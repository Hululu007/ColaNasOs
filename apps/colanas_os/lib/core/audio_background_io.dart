import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'audio_background.dart';
import 'client_log.dart';

/// 只在 Android 上真正拉起媒体面板；其余 io 平台（Windows / macOS / Linux）
/// 保持改动前的行为 —— 桌面窗口常驻，不需要系统托底。
AudioBackground createAudioBackground() =>
    Platform.isAndroid ? _AndroidAudioBackground() : NoopAudioBackground();

/// Android 媒体面板（通知栏 / 锁屏 / 耳机键）。
///
/// 为什么不再用 `audio_service` 自动生成的通知（2026-11-24）：
/// 用户实测「通知权限已给、卸载重装也没有状态栏播放器」，而视频那套自建前台服务
/// （`VideoMediaSessionService`）在同机型上正常 —— 第三方库自动挂的媒体通知
/// 在部分国产 ROM 上就是不显示。现在改由 `AudioPanelService`（原生）自己持
/// MediaSession + MediaStyle 通知，本类只负责推快照 / 收命令，
/// 播放链路（media_kit）一行没动。
class _AndroidAudioBackground implements AudioBackground {
  static const MethodChannel _channel = MethodChannel(
    'com.colanas.os/audio_panel',
  );

  /// 最新快照：命令总是转给它，所以即使面板是节流过的，按下去也作用于当前音源。
  AudioSnapshot? _latest;

  /// 上次真正写面板的内容：拿它和推送来的快照比，只有「面子变了」才跨 channel。
  AudioSnapshot? _pushed;

  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  bool _installed = false;

  /// 只在第一次成功推面板时记一条，避免每 5 秒刷日志。
  bool _loggedFirstPush = false;

  /// 推送失败也只记一条：原生面板偶发不可用时不应该刷满日志。
  bool _loggedPushFailure = false;

  /// 播放进度大约每秒 10 次，全推过去会让通知栏一直重绘。
  static const _minPushGap = Duration(milliseconds: 900);

  @override
  Future<void> ensureStarted({required String channelName}) async {
    if (_installed) return;
    _installed = true;
    _channel.setMethodCallHandler(_onNativeCommand);
  }

  /// 面板按键 → 当前音源的回调。
  Future<Object?> _onNativeCommand(MethodCall call) async {
    if (call.method != 'command') return null;
    final raw = call.arguments;
    final args = raw is Map ? raw : const <Object?, Object?>{};
    final action = '${args['action'] ?? ''}';
    final positionMs = (args['positionMs'] as num?)?.toInt() ?? 0;
    final s = _latest;
    if (s == null) return null;
    switch (action) {
      case 'play':
        s.onPlay();
      case 'pause':
        s.onPause();
      // 通知上的单键在原生侧不知道当前有没有在播，交给这里判断
      case 'toggle':
        s.playing ? s.onPause() : s.onPlay();
      case 'next':
        s.onNext();
      case 'previous':
        s.onPrevious();
      case 'stop':
        s.onStop();
      case 'seek':
        s.onSeek(Duration(milliseconds: positionMs));
    }
    return null;
  }

  @override
  void update(AudioSnapshot snapshot) {
    _latest = snapshot;
    final now = DateTime.now();
    final changed = _pushed == null || !_pushed!.sameSurface(snapshot);
    if (!changed && now.difference(_lastPush) < _minPushGap) return;
    _pushed = snapshot;
    _lastPush = now;
    unawaited(_push(snapshot));
  }

  Future<void> _push(AudioSnapshot snapshot) async {
    try {
      await _channel.invokeMethod<bool>('update', <String, Object?>{
        'title': snapshot.title,
        'artist': snapshot.artist ?? '',
        'playing': snapshot.playing,
        'positionMs': snapshot.position.inMilliseconds,
        'durationMs': snapshot.duration.inMilliseconds,
      });
      if (!_loggedFirstPush) {
        _loggedFirstPush = true;
        ClientLogger.instance.info(
          '媒体面板首次推送',
          route: 'audio.panel',
          detail: 'title=${snapshot.title} playing=${snapshot.playing}',
        );
      }
    } catch (e) {
      // 面板是增强项：推送失败不能影响播放
      if (!_loggedPushFailure) {
        _loggedPushFailure = true;
        ClientLogger.instance.warn('媒体面板推送失败：$e', route: 'audio.panel');
      }
    }
  }

  @override
  void clear(Object owner) {
    final current = _pushed;
    if (current != null && !identical(current.owner, owner)) return;
    _pushed = null;
    _latest = null;
    unawaited(_clear());
  }

  Future<void> _clear() async {
    try {
      await _channel.invokeMethod<bool>('clear');
    } catch (e) {
      debugPrint('媒体面板清理失败：$e');
    }
  }
}
