import 'dart:io';

import 'package:flutter/foundation.dart';

/// 「启动时最小化到托盘」的**原生侧标记**。
///
/// 为什么不直接用 window_manager 在 Dart 里 hide：原生 runner 只在 Flutter
/// **首帧回调**里 `Show()` 窗口（见 `windows/runner/flutter_window.cpp`），
/// 等 Dart 起来再 hide，用户会先看到一个空白窗口闪一下。
/// 所以走「文件存在 = 这次别 Show」：`utils.cpp#StartHiddenRequested()` 只判存在性，
/// 不解析 settings.json，判断不出来就当正常启动（宁可闪一下，不能起不来）。
///
/// ⚠️ 路径必须和 `windows/runner/utils.cpp` 里的完全一致；
/// 只有 Windows 有原生 runner，其他端全是空实现。
class StartHidden {
  StartHidden._();

  static const _dirName = 'ColaNasOs';
  static const _fileName = 'start-hidden';

  /// 原生侧读取的那个文件；非 Windows / 拿不到 APPDATA 时返回 null
  static String? get markerPath {
    if (kIsWeb || !Platform.isWindows) return null;
    final appData = Platform.environment['APPDATA'];
    if (appData == null || appData.isEmpty) return null;
    final sep = Platform.pathSeparator;
    return '$appData$sep$_dirName$sep$_fileName';
  }

  /// 让原生下次启动时保持隐藏（[on] = true）或正常显示
  static Future<void> sync(bool on) async {
    final path = markerPath;
    if (path == null) return;
    try {
      final file = File(path);
      if (on) {
        await file.parent.create(recursive: true);
        if (!await file.exists()) await file.writeAsString('1');
      } else if (await file.exists()) {
        await file.delete();
      }
    } catch (_) {
      // 只读目录 / 权限问题：静默降级成「正常显示窗口」，不影响启动
    }
  }
}
