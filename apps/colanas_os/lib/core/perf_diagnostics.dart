import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/scheduler.dart';
import 'package:http/http.dart' as http;

import 'app_settings.dart';
import 'app_version.dart';
import 'client_log.dart';
import 'perf_device_io.dart'
    if (dart.library.js_interop) 'perf_device_web.dart'
    as device;
import 'session.dart';
import 'settings_store.dart';

/// 客户端性能诊断（**默认关闭**）。
///
/// 为什么要有：装机版用户在「另一台电脑」上说卡到不可用时，服务端的请求日志
/// 看不出到底是 Dart 主线程被占、GPU 光栅慢、图片解码炸内存，还是网络 RTT 高。
/// 这个模块把可区分这几种情况的数字都采下来，写到本机文件 **并** 上报到服务端
/// `<数据目录>/logs/perf/client-perf-<日期>.jsonl`，用户只需要回传一个文件。
///
/// 采什么：
///   - 帧耗时：build / raster / total 的 p50 / p90 / p99 / max，慢帧计数，fps；
///   - 按页面维度：当前所在 App（工作台 / 相册 / 影视…）各自的帧耗时，能定位是哪一页；
///   - 接口耗时：客户端 → 服务端每个路由的次数 / 均值 / p95 / 最大 / 响应字节；
///   - 设备：分辨率、DPR、刷新率、显卡与驱动（Windows 走 PowerShell 静态查询）、
///     Dart 进程内存、图片缓存张数与字节数、界面风格与模糊强度；
///   - 事件：页面切换、前后台切换。
///
/// 开销控制：
///   - 关闭时只累加几个整数（每帧 O(1)），每 60 s 打一行摘要（沿用旧行为）；
///   - 打开时才保留环形采样、设备信息与 JSON 上报，30 s 一次。
class PerfDiagnostics {
  PerfDiagnostics._();

  static final PerfDiagnostics instance = PerfDiagnostics._();

  static const String storageKey = 'perf.diagnostics';

  /// 打包时固定打开（`--dart-define=COLANAS_PERF=1`），用于给用户发专用诊断包。
  static const bool _buildDefault = bool.fromEnvironment('COLANAS_PERF');

  /// 详细模式的采样周期
  static const Duration _reportEvery = Duration(seconds: 30);

  /// 关闭状态下的轻量摘要周期
  static const Duration _summaryEvery = Duration(seconds: 60);

  final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  /// 最近一次上报结果（设置页展示）
  final ValueNotifier<String> lastReport = ValueNotifier<String>('');

  /// 本机诊断文件路径（设置页展示，方便用户直接回传）
  final ValueNotifier<String> localLogPath = ValueNotifier<String>('');

  /// 服务端诊断文件路径（上报成功后由服务端回传）
  final ValueNotifier<String> serverLogPath = ValueNotifier<String>('');

  bool _installed = false;
  String _app = 'full';
  String _surface = 'startup';

  // ---- 帧耗时累加（关闭时也跑，全是 O(1)） ----
  int _frames = 0;
  double _sumTotal = 0;
  double _sumBuild = 0;
  double _sumRaster = 0;
  double _maxTotal = 0;
  double _maxBuild = 0;
  double _maxRaster = 0;
  int _slow16 = 0;
  int _slow33 = 0;
  int _slow50 = 0;

  // ---- 详细模式才用的环形采样 ----
  final _Ring _total = _Ring(2400);
  final _Ring _build = _Ring(2400);
  final _Ring _raster = _Ring(2400);
  final Map<String, _SurfaceAgg> _surfaces = <String, _SurfaceAgg>{};
  final List<Map<String, Object?>> _slowest = <Map<String, Object?>>[];
  final List<Map<String, Object?>> _events = <Map<String, Object?>>[];
  final Map<String, _ReqAgg> _requests = <String, _ReqAgg>{};

  Map<String, Object?>? _device;
  Map<String, int>? _bootMarks;
  DateTime _windowStart = DateTime.now();

  /// 启动阶段各时间点（毫秒）：settings / i18n / session / services / firstFrame
  void setBootMarks(Map<String, int> marks) => _bootMarks = marks;

  bool get isOn => enabled.value;

  /// 启动时调用一次。[app] 是端标识（full / photo / music / sync）。
  void install({String app = 'full'}) {
    if (_installed) return;
    _installed = true;
    _app = app;
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
    // 计时器常驻进程生命周期（诊断模块本身不销毁），不需要保存句柄
    Timer.periodic(const Duration(seconds: 5), (_) => _tick());
    // 设置已由 AppSettings.load() 读进内存，这里同步取即可
    final saved = SettingsStore.instance.getBool(storageKey);
    enabled.value = _buildDefault || saved == true;
    if (enabled.value) _startDetail();
  }

  Future<void> setEnabled(bool on) async {
    if (enabled.value == on) return;
    enabled.value = on;
    await SettingsStore.instance.setBool(storageKey, on);
    if (on) {
      _startDetail();
      _event('diagnostics.on');
    } else {
      _event('diagnostics.off');
      // 关闭前把手上这段送出去，避免用户白采
      unawaited(_flush());
      _resetDetail();
    }
  }

  /// 当前页面（App）标识：工作台 / photo / video ……
  void setSurface(String id) {
    if (id.isEmpty || id == _surface) return;
    _surface = id;
    if (enabled.value) _event('surface:$id');
  }

  /// 由传输层回调；只要超过阈值就记一条慢接口日志（关闭状态下也生效，低频）。
  void recordRequest({
    required String method,
    required String path,
    required int status,
    required int ms,
    required int bytes,
  }) {
    if (path.contains('/system/perf-report')) return;
    final slow = ms >= 1000 || bytes >= 2 * 1024 * 1024;
    // 关闭且不慢：直接返回，正常使用几乎零开销
    if (!enabled.value && !slow) return;
    final route = '$method ${_normalizePath(path)}';
    if (enabled.value) {
      final agg = _requests.putIfAbsent(route, _ReqAgg.new);
      agg.add(ms, bytes, status >= 400);
    }
    // 慢接口 / 大响应：关闭状态下也留一行证据，但每条路由 5 分钟最多一条
    if (slow) _logSlowRoute(route, ms, bytes, status);
  }

  /// 记录一次可解释的事件（页面切换 / 前后台 / 手动上报）
  void mark(String name, [Map<String, Object?>? extra]) {
    if (!enabled.value) return;
    _event(name, extra);
  }

  /// 立即上报一次（不等到 30 s 周期）
  Future<void> reportNow() async {
    if (enabled.value) await _flush();
  }

  /// 设置页展示的当前快照（不落盘、不上报）
  String get summaryLine {
    final s = snapshot();
    final fps = s['fps'];
    return 'fps=$fps 慢帧33=${s['slow33']} '
        'build p95=${s['buildP95']}ms raster p95=${s['rasterP95']}ms';
  }

  // ---------------------------------------------------------------- 内部实现

  void _startDetail() {
    _windowStart = DateTime.now();
    _events.clear();
    _events.add(<String, Object?>{
      'ts': DateTime.now().millisecondsSinceEpoch,
      'name': 'diagnostics.start',
      'surface': _surface,
      'app': _app,
    });
    unawaited(_loadDevice());
    if (localLogPath.value.isEmpty) {
      unawaited(
        device.perfLogPath().then((p) {
          if (p != null) localLogPath.value = p;
        }),
      );
    }
  }

  void _resetDetail() {
    _total.clear();
    _build.clear();
    _raster.clear();
    _surfaces.clear();
    _slowest.clear();
    _requests.clear();
    _events.clear();
    _windowStart = DateTime.now();
  }

  Future<void> _loadDevice() async {
    try {
      final info = await device.collectDeviceInfo();
      _device = <String, Object?>{
        ...info,
        'app': _app,
        'appVersion': kAppVersion,
        'platform': defaultTargetPlatform.name,
        'isWeb': kIsWeb,
        'boot': _bootMarks == null ? null : Map<String, int>.of(_bootMarks!),
      };
    } catch (_) {
      _device = <String, Object?>{
        'app': _app,
        'appVersion': kAppVersion,
        'platform': defaultTargetPlatform.name,
        'isWeb': kIsWeb,
      };
    }
  }

  void _event(String name, [Map<String, Object?>? extra]) {
    if (_events.length >= 600) _events.removeAt(0);
    _events.add(<String, Object?>{
      'ts': DateTime.now().millisecondsSinceEpoch,
      'name': name,
      'surface': _surface,
      ...?extra,
    });
  }

  void _onTimings(List<FrameTiming> timings) {
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final t in timings) {
      final total = t.totalSpan.inMicroseconds / 1000.0;
      final build = t.buildDuration.inMicroseconds / 1000.0;
      final raster = t.rasterDuration.inMicroseconds / 1000.0;
      _frames += 1;
      _sumTotal += total;
      _sumBuild += build;
      _sumRaster += raster;
      if (total > _maxTotal) _maxTotal = total;
      if (build > _maxBuild) _maxBuild = build;
      if (raster > _maxRaster) _maxRaster = raster;
      if (total > 16.7) _slow16 += 1;
      if (total > 33) _slow33 += 1;
      if (total > 50) _slow50 += 1;

      if (!enabled.value) continue;
      _total.add(total);
      _build.add(build);
      _raster.add(raster);
      _surfaces
          .putIfAbsent(_surface, _SurfaceAgg.new)
          .add(total, build, raster);
      if (total > 33) {
        _slowest.add(<String, Object?>{
          'ts': now,
          'surface': _surface,
          'total': _r1(total),
          'build': _r1(build),
          'raster': _r1(raster),
        });
        if (_slowest.length > 20) _slowest.removeAt(0);
      }
    }
  }

  void _tick() {
    final elapsed = DateTime.now().difference(_windowStart);
    if (elapsed < _reportEvery) return;
    if (!enabled.value) {
      // 关闭状态：按 60 s 打一行轻量摘要，和其它客户端日志同一份
      if (elapsed < _summaryEvery || _frames == 0) return;
      _emitSummaryToLog(elapsed);
      return;
    }
    unawaited(_flush());
  }

  void _emitSummaryToLog(Duration elapsed) {
    final frames = _frames;
    if (frames == 0) return;
    final secs = elapsed.inMilliseconds / 1000.0;
    ClientLogger.instance.info(
      '$frames帧/${secs.toStringAsFixed(0)}s '
      'fps=${(frames / secs).toStringAsFixed(1)} '
      '平均${(_sumTotal / frames).toStringAsFixed(1)}ms '
      '慢帧16=$_slow16 慢帧33=$_slow33 '
      'build=${(_sumBuild / frames).toStringAsFixed(1)}ms '
      'raster=${(_sumRaster / frames).toStringAsFixed(1)}ms '
      '最差 total=${_maxTotal.toStringAsFixed(0)}ms '
      'build=${_maxBuild.toStringAsFixed(0)}ms '
      'raster=${_maxRaster.toStringAsFixed(0)}ms',
      route: 'perf.frame',
    );
    _resetWindowCounters();
  }

  void _resetWindowCounters() {
    _frames = 0;
    _sumTotal = 0;
    _sumBuild = 0;
    _sumRaster = 0;
    _maxTotal = 0;
    _maxBuild = 0;
    _maxRaster = 0;
    _slow16 = 0;
    _slow33 = 0;
    _slow50 = 0;
    _windowStart = DateTime.now();
  }

  Map<String, Object?> snapshot() {
    final frames = _frames;
    final secs =
        DateTime.now().difference(_windowStart).inMilliseconds / 1000.0;
    final cache = PaintingBinding.instance.imageCache;
    return <String, Object?>{
      'app': _app,
      'surface': _surface,
      // 界面参数：同一台机器上对比「流畅模式开/关」时靠这两个字段区分样本
      'style': AppSettings.instance.styleId.value,
      'reduceBlur': AppSettings.instance.reduceBlur.value,
      'windowSec': _r1(secs),
      'frames': frames,
      'fps': frames == 0 || secs <= 0 ? 0 : _r1(frames / secs),
      'totalAvg': frames == 0 ? 0 : _r1(_sumTotal / frames),
      'totalP50': _r1(_total.percentile(50)),
      'totalP90': _r1(_total.percentile(90)),
      'totalP99': _r1(_total.percentile(99)),
      'totalMax': _r1(_maxTotal),
      'buildAvg': frames == 0 ? 0 : _r1(_sumBuild / frames),
      'buildP95': _r1(_build.percentile(95)),
      'buildMax': _r1(_maxBuild),
      'rasterAvg': frames == 0 ? 0 : _r1(_sumRaster / frames),
      'rasterP95': _r1(_raster.percentile(95)),
      'rasterMax': _r1(_maxRaster),
      'slow16': _slow16,
      'slow33': _slow33,
      'slow50': _slow50,
      'surfaces': <String, Object?>{
        for (final e in _surfaces.entries) e.key: e.value.toJson(),
      },
      'requests': <Object?>[
        for (final e in _requests.entries)
          <String, Object?>{'route': e.key, ...e.value.toJson()},
      ],
      'images': <String, Object?>{
        'live': cache.liveImageCount,
        'currentBytes': cache.currentSizeBytes,
        'currentCount': cache.currentSize,
        'maxBytes': cache.maximumSizeBytes,
      },
    };
  }

  Future<void> _flush() async {
    if (!enabled.value) return;
    final started = DateTime.now();
    final snap = snapshot();
    final body = <String, Object?>{
      'kind': 'client-perf',
      'ts': started.millisecondsSinceEpoch,
      'device': <String, Object?>{
        ...?_device,
        'app': _app,
        'platform': defaultTargetPlatform.name,
        'appVersion': kAppVersion,
        // 启动阶段时间点在 runColanasApp 里持续补写，这里取最新快照
        if (_bootMarks != null) 'boot': Map<String, int>.of(_bootMarks!),
      },
      'window': snap,
      'slowest': List<Map<String, Object?>>.of(_slowest),
      'events': List<Map<String, Object?>>.of(_events),
    };
    final line = jsonEncode(body);

    // 1) 本机文件：服务端连不上时也有据可查
    try {
      final p = await device.appendPerfLine(line);
      if (p != null && p.isNotEmpty) localLogPath.value = p;
    } catch (_) {}

    // 2) 服务端文件 + 日志行
    var ok = false;
    try {
      final base = ApiSession.instance.baseUrl;
      if (base.isNotEmpty && ApiSession.instance.token != null) {
        final res = await http
            .post(
              Uri.parse('$base/api/v1/system/perf-report'),
              headers: <String, String>{
                ...ApiSession.instance.authHeaders,
                'content-type': 'application/json',
              },
              body: line,
            )
            .timeout(const Duration(seconds: 10));
        ok = res.statusCode >= 200 && res.statusCode < 300;
        if (ok) {
          try {
            final decoded = jsonDecode(utf8.decode(res.bodyBytes));
            if (decoded is Map && decoded['file'] is String) {
              serverLogPath.value = decoded['file'] as String;
            }
          } catch (_) {}
        }
      }
    } catch (_) {
      ok = false;
    }
    lastReport.value = ok
        ? '${_fmtTime(started)} 已上报服务端'
        : '${_fmtTime(started)} 上报失败（已存本机文件）';

    _slowest.clear();
    _events.clear();
    // 每个上报窗口独立统计：不清环形采样会让 p95 混入上一段时间的慢帧，
    // 出现「slow33=0 但 p95=55ms」这种自相矛盾的数字。
    _total.clear();
    _build.clear();
    _raster.clear();
    _surfaces.clear();
    _resetWindowCounters();
  }

  static String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}:'
      '${t.second.toString().padLeft(2, '0')}';

  static double _r1(double v) =>
      double.parse(v.isNaN ? '0' : v.toStringAsFixed(1));

  static final RegExp _digits = RegExp(r'^\d+$');
  static final RegExp _longId = RegExp(r'^[0-9a-fA-F-]{16,}$');

  static String _normalizePath(String path) {
    final out = <String>[];
    for (final seg in path.split('/')) {
      if (seg.isEmpty) continue;
      // 数字 / 长 id / 文件名统一成占位，避免每个 id 一条 route
      if (_digits.hasMatch(seg) || _longId.hasMatch(seg) || seg.contains('.')) {
        out.add(':id');
      } else {
        out.add(seg);
      }
    }
    return '/${out.join('/')}';
  }

  final Map<String, DateTime> _slowRouteSeen = <String, DateTime>{};

  void _logSlowRoute(String route, int ms, int bytes, int status) {
    final now = DateTime.now();
    final last = _slowRouteSeen[route];
    if (last != null && now.difference(last) < const Duration(minutes: 5)) {
      return;
    }
    _slowRouteSeen[route] = now;
    if (_slowRouteSeen.length > 120) _slowRouteSeen.clear();
    ClientLogger.instance.warn(
      '慢接口 ${ms}ms ${_fmtBytes(bytes)} status=$status',
      route: 'perf.http $route',
    );
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / 1024 / 1024).toStringAsFixed(2)}MB';
  }
}

/// 定长环形缓冲：每帧写入 O(1)，不产生持续的内存增长。
class _Ring {
  _Ring(this.capacity);

  final int capacity;
  final List<double> _buf = <double>[];
  int _next = 0;

  void add(double v) {
    if (_buf.length < capacity) {
      _buf.add(v);
    } else {
      _buf[_next] = v;
      _next = (_next + 1) % capacity;
    }
  }

  void clear() {
    _buf.clear();
    _next = 0;
  }

  double percentile(int p) {
    if (_buf.isEmpty) return 0;
    final sorted = List<double>.of(_buf)..sort();
    final idx = ((p / 100) * (sorted.length - 1)).round().clamp(
      0,
      sorted.length - 1,
    );
    return sorted[idx];
  }
}

class _SurfaceAgg {
  int frames = 0;
  double sumTotal = 0;
  double sumBuild = 0;
  double sumRaster = 0;
  double maxTotal = 0;
  double maxRaster = 0;
  int slow33 = 0;
  final _Ring total = _Ring(600);
  final _Ring build = _Ring(600);
  final _Ring raster = _Ring(600);

  void add(double t, double b, double r) {
    frames += 1;
    sumTotal += t;
    sumBuild += b;
    sumRaster += r;
    if (t > maxTotal) maxTotal = t;
    if (r > maxRaster) maxRaster = r;
    if (t > 33) slow33 += 1;
    total.add(t);
    build.add(b);
    raster.add(r);
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'frames': frames,
    'avg': frames == 0
        ? 0
        : double.parse((sumTotal / frames).toStringAsFixed(1)),
    'p90': double.parse(total.percentile(90).toStringAsFixed(1)),
    'max': double.parse(maxTotal.toStringAsFixed(1)),
    'buildP95': double.parse(build.percentile(95).toStringAsFixed(1)),
    'rasterP95': double.parse(raster.percentile(95).toStringAsFixed(1)),
    'rasterMax': double.parse(maxRaster.toStringAsFixed(1)),
    'slow33': slow33,
  };
}

class _ReqAgg {
  int count = 0;
  int errors = 0;
  double sumMs = 0;
  double maxMs = 0;
  double sumBytes = 0;
  final _Ring samples = _Ring(120);

  void add(int ms, int bytes, bool error) {
    count += 1;
    sumMs += ms;
    sumBytes += bytes;
    if (ms > maxMs) maxMs = ms.toDouble();
    if (error) errors += 1;
    samples.add(ms.toDouble());
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'count': count,
    'avg': count == 0 ? 0 : double.parse((sumMs / count).toStringAsFixed(1)),
    'p95': double.parse(samples.percentile(95).toStringAsFixed(1)),
    'max': double.parse(maxMs.toStringAsFixed(1)),
    'avgKB': count == 0
        ? 0
        : double.parse((sumBytes / count / 1024).toStringAsFixed(1)),
    'errors': errors,
  };
}
