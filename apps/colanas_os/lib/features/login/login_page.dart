import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/server_discovery.dart';
import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../tv/tv_keyboard.dart';

/// 登录分两步：先连服务器，连上才知道该「登录」还是「创建管理员」。
enum _LoginStage { server, auth }

/// TV 扫码登录状态：电视只负责展示一次性 code 并轮询，批准动作在手机侧完成。
enum _DeviceLoginState {
  idle,
  loading,
  ready,
  expired,
  canceled,
  unsupported,
  approved,
}

/// 登录页。启动时先探测服务端是否「还没初始化」（`GET /auth/bootstrap`）：
///
/// - `needsSetup: true` → 切到「首次安装」表单，创建第一个管理员（蓝图 §50）；
/// - 其余情况（含探测失败）→ 正常登录表单。探测失败不弹错，用户仍可手动登录
///   （服务端可能还没起来，或者已经初始化过）。
///
/// 2026-11-04：改成两步。第一步只填服务器地址 + 「连接」，
/// 连上之后再决定显示登录还是创建管理员 —— 之前地址和账号密码挤在一屏，
/// 而且空库时会直接铺出「创建管理员」，看起来像默认让人开账号。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  /// 测试注入口：覆盖第一步「连服务器」的探测，返回 `needsSetup`。
  ///
  /// 生产恒为 null，走真实请求。`testWidgets` 会把 HttpClient 换成返回 400 的
  /// 假实现，测试里没法用本地 HttpServer 进第二步，所以留这一个钩子。
  @visibleForTesting
  static Future<bool> Function(String url)? debugProbe;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _server = TextEditingController(text: ApiSession.defaultBaseUrl());
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _totp = TextEditingController();

  bool _busy = false;
  bool _autoLogin = true;

  /// 密码是否明文显示：默认隐藏，点右侧小眼睛临时看一眼（不持久化）。
  bool _showPassword = false;

  /// 是否要提交两步验证码：默认关闭，勾选后才显示验证码输入框。
  bool _twoFactor = false;

  bool _checking = true;
  bool _setupMode = false;
  String? _error;
  String? _hint;

  /// 局域网扫描中（按钮转圈）
  bool _scanning = false;

  /// 地址下方的提示：端口自动匹配结果 / 扫描结果
  String? _serverHint;

  /// 防止「连不上 → 自动匹配端口 → 再连 → 又连不上」死循环
  bool _autoMatched = false;

  /// 当前步骤：先连服务器，连上才显示登录 / 创建管理员
  _LoginStage _stage = _LoginStage.server;
  bool _connecting = false;
  String? _serverError;

  /// TV 端显式焦点链：输入框不再靠方向键猜邻居，逐级交给下一个控件。
  /// 非 TV 构建完全不用这些节点，行为与以前一致。
  final FocusNode _serverFocus = FocusNode(debugLabel: 'login-server');
  final FocusNode _scanFocus = FocusNode(debugLabel: 'login-scan-lan');
  final FocusNode _connectFocus = FocusNode(debugLabel: 'login-connect');
  final FocusNode _userFocus = FocusNode(debugLabel: 'login-user');
  final FocusNode _passwordFocus = FocusNode(debugLabel: 'login-password');
  final FocusNode _eyeFocus = FocusNode(debugLabel: 'login-password-eye');
  final FocusNode _confirmFocus = FocusNode(debugLabel: 'login-confirm');
  final FocusNode _totpFocus = FocusNode(debugLabel: 'login-totp');
  final FocusNode _submitFocus = FocusNode(debugLabel: 'login-submit');

  /// TV 扫码登录：二维码 / 短码 / 过期倒计时 / 轮询。
  final FocusNode _deviceRefreshFocus = FocusNode(
    debugLabel: 'login-device-refresh',
  );
  final FocusNode _deviceCancelFocus = FocusNode(
    debugLabel: 'login-device-cancel',
  );
  _DeviceLoginState _deviceState = _DeviceLoginState.idle;
  String? _deviceCode;
  String _deviceUserCode = '';
  String _deviceVerifyUrl = '';
  int _deviceLeftSec = 0;
  DateTime? _deviceExpiresAt;
  Timer? _devicePollTimer;
  Timer? _deviceTickTimer;
  bool _devicePolling = false;

  @override
  void initState() {
    super.initState();
    final store = SettingsStore.instance;
    // 服务器地址：Web 端以**地址栏**为准（页面本身就是内核，可能经 lucky 反代，
    // API 必须同源），原生端读存档。currentServerUrl() 已把两者分开处理。
    _server.text = ApiSession.currentServerUrl();
    final user = store.getString('auth.username');
    if (user != null && user.isNotEmpty) _user.text = user;
    // 记住的密码直接预填（用户要求「账号密码都要保存」），点登录即可
    final savedPassword = store.getString('auth.password');
    if (savedPassword != null && savedPassword.isNotEmpty) {
      _password.text = savedPassword;
    }
    // 服务端公开信息（自定义主机名 / 欢迎语）：登录页先读一次，读到就刷新标题
    ApiSession.instance.loadServerInfo().then((_) {
      if (mounted) setState(() {});
    });
    _autoLogin = (savedPassword != null && savedPassword.isNotEmpty) ||
        !(store.getBool('auth.autoLoginDisabled') ?? false);
    // 已保存过地址：自动试连一次，连上就直接进登录/创建步骤；
    // 没保存地址（或连不上）就停在「填地址」这一步。
    if (_server.text.trim().isNotEmpty) {
      unawaited(_connect(auto: true));
    } else {
      _checking = false;
    }
  }

  @override
  void dispose() {
    _stopDeviceLogin(cancel: true);
    _server.dispose();
    _user.dispose();
    _password.dispose();
    _confirm.dispose();
    _totp.dispose();
    _serverFocus.dispose();
    _scanFocus.dispose();
    _connectFocus.dispose();
    _userFocus.dispose();
    _passwordFocus.dispose();
    _eyeFocus.dispose();
    _confirmFocus.dispose();
    _totpFocus.dispose();
    _submitFocus.dispose();
    _deviceRefreshFocus.dispose();
    _deviceCancelFocus.dispose();
    super.dispose();
  }

  /// 第一步：连服务器。连上之后才知道该显示「登录」还是「创建管理员」。
  ///
  /// [auto] = 启动时用上次保存的地址自动重连，失败不铺错误（用户直接改地址即可）。
  Future<void> _connect({bool auto = false}) async {
    final url = _server.text.trim();
    if (url.isEmpty) {
      setState(() {
        _connecting = false;
        _checking = false;
        _serverError = tr('login.serverRequired');
      });
      return;
    }
    setState(() {
      _connecting = true;
      _serverError = null;
      _error = null;
    });
    ApiSession.instance.configure(url);
    try {
      final probe = LoginPage.debugProbe;
      final res = probe != null
          ? <String, dynamic>{'needsSetup': await probe(url)}
          : await ApiSession.instance.client.authBootstrapStatus();
      // 静态网页 / 反代误配也会返回 200 + HTML，客户端会解成空 Map。
      // 没有 needsSetup 字段就不是内核，直接停在第一步，避免「已连接」后登录 404。
      if (probe == null && res['needsSetup'] is! bool) {
        throw const FormatException('not_nas_server');
      }
      if (!mounted) return;
      SettingsStore.instance.setString('auth.server', url);
      _autoMatched = false;
      setState(() {
        _setupMode = res['needsSetup'] == true;
        _stage = _LoginStage.auth;
        _connecting = false;
        _checking = false;
        _serverHint = null;
      });
      // TV：连上就顺手生成扫码登录码，手动输入照旧可用。
      if (tvInputEnabled && !_setupMode) {
        unawaited(_startDeviceLogin());
      }
      // 连上之后，勾了自动登录且账号密码都记着 → 直接登录进桌面。
      // 覆盖「启动时服务端还没起来、用户手动重试连上」这种情况：
      // 勾了自动登录就不该再让人手输一遍密码。
      if (auto &&
          !_setupMode &&
          _autoLogin &&
          _user.text.trim().isNotEmpty &&
          _password.text.isNotEmpty) {
        await _submitLogin();
      }
    } catch (e) {
      debugPrint('[login] connect failed: $e');
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _checking = false;
        _serverError = auto ? null : _describe(e);
      });
      // 把用户刚填的地址记住：服务端端口换过也不至于下次还要重打一遍
      if (url.isNotEmpty) {
        SettingsStore.instance.setString('auth.server', url);
      }
      // 原生端：连不上时按「同一个主机 + 候选端口」自动找一遍（Web 端同源，无需匹配）。
      // 启动自动重连时只在「本机地址」上匹配 —— 端口改了一般就是本机内核，
      // 而远程 NAS 连不上多半是没开机，别在启动路径上干等 8 个端口的超时。
      if (!kIsWeb && !_autoMatched && (!auto || _isLocalHost(url))) {
        await _autoMatchPort(url, silent: auto);
      }
    }
  }

  /// 端口自动匹配：只换端口、不换主机。找到就填回输入框并重连一次。
  ///
  /// 这是「服务端把 7788 改成别的口」最省事的处理方式：用户不用知道新端口。
  Future<void> _autoMatchPort(String url, {bool silent = false}) async {
    if (!silent) setState(() => _serverHint = tr('login.matchingPort'));
    final hit = await matchPort(url);
    if (!mounted) return;
    final normalized = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (hit == null || hit.baseUrl == normalized) {
      // 端口也没找着：原生端提示可以直接扫网段（Web 端本来就没有扫描入口）
      setState(() => _serverHint = silent || kIsWeb ? null : tr('login.matchFailed'));
      return;
    }
    setState(() {
      _server.text = hit.baseUrl;
      _serverHint = tr('login.autoMatched', {'url': hit.baseUrl});
      _autoMatched = true;
    });
    await _connect();
  }

  /// 扫本网段：手机 / 换机器时不知道填哪个 IP，点一下列出来。
  Future<void> _scanLan() async {
    if (_scanning) return;
    final typed = _portOf(_server.text) ?? 7788;
    setState(() {
      _scanning = true;
      _serverHint = tr('login.scanning');
    });
    List<DiscoveredServer> found = const <DiscoveredServer>[];
    try {
      found = await scanLan(port: typed, extraPorts: const <int>[7788, 23788]);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
    if (!mounted) return;
    if (found.isEmpty) {
      setState(() => _serverHint = tr('login.scanEmpty'));
      return;
    }
    setState(() => _serverHint = null);
    final picked = await showDialog<DiscoveredServer>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('login.pickServer')),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: found
                .map((e) => ListTile(
                      leading: const Icon(Icons.dns_outlined, size: 18),
                      title: Text(e.label),
                      subtitle: Text(e.baseUrl),
                      onTap: () => Navigator.of(ctx).pop(e),
                    ))
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(tr('common.cancel')),
          ),
        ],
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _server.text = picked.baseUrl;
      _serverHint = tr('login.autoMatched', {'url': picked.baseUrl});
    });
    await _connect();
  }

  /// 是不是指向本机（127.x / localhost / ::1）
  bool _isLocalHost(String url) {
    var s = url.trim();
    if (s.isEmpty) return false;
    if (!s.contains('://')) s = 'http://$s';
    final uri = Uri.tryParse(s);
    final host = uri?.host ?? '';
    return host == 'localhost' ||
        host == '::1' ||
        host == '[::1]' ||
        host.startsWith('127.');
  }

  /// 从输入框里取端口（没写就是 null）
  int? _portOf(String text) {
    var s = text.trim();
    if (s.isEmpty) return null;
    if (!s.contains('://')) s = 'http://$s';
    final uri = Uri.tryParse(s);
    if (uri == null) return null;
    if (uri.hasPort) return uri.port;
    if (uri.scheme == 'https') return 443;
    return null;
  }

  /// 回到第一步（换一台服务器）
  void _backToServer() {
    _stopDeviceLogin(cancel: true);
    setState(() {
      _deviceState = _DeviceLoginState.idle;
      _stage = _LoginStage.server;
      _serverError = null;
      _error = null;
      _hint = null;
    });
  }

  // ---------------------------------------------------------------------------
  // 扫码登录（TV）：服务端一次性 code，手机浏览器批准，电视轮询拿 token
  // ---------------------------------------------------------------------------

  Future<void> _startDeviceLogin() async {
    if (!tvInputEnabled) return;
    _stopDeviceLogin(cancel: true);
    if (!mounted) return;
    setState(() {
      _deviceState = _DeviceLoginState.loading;
      _deviceCode = null;
      _deviceUserCode = '';
      _deviceVerifyUrl = '';
      _deviceLeftSec = 0;
    });
    try {
      final res = await ApiSession.instance.client.authDeviceCode(
        body: <String, dynamic>{
          'deviceName': defaultTargetPlatform == TargetPlatform.android
              ? 'Android TV'
              : defaultTargetPlatform.name,
        },
      );
      if (!mounted) return;
      final code = '${res['code'] ?? ''}';
      final userCode = '${res['userCode'] ?? ''}';
      final verifyUrl = '${res['verifyUrl'] ?? ''}';
      if (code.isEmpty || verifyUrl.isEmpty) {
        setState(() => _deviceState = _DeviceLoginState.unsupported);
        return;
      }
      final expiresIn = (res['expiresInSec'] as num?)?.toInt() ?? 300;
      final pollSec = ((res['pollIntervalSec'] as num?)?.toInt() ?? 2).clamp(2, 10);
      _deviceCode = code;
      _deviceUserCode = userCode;
      _deviceVerifyUrl = verifyUrl;
      _deviceExpiresAt = DateTime.now().add(Duration(seconds: expiresIn));
      setState(() {
        _deviceLeftSec = expiresIn;
        _deviceState = _DeviceLoginState.ready;
      });
      _devicePollTimer = Timer.periodic(
        Duration(seconds: pollSec),
        (_) => unawaited(_pollDevice()),
      );
      _deviceTickTimer = Timer.periodic(
        const Duration(seconds: 1),
        (_) => _tickDevice(),
      );
    } catch (e) {
      debugPrint('[login] device code failed: $e');
      if (!mounted) return;
      // 老服务端没有这个接口：不报错，退回手动输入。
      setState(() => _deviceState = _DeviceLoginState.unsupported);
    }
  }

  void _tickDevice() {
    final expiresAt = _deviceExpiresAt;
    if (expiresAt == null || !mounted) return;
    final left = expiresAt.difference(DateTime.now()).inSeconds;
    if (left <= 0) {
      _stopDeviceLogin(cancel: false);
      setState(() {
        _deviceLeftSec = 0;
        _deviceState = _DeviceLoginState.expired;
      });
      return;
    }
    setState(() => _deviceLeftSec = left);
  }

  Future<void> _pollDevice() async {
    final code = _deviceCode;
    if (code == null || _devicePolling) return;
    _devicePolling = true;
    try {
      final res = await ApiSession.instance.client.authDeviceStatus(code: code);
      if (!mounted || _deviceCode != code) return;
      final status = '${res['status'] ?? ''}';
      if (status == 'approved') {
        final token = res['token'] as String?;
        if (token == null || token.isEmpty) return; // token 已取走，等页面切走
        final user = res['user'];
        final name = user is Map ? '${user['username'] ?? ''}' : '';
        _stopDeviceLogin(cancel: false);
        setState(() => _deviceState = _DeviceLoginState.approved);
        await ApiSession.instance.adoptToken(
          tokenValue: token,
          userName: name.isEmpty ? _user.text.trim() : name,
        );
      } else if (status == 'expired' || status == 'canceled') {
        _stopDeviceLogin(cancel: false);
        setState(() {
          _deviceState = status == 'canceled'
              ? _DeviceLoginState.canceled
              : _DeviceLoginState.expired;
        });
      }
    } catch (_) {
      // 网络抖动：下一轮继续，过期由倒计时兜底
    } finally {
      _devicePolling = false;
    }
  }

  void _stopDeviceLogin({required bool cancel}) {
    _devicePollTimer?.cancel();
    _deviceTickTimer?.cancel();
    _devicePollTimer = null;
    _deviceTickTimer = null;
    _deviceExpiresAt = null;
    final code = _deviceCode;
    _deviceCode = null;
    if (cancel && code != null) {
      unawaited(() async {
        try {
          await ApiSession.instance.client.authDeviceCancel(
            body: <String, dynamic>{'code': code},
          );
        } catch (_) {
          // 取消失败不影响：码本身会过期
        }
      }());
    }
  }

  Future<void> _submitLogin() async {
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });
    try {
      await ApiSession.instance.setAutoLoginEnabled(_autoLogin);
      ApiSession.instance.configure(_server.text.trim());
      final totp = _twoFactor ? _totp.text.trim() : '';
      await ApiSession.instance.login(
        _user.text.trim(),
        _password.text,
        totp: totp.isEmpty ? null : totp,
      );
    } catch (e) {
      final text = e.toString();
      if (!mounted) return;
      setState(() {
        _error = _describe(e);
        // 服务端要求两步验证：直接打开开关，省一次手动勾选
        if (text.contains('totp_required')) _twoFactor = true;
      });
      // 连不上服务端（常见于先开窗口、内核还没起来）→ 重新探测：空库就切到「首次安装」
      if (_isConnectionError(text)) await _connect();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _isConnectionError(String text) =>
      text.contains('SocketException') ||
      text.contains('connection') ||
      text.contains('Connection');

  /// 首次安装：创建管理员 → 直接用同一密码登录。
  Future<void> _submitSetup() async {
    final user = _user.text.trim();
    final pwd = _password.text;
    if (user.isEmpty) {
      setState(() => _error = tr('setup.usernameRequired'));
      return;
    }
    if (pwd.length < 8) {
      setState(() => _error = tr('setup.tooShort'));
      return;
    }
    if (pwd != _confirm.text) {
      setState(() => _error = tr('setup.mismatch'));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _hint = null;
    });
    try {
      ApiSession.instance.configure(_server.text.trim());
      await ApiSession.instance.client.authBootstrap(
        body: {'username': user, 'password': pwd},
      );
      await ApiSession.instance.setAutoLoginEnabled(_autoLogin);
      await ApiSession.instance.login(user, pwd);
    } catch (e) {
      final text = e.toString();
      if (text.contains('already initialized') || text.contains('conflict')) {
        // 别人已经初始化过：切回登录，不把用户卡在引导页
        if (!mounted) return;
        setState(() {
          _setupMode = false;
          _hint = tr('setup.alreadyDone');
          _error = null;
        });
      } else if (text.contains('connection') ||
          text.contains('SocketException')) {
        if (!mounted) return;
        setState(() => _error = tr('setup.failed'));
      } else {
        if (!mounted) return;
        setState(() => _error = '${tr('setup.failed')}：$text');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe(Object e) {
    final text = e.toString();
    if (text.contains('not_nas_server')) return tr('login.notNasServer');
    if (text.contains('totp_required')) return tr('ui.login.h1b8cb2');
    if (text.contains('unauthorized') || text.contains('401')) {
      return tr('ui.login.hfbaa29');
    }
    return tr('login.failed', {'reason': text});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: tvInputEnabled ? 620 : 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(NasTokens.spaceLg),
            child: _stage == _LoginStage.server
                ? _serverForm(context)
                : _authForm(context),
          ),
        ),
      ),
    );
  }

  /// 第一步：只有服务器地址。连上之后才进登录/创建。
  Widget _serverForm(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'ColaNasOs',
          style: TextStyle(fontSize: NasTokens.fontHeadline),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          tr('login.serverStep'),
          style: TextStyle(
            fontSize: NasTokens.fontBody,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          tr('login.serverStepHint'),
          style: TextStyle(
            fontSize: NasTokens.fontCaption,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: NasTokens.spaceLg),
        if (tvInputEnabled)
          TvKeyboardField(
            controller: _server,
            focusNode: _serverFocus,
            autofocus: true,
            labelText: tr('login.server'),
            prefixIcon: const Icon(Icons.dns_outlined, size: 18),
            // 「右 / 下」先到扫描局域网，再到连接；按钮被禁用时自动跳过。
            nextFocusNodes: <FocusNode>[
              if (!kIsWeb) _scanFocus,
              _connectFocus,
            ],
            onChanged: (_) => _autoMatched = false,
            onSubmitted: (_) => _connecting ? null : _connect(),
          )
        else
          TextField(
            controller: _server,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: tr('login.server'),
              prefixIcon: const Icon(Icons.dns_outlined, size: 18),
              // 浏览器扫不了网段（没有 dart:io），只在原生端给扫描入口
              suffixIcon: kIsWeb
                  ? null
                  : IconButton(
                      tooltip: tr('login.scanLan'),
                      onPressed: _scanning || _connecting ? null : _scanLan,
                      icon: _scanning
                          ? const SizedBox(
                              height: 16,
                              width: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.wifi_tethering, size: 18),
                    ),
            ),
            onChanged: (_) => _autoMatched = false,
            onSubmitted: (_) => _connecting ? null : _connect(),
          ),
        // TV 上 suffixIcon 不在焦点遍历里，扫描入口改成独立的、可用方向键到达的按钮。
        if (tvInputEnabled && !kIsWeb) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              focusNode: _scanFocus,
              onPressed: _scanning || _connecting ? null : _scanLan,
              icon: _scanning
                  ? const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.wifi_tethering, size: 18),
              label: Text(tr('login.scanLan')),
            ),
          ),
        ],
        if (_serverHint != null) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Text(
            _serverHint!,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
        if (_serverError != null) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Text(_serverError!, style: TextStyle(color: context.nasDanger)),
        ],
        const SizedBox(height: NasTokens.spaceMd),
        FilledButton(
          focusNode: tvInputEnabled ? _connectFocus : null,
          onPressed: _connecting ? null : () => _connect(),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceSm),
            child: _connecting
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(tr('login.connect')),
          ),
        ),
      ],
    );
  }

  /// TV 扫码登录区：二维码 + 短码 + 倒计时，手机浏览器打开授权页批准。
  Widget _buildDeviceLogin(BuildContext context) {
    final muted = TextStyle(
      fontSize: NasTokens.fontCaption,
      color: context.nasTextSecondary,
    );
    switch (_deviceState) {
      case _DeviceLoginState.idle:
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            focusNode: _deviceRefreshFocus,
            onPressed: _startDeviceLogin,
            icon: const Icon(Icons.qr_code_2, size: 18),
            label: Text(tr('login.device.show')),
          ),
        );
      case _DeviceLoginState.loading:
        return Row(
          children: [
            const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(tr('login.device.loading'), style: muted),
          ],
        );
      case _DeviceLoginState.unsupported:
        return Text(tr('login.device.unsupported'), style: muted);
      case _DeviceLoginState.expired:
      case _DeviceLoginState.canceled:
        return Row(
          children: [
            Expanded(
              child: Text(
                _deviceState == _DeviceLoginState.expired
                    ? tr('login.device.expired')
                    : tr('login.device.canceled'),
                style: muted,
              ),
            ),
            TextButton.icon(
              focusNode: _deviceRefreshFocus,
              onPressed: _startDeviceLogin,
              icon: const Icon(Icons.refresh, size: 18),
              label: Text(tr('login.device.refresh')),
            ),
          ],
        );
      case _DeviceLoginState.approved:
        return Row(
          children: [
            const SizedBox(
              height: 16,
              width: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 10),
            Text(tr('login.device.approved'), style: muted),
          ],
        );
      case _DeviceLoginState.ready:
        final left = _deviceLeftSec;
        final clock =
            '${(left ~/ 60).toString().padLeft(2, '0')}:${(left % 60).toString().padLeft(2, '0')}';
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: _deviceVerifyUrl,
                version: QrVersions.auto,
                size: 168,
                backgroundColor: Colors.white,
                padding: EdgeInsets.zero,
                gapless: true,
              ),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr('login.device.title'),
                    style: const TextStyle(
                      fontSize: NasTokens.fontBody,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr('login.device.hint', {'url': _deviceVerifyUrl}),
                    style: muted,
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Text('${tr('login.device.code')}:', style: muted),
                      const SizedBox(width: 10),
                      SelectableText(
                        _deviceUserCode,
                        style: const TextStyle(
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 6,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    tr('login.device.expiresIn', {'time': clock}),
                    style: muted,
                  ),
                  const SizedBox(height: 4),
                  Wrap(
                    spacing: 8,
                    children: [
                      TextButton.icon(
                        focusNode: _deviceRefreshFocus,
                        onPressed: _startDeviceLogin,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: Text(tr('login.device.refresh')),
                      ),
                      TextButton.icon(
                        focusNode: _deviceCancelFocus,
                        onPressed: () {
                          _stopDeviceLogin(cancel: true);
                          setState(
                            () => _deviceState = _DeviceLoginState.idle,
                          );
                        },
                        icon: const Icon(Icons.close, size: 18),
                        label: Text(tr('login.device.cancel')),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
    }
  }

  /// 第二步：登录或创建管理员（取决于服务端是否已有账号）。
  Widget _authForm(BuildContext context) {
    final setup = _setupMode;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'ColaNasOs',
          style: TextStyle(fontSize: NasTokens.fontHeadline),
        ),
        const SizedBox(height: NasTokens.spaceXs),
        Text(
          setup
              ? tr('setup.hint')
              : (ApiSession.instance.hostName.isEmpty
                  ? tr('login.title')
                  : '${tr('login.title')} · ${ApiSession.instance.hostName}'),
          style: TextStyle(
            fontSize: NasTokens.fontBody,
            color: context.nasTextSecondary,
          ),
        ),
        const SizedBox(height: NasTokens.spaceLg),
        Row(
          children: [
            Icon(
              Icons.dns_outlined,
              size: 15,
              color: context.nasTextSecondary,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                tr('login.connectedTo', {
                  'host': ApiSession.instance.hostName.isEmpty
                      ? _server.text.trim()
                      : ApiSession.instance.hostName,
                }),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
            TextButton(
              onPressed: _busy ? null : _backToServer,
              child: Text(tr('login.changeServer')),
            ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceSm),
        // TV：扫码登录（手机浏览器批准），与下面的手动输入并存。
        if (tvInputEnabled && !setup) ...[
          _buildDeviceLogin(context),
          const SizedBox(height: NasTokens.spaceMd),
          Row(
            children: [
              const Expanded(child: Divider()),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text(
                  tr('login.device.orManual'),
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
              const Expanded(child: Divider()),
            ],
          ),
          const SizedBox(height: NasTokens.spaceMd),
        ],
        if (tvInputEnabled)
          TvKeyboardField(
            controller: _user,
            focusNode: _userFocus,
            autofocus: true,
            labelText: setup ? tr('setup.username') : tr('login.username'),
            previousFocusNodes: <FocusNode>[
              _deviceCancelFocus,
              _deviceRefreshFocus,
            ],
            nextFocusNodes: <FocusNode>[_passwordFocus],
          )
        else
          TextField(
            controller: _user,
            decoration: InputDecoration(
              labelText: setup
                  ? tr('setup.username')
                  : tr('login.username'),
            ),
          ),
        const SizedBox(height: NasTokens.spaceMd),
        if (tvInputEnabled)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TvKeyboardField(
                  controller: _password,
                  focusNode: _passwordFocus,
                  obscureText: !_showPassword,
                  labelText: setup
                      ? tr('setup.password')
                      : tr('login.password'),
                  previousFocusNodes: <FocusNode>[_userFocus],
                  nextFocusNodes: <FocusNode>[
                    _eyeFocus,
                    if (setup) _confirmFocus,
                    if (!setup && _twoFactor) _totpFocus,
                    _submitFocus,
                  ],
                  onSubmitted: (_) => setup ? _submitSetup() : _submitLogin(),
                ),
              ),
              IconButton(
                focusNode: _eyeFocus,
                tooltip: tr(
                  _showPassword ? 'login.hidePassword' : 'login.showPassword',
                ),
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () =>
                    setState(() => _showPassword = !_showPassword),
              ),
            ],
          )
        else
          TextField(
            controller: _password,
            obscureText: !_showPassword,
            decoration: InputDecoration(
              labelText: setup
                  ? tr('setup.password')
                  : tr('login.password'),
              suffixIcon: IconButton(
                tooltip: tr(
                  _showPassword
                      ? 'login.hidePassword'
                      : 'login.showPassword',
                ),
                icon: Icon(
                  _showPassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                ),
                onPressed: () =>
                    setState(() => _showPassword = !_showPassword),
              ),
            ),
            onSubmitted: (_) => setup ? _submitSetup() : _submitLogin(),
          ),
        if (setup) ...[
          const SizedBox(height: NasTokens.spaceMd),
          if (tvInputEnabled)
            TvKeyboardField(
              controller: _confirm,
              focusNode: _confirmFocus,
              obscureText: true,
              labelText: tr('setup.confirm'),
              previousFocusNodes: <FocusNode>[_passwordFocus, _userFocus],
              nextFocusNodes: <FocusNode>[_submitFocus],
            )
          else
            TextField(
              controller: _confirm,
              obscureText: true,
              decoration: InputDecoration(labelText: tr('setup.confirm')),
            ),
        ] else ...[
          Row(
            children: [
              Expanded(
                child: CheckboxListTile(
                  value: _autoLogin,
                  // 勾选状态**立即落盘**：用户取消勾选就是「不要记住我」，
                  // 不该等到点登录才生效 —— 否则下次打开又是勾上的。
                  onChanged: (v) async {
                    final enabled = v ?? true;
                    setState(() => _autoLogin = enabled);
                    await ApiSession.instance.setAutoLoginEnabled(enabled);
                  },
                  title: Text(tr('login.autoLogin')),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              Expanded(
                child: CheckboxListTile(
                  value: _twoFactor,
                  onChanged: (v) => setState(() {
                    _twoFactor = v ?? false;
                    if (!_twoFactor) _totp.clear();
                  }),
                  title: Text(tr('login.twoFactor')),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          if (_twoFactor)
            if (tvInputEnabled)
              TvKeyboardField(
                controller: _totp,
                focusNode: _totpFocus,
                numbersOnly: true,
                maxLength: 6,
                labelText: tr('login.totp'),
                previousFocusNodes: <FocusNode>[_passwordFocus, _userFocus],
                nextFocusNodes: <FocusNode>[_submitFocus],
              )
            else
              TextField(
                controller: _totp,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: InputDecoration(labelText: tr('login.totp')),
              ),
        ],
        if (_hint != null) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Text(
            _hint!,
            style: TextStyle(color: context.nasTextSecondary),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Text(_error!, style: TextStyle(color: context.nasDanger)),
        ],
        const SizedBox(height: NasTokens.spaceMd),
        FilledButton(
          focusNode: tvInputEnabled ? _submitFocus : null,
          onPressed: _busy || _checking
              ? null
              : (setup ? _submitSetup : _submitLogin),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: NasTokens.spaceSm,
            ),
            child: _busy
                ? const SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(setup ? tr('setup.submit') : tr('login.submit')),
          ),
        ),
        if (setup) ...[
          const SizedBox(height: NasTokens.spaceSm),
          Text(
            tr('setup.title'),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ],
    );
  }
}
