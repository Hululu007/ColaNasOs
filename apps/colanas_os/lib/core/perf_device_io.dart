import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:path_provider/path_provider.dart';

/// 性能诊断的桌面实现：设备/显卡信息、本机 JSONL 落盘。
///
/// 全部包了 try/catch：诊断自身失败绝不能影响应用启动或使用。

Map<String, Object?>? _deviceCache;

Future<Map<String, Object?>> collectDeviceInfo() async {
  if (_deviceCache != null) return _deviceCache!;
  final info = <String, Object?>{
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'cpuCores': Platform.numberOfProcessors,
    'locale': Platform.localeName,
    'rssMB': _mb(ProcessInfo.currentRss),
    'maxRssMB': _mb(ProcessInfo.maxRss),
    'pid': pid,
  };

  try {
    final view = ui.PlatformDispatcher.instance.implicitView;
    if (view != null) {
      final display = view.display;
      info['windowPhysical'] =
          '${view.physicalSize.width.toInt()}x${view.physicalSize.height.toInt()}';
      info['devicePixelRatio'] = view.devicePixelRatio;
      info['refreshRate'] = display.refreshRate;
      info['displayPhysical'] =
          '${display.size.width.toInt()}x${display.size.height.toInt()}';
    }
  } catch (_) {}

  final ps = await _queryWindowsHardware();
  if (ps != null) info.addAll(ps);

  _deviceCache = info;
  return info;
}

/// 本机诊断文件（按天一个文件）
Future<File?> _file() async {
  try {
    final dir = await getApplicationSupportDirectory();
    final d = Directory('${dir.path}${Platform.pathSeparator}perf');
    if (!await d.exists()) await d.create(recursive: true);
    final now = DateTime.now();
    final day =
        '${now.year}'
        '${now.month.toString().padLeft(2, '0')}'
        '${now.day.toString().padLeft(2, '0')}';
    return File('${d.path}${Platform.pathSeparator}perf-$day.jsonl');
  } catch (_) {
    return null;
  }
}

Future<String?> appendPerfLine(String line) async {
  try {
    final f = await _file();
    if (f == null) return null;
    await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
    return f.path;
  } catch (_) {
    return null;
  }
}

Future<String?> perfLogPath() async {
  final f = await _file();
  return f?.path;
}

double _mb(int bytes) => double.parse((bytes / 1024 / 1024).toStringAsFixed(1));

/// 一次 PowerShell 拿 CPU 名称 + 所有显卡（含驱动与当前分辨率/刷新率）。
///
/// 哪个 `Win32_VideoController` 报告了 `CurrentHorizontalResolution`，
/// 说明当前显示器挂在它上面 —— 这是判断「是不是核显在驱动 4K 屏」的关键证据。
///
/// `d3d10warp.dll` 出现在模块列表里说明 D3D 走了 WARP **软件光栅化**
/// （ANGLE 创建硬件 D3D11 设备失败的典型结果），这时再高的显卡也救不了帧率。
Future<Map<String, Object?>?> _queryWindowsHardware() async {
  if (!Platform.isWindows) return null;
  final script = _hwScript.replaceFirst('%PID%', '$pid');
  try {
    final r = await Process.run('powershell', <String>[
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      script,
    ], runInShell: false).timeout(const Duration(seconds: 12));
    final text = (r.stdout as String?)?.trim();
    if (text == null || text.isEmpty) return null;
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    return <String, Object?>{
      'cpuName': decoded['cpus'],
      'gpus': decoded['gpus'],
      'gfxModules': decoded['gfxModules'],
      'softwareRaster': decoded['warp'],
    };
  } catch (_) {
    return null;
  }
}

const String _hwScript = r'''
$cpus = @(Get-CimInstance Win32_Processor | ForEach-Object { $_.Name })
$gpus = @(Get-CimInstance Win32_VideoController | ForEach-Object {
  [pscustomobject]@{
    name = $_.Name
    driver = $_.DriverVersion
    driverDate = "$($_.DriverDate)"
    width = $_.CurrentHorizontalResolution
    height = $_.CurrentVerticalResolution
    refresh = $_.CurrentRefreshRate
    ramMB = if ($_.AdapterRAM) { [math]::Round($_.AdapterRAM / 1MB) } else { $null }
  }
})
$mods = @()
$warp = $false
try {
  $proc = Get-Process -Id %PID%
  $mods = @($proc.Modules | ForEach-Object { $_.ModuleName } |
    Where-Object { $_ -match '^(d3d10warp|libEGL|libGLESv2|d3d11|d3d12|dxgi|nvoglv64|nvwgf2umx|atio6axx|igdumdim64|igxelpicd64)\.dll$' })
  $warp = $mods -contains 'd3d10warp.dll'
} catch {}
@{ cpus = $cpus; gpus = $gpus; gfxModules = $mods; warp = $warp } |
  ConvertTo-Json -Compress -Depth 5
''';
