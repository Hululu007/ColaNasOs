import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';

import 'audio_background.dart';
import 'client_log.dart';

/// 只在 Android 上真正拉起前台服务；其余 io 平台（Windows / macOS / Linux）
/// 保持改动前的行为 —— 桌面窗口常驻，不需要系统托底。
AudioBackground createAudioBackground() =>
    Platform.isAndroid ? _AndroidAudioBackground() : NoopAudioBackground();

/// 通知 / 锁屏面板的下发口。系统按键在这里收，转手交给最近一次快照的回调。
class _ColanasAudioHandler extends BaseAudioHandler with SeekHandler {
  /// 最新快照：命令总是转给它，所以即使面板是节流过的，按下去也作用于当前音源。
  AudioSnapshot? latest;

  /// 写一次面板（跨 channel，调用方负责节流）。
  void apply(AudioSnapshot? s) {
    if (s == null || s.id.isEmpty) {
      mediaItem.add(null);
      playbackState.add(
        playbackState.value.copyWith(
          controls: const [],
          systemActions: const {},
          processingState: AudioProcessingState.idle,
          playing: false,
          updatePosition: Duration.zero,
        ),
      );
      return;
    }
    mediaItem.add(
      MediaItem(
        id: s.id,
        title: s.title,
        artist: s.artist ?? '',
        album: s.album ?? '',
        artUri: (s.artUri ?? '').isEmpty ? null : Uri.tryParse(s.artUri!),
        duration: s.duration,
      ),
    );
    playbackState.add(
      playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (s.playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: const {MediaAction.seek},
        // 折叠态通知只放得下三个：上一期 / 播放暂停 / 下一期
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.ready,
        playing: s.playing,
        updatePosition: s.position,
        bufferedPosition: s.duration,
        speed: 1,
      ),
    );
  }

  @override
  Future<void> play() async => latest?.onPlay();

  @override
  Future<void> pause() async => latest?.onPause();

  @override
  Future<void> skipToNext() async => latest?.onNext();

  @override
  Future<void> skipToPrevious() async => latest?.onPrevious();

  @override
  Future<void> seek(Duration position) async => latest?.onSeek(position);

  @override
  Future<void> stop() async {
    final s = latest;
    latest = null;
    s?.onStop();
    await super.stop();
  }
}

class _AndroidAudioBackground implements AudioBackground {
  _ColanasAudioHandler? _handler;

  /// 上次真正写面板的内容：拿它和推送来的快照比，只有「面子变了」才跨 channel。
  AudioSnapshot? _pushed;

  DateTime _lastPush = DateTime.fromMillisecondsSinceEpoch(0);

  /// 上一次「拉起前台服务」的时间点与是否正在进行中。
  ///
  /// 启动阶段那一次失败**不能就此判死**：面板是增强项，失败时只是打日志静默降级，
  /// 之后再也没人重试 —— 用户看到的就是「听得到声音，但状态栏永远没有播放器」。
  /// 现在推送时如果还没有 handler，就按 [_retryGap] 补一次重试。
  DateTime _lastStartAttempt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _starting = false;
  String _channelName = '播放';

  /// 只在第一次成功推面板时记一条，避免每 5 秒刷日志。
  bool _loggedFirstPush = false;

  /// media_kit 的 position 流大约每秒 10 次，全推过去会让通知栏一直重绘。
  static const _minPushGap = Duration(milliseconds: 900);
  static const _retryGap = Duration(seconds: 10);

  @override
  Future<void> ensureStarted({required String channelName}) async {
    if (_handler != null || _starting) return;
    _channelName = channelName;
    _starting = true;
    try {
      _handler = await AudioService.init(
        builder: _ColanasAudioHandler.new,
        config: AudioServiceConfig(
          // 通道 id 带 v2：Android 会把「通知通道」的开关**跨卸载重装记住**，
          // 老通道一旦被关成静音/不显示，重装也不会恢复 —— 表现就是「权限都给了，
          // 状态栏还是没有播放器」。换一个 id 等于新建一条默认重要度的通道。
          androidNotificationChannelId: 'com.colanas.os.playback.v2',
          androidNotificationChannelName: channelName,
          // 播放时保持常驻：Android 才会把进程当前台服务，熄屏不被冻
          androidNotificationOngoing: true,
          // 暂停时**不要**摘掉通知：摘掉之后状态栏那条播放器就消失了，
          // 用户会以为「播放器没了」。停在通知栏里、按一下继续，才是媒体面板该有的样子。
          androidStopForegroundOnPause: false,
          androidNotificationClickStartsActivity: true,
        ),
      );
      ClientLogger.instance.info(
        '音频前台服务已就绪',
        route: 'audio.foreground',
        detail: channelName,
      );
    } catch (e) {
      // 增强项失败不能挡住启动：退化成「只有 App 在前台时才保证出声」。
      // 这条以前只 debugPrint（release 下看不见），面板不出来时无从判断。
      debugPrint('音频前台服务不可用：$e');
      ClientLogger.instance.warn('音频前台服务不可用：$e', route: 'audio.foreground');
      _handler = null;
    } finally {
      _starting = false;
      _lastStartAttempt = DateTime.now();
    }
  }

  @override
  void update(AudioSnapshot snapshot) {
    final h = _handler;
    if (h == null) {
      // 还没建起原生连接：按间隔补一次重试，别让面板永久性缺失
      final now = DateTime.now();
      if (!_starting && now.difference(_lastStartAttempt) > _retryGap) {
        _lastStartAttempt = now;
        unawaited(ensureStarted(channelName: _channelName));
      }
      return;
    }
    h.latest = snapshot;
    final now = DateTime.now();
    final changed = _pushed == null || !_pushed!.sameSurface(snapshot);
    if (!changed && now.difference(_lastPush) < _minPushGap) return;
    _pushed = snapshot;
    _lastPush = now;
    h.apply(snapshot);
    if (!_loggedFirstPush) {
      _loggedFirstPush = true;
      ClientLogger.instance.info(
        '媒体面板首次推送',
        route: 'audio.panel',
        detail: 'title=${snapshot.title} playing=${snapshot.playing}',
      );
    }
  }

  @override
  void clear(Object owner) {
    final current = _pushed;
    if (current != null && !identical(current.owner, owner)) return;
    _pushed = null;
    final h = _handler;
    if (h == null) return;
    h.latest = null;
    h.apply(null);
  }
}
