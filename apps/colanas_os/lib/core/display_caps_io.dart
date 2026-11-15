import 'dart:io';

import 'package:flutter/services.dart';

import 'display_caps.dart';

/// Android：问系统「这块屏支持哪些 HDR 类型」。
///
/// 走原生通道 `com.colanas.os/display_caps`（见 `MainActivity.kt`），
/// 读 `Display.getHdrCapabilities().getSupportedHdrTypes()`：
///   1 = Dolby Vision，2 = HDR10，3 = HLG，4 = HDR10+。
///
/// 其它平台直接返回 [DisplayCaps.unknown]：桌面显示器 / 浏览器自己不报能力，
/// 猜错会把 HDR 片源无谓地转码，反而更差。
Future<DisplayCaps> readDisplayCaps() async {
  if (!Platform.isAndroid) return DisplayCaps.unknown;
  try {
    const channel = MethodChannel('com.colanas.os/display_caps');
    final raw = await channel.invokeMethod<List<dynamic>>('hdrTypes');
    if (raw == null) return DisplayCaps.unknown;
    final types = <int>{};
    for (final v in raw) {
      final n = v is int ? v : int.tryParse('$v');
      if (n != null) types.add(n);
    }
    return DisplayCaps(hdrTypes: types, known: true);
  } catch (_) {
    // 通道还没装（旧安装包）/ 权限异常：当成未知，不影响播放
    return DisplayCaps.unknown;
  }
}
