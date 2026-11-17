import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../core/android_notification_permission.dart';

/// 下载期间的前台服务（仅 Android 有意义）。
///
/// 没有它，手机一息屏 / 切后台，Android 会冻结进程：下载循环断掉，回来看是
/// 「进度停在 40% 不动」。桌面端不需要 —— Windows 进程不会被这么掐。
///
/// 一切失败都吞掉：没有通知栏也得能下载（前台服务只是保活手段，不是前置条件）。
class OfflineBackground {
  OfflineBackground._();

  static const _channel = MethodChannel('com.colanas.os/offline_download');

  static bool get _supported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool _started = false;

  /// 开始下载时调一次。会顺带申请通知权限（Android 13+ 没权限通知栏看不到）。
  static Future<void> start(String title, String text) async {
    if (!_supported || _started) return;
    try {
      await ensureAndroidNotificationPermission();
      final ok = await _channel.invokeMethod<bool>('start', {
        'title': title,
        'text': text,
      });
      _started = ok == true;
    } catch (_) {
      // 通道异常 / 系统拒绝后台启动：静默降级
    }
  }

  /// 进度更新。[progress] < 0 表示不确定进度（转码阶段）。
  static Future<void> update(String text, {int progress = -1, int max = 100}) async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('update', {
        'text': text,
        'progress': progress,
        'max': max,
      });
    } catch (_) {
      // 忽略
    }
  }

  /// 所有任务结束时调一次。
  static Future<void> stop() async {
    if (!_supported || !_started) return;
    _started = false;
    try {
      await _channel.invokeMethod<bool>('stop');
    } catch (_) {
      // 忽略
    }
  }
}
