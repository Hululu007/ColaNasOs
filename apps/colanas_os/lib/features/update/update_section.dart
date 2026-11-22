import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_version.dart';
import '../../core/session.dart';
import 'update_dialog.dart';
import 'update_service.dart';

/// 设置 →「软件更新」区块（客户端 + 服务端）。
///
/// 设计取舍：
///   - 客户端更新只在**登录后**检查一次，这里点「检查更新」是强制的（`force=1`）；
///   - 服务端更新默认**不自动**安装：NAS 常在跑转码 / 做种，切版本会重启内核，
///     所以必须用户点「立即更新」→ 看进度 → 再点「重启生效」。
class UpdateSection extends StatefulWidget {
  const UpdateSection({super.key});

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<UpdateSection> {
  SystemUpdateCheckResponse? _server;
  SystemUpdateJob? _job;
  Timer? _poll;
  bool _checking = false;
  bool _autoCheck = false;

  /// 增量装完后自动重启只做一次（轮询会在 ready 上反复进来）
  bool _autoRestarting = false;

  /// 服务端拉清单用的通道：`stable` / `pre`。勾了预发布才看得到开发中的版本。
  String _channel = 'stable';
  String? _error;
  String _versionDir = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _refreshServer();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final cfg = await ApiSession.instance.client.systemUpdateConfig();
      if (!mounted) return;
      setState(() {
        _autoCheck = cfg.autoCheck;
        _versionDir = cfg.versionDir;
        _channel = cfg.channel.isEmpty ? 'stable' : cfg.channel;
      });
    } catch (_) {
      // 老服务端没有这个接口：静默，界面上少一行而已
    }
  }

  Future<void> _refreshServer({bool force = true}) async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.systemUpdateCheck(
        component: 'server',
        force: force ? '1' : '0',
      );
      if (!mounted) return;
      setState(() {
        _server = res;
        // 服务端检查失败是 200 + error（离线 NAS 是常态），要如实告诉用户
        _error = res.error.isEmpty ? null : res.error;
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _checking = false;
      });
    }
  }

  /// `mode`：`delta` / `full` 对应界面上两个按钮；`auto` 是「能增量就增量」。
  Future<void> _startServerUpdate({String mode = 'auto'}) async {
    try {
      setState(() {
        _autoRestarting = false;
        _error = null;
      });
      final res = await ApiSession.instance.client.systemUpdateInstall(
        body: SystemUpdateInstallBody(force: true, mode: mode),
      );
      if (!mounted) return;
      setState(() => _job = res.job);
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 800), (timer) async {
      try {
        final res = await ApiSession.instance.client.systemUpdateStatus();
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _job = res.job);
        final phase = res.job.phase;
        if (phase != 'preparing' &&
            phase != 'downloading' &&
            phase != 'verifying' &&
            phase != 'assembling' &&
            phase != 'activating') {
          timer.cancel();
          if (phase == 'ready') {
            // 增量：文件已经落到新版本目录，只差重启内核，别让用户再点一下
            if (res.job.mode == 'delta') {
              unawaited(_autoRestartServer());
            }
            // 全量：服务端下载完会自己拉起安装程序（installer.nsh 装完再启回来），
            // 这里只需要把「正在安装」的状态显示出来，不要再去打接口
            await _refreshServer(force: false);
          }
        }
      } catch (_) {
        timer.cancel();
      }
    });
  }

  /// 增量装完自动重启：界面不再问「立即重启 / 稍后重启」。
  ///
  /// 留 1.2 秒是因为重启请求一发出内核就没了，先把「正在重启」这一帧画出去。
  Future<void> _autoRestartServer() async {
    if (_autoRestarting) return;
    _autoRestarting = true;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    try {
      await ApiSession.instance.client.systemUpdateRestart();
    } catch (_) {
      // 内核先死、请求被截断是正常的，不用报错
    }
    if (!mounted) return;
    NasSnack.show(context, tr('update.restartingServer'));
  }

  Future<void> _restartServer() async {
    try {
      await ApiSession.instance.client.systemUpdateRestart();
      if (!mounted) return;
      NasSnack.show(context, tr('update.restartingServer'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _rollback() async {
    try {
      await ApiSession.instance.client.systemUpdateRollback();
      await _refreshServer();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _toggleAutoCheck(bool on) async {
    setState(() => _autoCheck = on);
    try {
      await ApiSession.instance.client.systemUpdateConfigSave(
        body: SystemUpdateConfigBody(autoCheck: on),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _autoCheck = !on;
        _error = '$e';
      });
    }
  }

  /// 切到预发布通道。
  ///
  /// 通道是**服务端**的设置（清单由服务端拉取后代理给客户端），所以这里改的是
  /// 服务端的 `channel`：勾上之后所有连这台服务端的设备都看得到预发布版。
  /// 开发期用得上 —— 服务端与客户端两边的更新检查走同一份清单。
  Future<void> _togglePreChannel(bool on) async {
    final next = on ? 'pre' : 'stable';
    final prev = _channel;
    setState(() => _channel = next);
    try {
      await ApiSession.instance.client.systemUpdateConfigSave(
        body: SystemUpdateConfigBody(channel: next),
      );
      await _refreshServer();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _channel = prev;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clientInfo = UpdateService.instance.available.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _clientRow(),
        if (clientInfo != null && clientInfo.hasUpdate)
          Padding(
            padding: const EdgeInsets.only(top: NasTokens.spaceXs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('update.clientAvailable', {'version': clientInfo.latestSemver}),
                    style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
                  ),
                ),
                TextButton(
                  onPressed: () => UpdateDialog.show(context, clientInfo),
                  child: Text(tr('update.now')),
                ),
              ],
            ),
          ),
        const Divider(height: NasTokens.spaceLg),
        // ---------------- 服务端 ----------------
        Row(
          children: [
            Expanded(
              child: Text(
                tr('update.serverTitle'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (_checking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton(
                onPressed: () => _refreshServer(),
                child: Text(tr('update.check')),
              ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceXs),
        _serverBody(),
        if (_versionDir.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: NasTokens.spaceXs),
            child: SelectableText(
              tr('update.versionDir', {'dir': _versionDir}),
              style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _channel == 'pre',
          onChanged: _togglePreChannel,
          title: Text(tr('update.preChannel')),
          subtitle: Text(
            tr('update.preChannelHint'),
            style: TextStyle(fontSize: NasTokens.fontCaption),
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _autoCheck,
          onChanged: _toggleAutoCheck,
          title: Text(tr('update.autoCheck')),
          subtitle: Text(
            tr('update.autoCheckHint'),
            style: TextStyle(fontSize: NasTokens.fontCaption),
          ),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
          ),
      ],
    );
  }

  Widget _clientRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('update.clientTitle'), style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                'v$kAppVersion',
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
            ],
          ),
        ),
        ValueListenableBuilder<UpdateStatus>(
          valueListenable: UpdateService.instance.status,
          builder: (context, status, _) {
            if (status.phase == UpdatePhase.checking) {
              return const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            }
            return TextButton(
              onPressed: () async {
                await UpdateService.instance.check(force: true);
                if (!context.mounted) return;
                final info = UpdateService.instance.available.value;
                if (info != null && info.hasUpdate) {
                  await UpdateDialog.show(context, info);
                } else {
                  NasSnack.show(context, tr('update.none'));
                }
              },
              child: Text(tr('update.check')),
            );
          },
        ),
      ],
    );
  }

  Widget _serverBody() {
    final scheme = Theme.of(context).colorScheme;
    final server = _server;
    if (server == null) {
      return Text(
        _checking ? tr('update.checking') : '',
        style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
      );
    }
    final job = _job;
    if (job != null &&
        job.phase != 'idle' &&
        job.phase != 'ready' &&
        job.phase != 'failed' &&
        job.phase != 'cancelled') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: job.percent > 0 ? job.percent / 100 : null),
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            '${job.message}  ${job.total > 0 ? '${UpdateService.formatBytes(job.loaded)} / ${UpdateService.formatBytes(job.total)}' : ''}'
            '${job.speed > 0 ? ' · ${UpdateService.formatSpeed(job.speed)}' : ''}',
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
        ],
      );
    }
    if (job?.phase == 'failed') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('update.failed', {'error': job?.error ?? ''}),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
          ),
          if (job?.hint != 'manual')
            TextButton(onPressed: _startServerUpdate, child: Text(tr('update.retry'))),
        ],
      );
    }
    if (job?.phase == 'ready') {
      // 全量：服务端下载完会自己用 `/S` 拉起安装程序（`hint == 'auto'`），
      // 装完由 installer.nsh 把服务端启回来。这里只把状态说清楚，
      // 不再给一个「运行它即可」的路径让人自己找。
      //
      // `hint != 'auto'` 只出现在跑不了安装程序的兜底（非 Windows / 测试环境），
      // 这时才需要把路径显示出来。
      if (job?.mode == 'full') {
        final auto = job?.autoRun == true;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              auto ? tr('update.fullAutoInstall') : tr('update.fullReady'),
              style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
            ),
            if (!auto && (job?.hint ?? '').isNotEmpty)
              SelectableText(
                job?.hint ?? '',
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
          ],
        );
      }
      // 增量：已经自动重启了，这里只留一句说明 + 万一自动重启没成功的兜底按钮
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _autoRestarting ? tr('update.deltaAutoRestart') : tr('update.serverReady'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
          ),
          if (!_autoRestarting)
            Row(
              children: [
                FilledButton(onPressed: _restartServer, child: Text(tr('update.restartNow'))),
                const SizedBox(width: NasTokens.spaceSm),
                TextButton(onPressed: _restartServer, child: Text(tr('update.serverRestart'))),
              ],
            ),
        ],
      );
    }
    if (!server.hasUpdate) {
      return Text(
        tr('update.noneWithVersion', {'version': server.currentSemver}),
        style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
      );
    }
    // 增量能不能用由服务端算（当前版本必须在增量基线里）：
    //   - 能用 → 「增量更新（1.4 MB）」+「下载并安装完整包（551 MB）」两个按钮；
    //   - 不能用（跨版本 / 基线对不上 / 需要换外壳）→ 只给全量那一个。
    final canDelta = server.deltaAvailable && !server.needsReshell;
    final fullBytes = server.fullBytes;
    final deltaText = tr('update.deltaInstall', {
      'size': UpdateService.formatBytes(server.deltaBytes),
    });
    final fullText = tr('update.fullInstall', {
      'size': UpdateService.formatBytes(fullBytes),
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('update.serverAvailable', {'version': server.latestSemver}),
          style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
        ),
        Text(
          canDelta
              ? tr('update.modeDelta', {'size': UpdateService.formatBytes(server.deltaBytes)})
              : tr('update.modeFull'),
          style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
        ),
        if (server.needsReshell)
          Text(
            tr('update.needsReshell'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
          ),
        const SizedBox(height: NasTokens.spaceXs),
        Wrap(
          spacing: NasTokens.spaceSm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (canDelta)
              FilledButton(
                onPressed: () => _startServerUpdate(mode: 'delta'),
                child: Text(deltaText),
              ),
            if (fullBytes > 0)
              canDelta
                  ? TextButton(
                      onPressed: () => _startServerUpdate(mode: 'full'),
                      child: Text(fullText),
                    )
                  : FilledButton(
                      onPressed: () => _startServerUpdate(mode: 'full'),
                      child: Text(fullText),
                    ),
            if (!canDelta && fullBytes == 0)
              Text(
                tr('update.noAsset'),
                style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
              ),
            TextButton(onPressed: _rollback, child: Text(tr('update.rollback'))),
          ],
        ),
      ],
    );
  }
}
