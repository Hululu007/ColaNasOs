import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:nas_core/nas_core.dart';

import '../../core/android_notification_permission.dart';
import '../../core/audio_background.dart';
import '../../core/audio_focus.dart';
import '../../core/client_log.dart';
import '../../core/session.dart';
import '../music/media_session.dart';

/// AI 新闻的**全局**播放器。
///
/// 不复用 `MusicPlaybackService`：那个服务的队列是 `MusicTrack`，走曲库 stream 路由；
/// 播客 mp3 在数据目录里，硬塞进音乐队列会冲掉用户的歌单。
///
/// 为什么是单例（2026-11-06）：以前它是页面 State 的成员，页面重建 / 热重载时
/// 旧的 media_kit Player（Web 端是一个挂在 globalContext 里的 `<video>` 元素）来不及
/// dispose，会继续出声；新页面又建一个 Player，就成了「两路音频同时播」。
/// 现在播放器与页面生命周期解耦：切模块、最小化、熄屏都不断，全应用也只有这一个实例。
class BlogPlayer extends ChangeNotifier {
  BlogPlayer._();

  static final BlogPlayer instance = BlogPlayer._();

  Player? _player;
  final List<StreamSubscription<Object?>> _subs = [];

  /// 停播看门狗：mpv 对「长连接被对方关掉、又不再续传」不会报错，也不会自己
  /// 重连，表现就是播到某个位置后彻底安静、界面上还显示「正在播放」。
  /// 2026-11-20 早上的实测：08:27 开播，那条 206 请求 6.8 秒就被断开，
  /// 之后 20 分钟一个请求都没有，26 分钟的一期播到 20 分钟处停死。
  Timer? _watchdog;
  Duration _lastProgress = Duration.zero;
  DateTime _lastProgressAt = DateTime.now();
  int _stallRecoveries = 0;
  bool _recovering = false;

  static const Duration _stallCheckInterval = Duration(seconds: 5);
  static const Duration _stallThreshold = Duration(seconds: 20);

  /// 当前播放队列（可编辑：加入 / 移除 / 跳转）。
  List<BlogEpisodeItem> _queue = const [];

  /// 列表页给出的全部已完成期次：播放列表弹层「添加期次」从这里挑。
  List<BlogEpisodeItem> _library = const [];

  int _index = -1;

  Duration position = Duration.zero;
  Duration duration = Duration.zero;
  bool playing = false;
  bool loading = false;
  String? error;
  double rate = 1;

  List<BlogEpisodeItem> get queue => _queue;
  List<BlogEpisodeItem> get library => _library;
  int get index => _index;

  BlogEpisodeItem? get episode =>
      _index >= 0 && _index < _queue.length ? _queue[_index] : null;

  String? get episodeId => episode?.id;

  bool isCurrent(String id) => episode?.id == id;

  bool inQueue(String id) => _queue.any((e) => e.id == id);

  Player _ensure() {
    final existing = _player;
    if (existing != null) return existing;
    final p = Player();
    _subs.add(p.stream.position.listen((v) {
      position = v;
      // 只有真的往前走了才算「活着」：暂停、拖动时位置本来就不动
      if (v > _lastProgress + const Duration(milliseconds: 300)) {
        _lastProgress = v;
        _lastProgressAt = DateTime.now();
        _stallRecoveries = 0;
      }
      // 锁屏面板的进度：只有活跃音源能写，别把音乐的系统面板抢过来
      if (AudioFocus.instance.holds(this)) {
        if (kIsWeb) {
          updateMediaSessionPosition(duration: duration, position: position);
        } else {
          // 原生端走前台服务；内部按 900ms 节流，不会每 100ms 刷一次通知
          _syncMediaSession();
        }
      }
      notifyListeners();
    }));
    _subs.add(p.stream.duration.listen((v) {
      duration = v;
      _syncMediaSession();
      notifyListeners();
    }));
    _subs.add(p.stream.playing.listen((v) {
      playing = v;
      // 从暂停恢复的那一刻重新起算：暂停期间位置不动是用户意愿，
      // 不重置的话恢复播放会立刻被看门狗判成「卡死」。
      if (v) _lastProgressAt = DateTime.now();
      _syncMediaSession();
      notifyListeners();
    }));
    _subs.add(p.stream.completed.listen((done) {
      if (done) unawaited(next());
    }));
    _subs.add(p.stream.error.listen((message) {
      error = message;
      loading = false;
      notifyListeners();
    }));
    _player = p;
    _startWatchdog();
    return p;
  }

  void _startWatchdog() {
    _watchdog?.cancel();
    _lastProgress = position;
    _lastProgressAt = DateTime.now();
    _watchdog = Timer.periodic(_stallCheckInterval, (_) => _checkStall());
  }

  void _checkStall() {
    if (_recovering || loading || error != null) return;
    if (!playing || _player == null) return;
    if (duration <= Duration.zero) return;
    if (episode == null) return;
    if (DateTime.now().difference(_lastProgressAt) < _stallThreshold) return;
    unawaited(_recoverFromStall());
  }

  /// 卡住就重新取一次播放地址，从当前位置续上。
  ///
  /// 重连要重新走 `blogAudioUrl`：URL 里带的是短期令牌，前一次链接可能早就
  /// 过了有效期，拿旧地址重试只会 401。连续三次都续不上就停下来报错，
  /// 不能无限重连把界面卡在「加载中」。
  Future<void> _recoverFromStall() async {
    if (_recovering) return;
    _recovering = true;
    final at = position;
    _stallRecoveries += 1;
    ClientLogger.instance.warn(
      '播客播放停滞 ${_stallThreshold.inSeconds}s，第 $_stallRecoveries 次重连',
      route: 'blog.player/${episodeId ?? '-'}',
      detail:
          'pos=${at.inMilliseconds}ms dur=${duration.inMilliseconds}ms '
          'playing=$playing rate=$rate',
    );
    try {
      if (_stallRecoveries > 3) {
        playing = false;
        loading = false;
        error = I18n.instance.tr('blog.loadFailed');
        notifyListeners();
        return;
      }
      await _load(resumeAt: at);
    } catch (e) {
      error = '$e';
      loading = false;
      notifyListeners();
    } finally {
      _recovering = false;
      _lastProgress = position;
      _lastProgressAt = DateTime.now();
    }
  }

  /// 只暂停，不释放资源：交给 AudioFocus 在别的音源开播时调用。
  Future<void> pause() async {
    await _player?.pause();
    playing = false;
    notifyListeners();
  }

  /// 播放某一期：默认把列表里的全部已完成期次当成队列（自动连播）。
  /// [queue] 同时进 `_library`，播放列表弹层可以再把其它期次加进来。
  Future<void> play(BlogEpisodeItem target, List<BlogEpisodeItem> queue) async {
    final playable = queue.where((e) => e.status == 'done').toList(growable: false);
    if (playable.isEmpty) return;
    _library = playable;
    _queue = playable;
    _index = playable.indexWhere((e) => e.id == target.id).clamp(0, playable.length - 1);
    await _load();
  }

  /// 追加到队尾；队列空时直接开播，不冲掉已有的 `_library`。
  Future<void> enqueue(BlogEpisodeItem ep) async {
    if (ep.status != 'done' || inQueue(ep.id)) return;
    if (_queue.isEmpty) {
      _queue = [ep];
      _index = 0;
      await _load();
      return;
    }
    _queue = [..._queue, ep];
    notifyListeners();
  }

  /// 插到当前期后面（下一期就放它）。
  Future<void> enqueueNext(BlogEpisodeItem ep) async {
    if (ep.status != 'done') return;
    if (_queue.isEmpty) {
      _queue = [ep];
      _index = 0;
      await _load();
      return;
    }
    final existing = _queue.indexWhere((e) => e.id == ep.id);
    final next = [..._queue];
    if (existing >= 0) next.removeAt(existing);
    final at = (_index + 1).clamp(0, next.length);
    next.insert(at, ep);
    _queue = next;
    if (existing >= 0 && existing < _index) _index -= 1;
    notifyListeners();
  }

  Future<void> jumpTo(int i) async {
    if (i < 0 || i >= _queue.length) return;
    _index = i;
    await _load();
  }

  Future<void> removeAt(int i) async {
    if (i < 0 || i >= _queue.length) return;
    if (_queue.length == 1) {
      await clearQueue();
      return;
    }
    final next = [..._queue]..removeAt(i);
    _queue = next;
    if (i < _index) {
      _index -= 1;
      notifyListeners();
      return;
    }
    if (i == _index) {
      _index = _index.clamp(0, next.length - 1);
      await _load();
      return;
    }
    notifyListeners();
  }

  Future<void> clearQueue() async {
    await _player?.stop();
    _queue = const [];
    _index = -1;
    position = Duration.zero;
    duration = Duration.zero;
    playing = false;
    _stallRecoveries = 0;
    _lastProgress = Duration.zero;
    _lastProgressAt = DateTime.now();
    AudioFocus.instance.release(this);
    _clearMediaSession();
    notifyListeners();
  }

  Future<void> setRate(double value) async {
    rate = value.clamp(0.5, 2.0);
    await _player?.setRate(rate);
    notifyListeners();
  }

  Future<void> _load({Duration? resumeAt}) async {
    final current = episode;
    if (current == null) return;
    // 开播前先让音乐 / 音色试听让路，避免两路声音叠在一起
    await AudioFocus.instance.request(this, pause);
    error = null;
    loading = true;
    // 续播时不要把进度条闪回 0：界面按断点画，seek 成功前也不会跳
    position = resumeAt ?? Duration.zero;
    duration = Duration(seconds: current.durationSec.round());
    notifyListeners();
    try {
      // Android 13+ 不给通知权限，前台服务挂不住，切后台 / 熄屏就被系统掐掉。
      // 音乐链路早申请了，播客以前漏了这一步（2026-11-10 反馈「切后台就断」）。
      if (!kIsWeb) {
        await ensureAndroidNotificationPermission();
        // 启动时初始化可能失败过（权限当时还没给），这里幂等重试一次
        await audioBackground.ensureStarted(
          channelName: I18n.instance.tr('audio.channelName'),
        );
      }
      final res = await ApiSession.instance.client.blogAudioUrl(id: current.id);
      final url = '${ApiSession.instance.baseUrl}${res.url}';
      final p = _ensure();
      await p.open(Media(url), play: true);
      if (resumeAt != null && resumeAt > Duration.zero) {
        await p.seek(resumeAt);
      }
      await p.setRate(rate);
      // open(play:true) 的 playing 流可能晚一拍；先把面板推成「正在播」，
      // 前台服务要看到 playing=true 才会真正常驻。
      playing = true;
      loading = false;
      _lastProgress = position;
      _lastProgressAt = DateTime.now();
      _syncMediaSession();
      notifyListeners();
    } catch (e) {
      error = '$e';
      loading = false;
      notifyListeners();
    }
  }

  Future<void> toggle() async {
    final p = _player;
    if (p == null) {
      if (episode != null) await _load();
      return;
    }
    // 从暂停恢复也是「开播」，同样要抢焦点
    if (!playing) {
      _lastProgressAt = DateTime.now();
      await AudioFocus.instance.request(this, pause);
    }
    await p.playOrPause();
  }

  Future<void> seek(Duration to) async {
    // 手动拖动后重新起算：不然「往回调」会被看门狗当成停滞
    _lastProgress = to;
    _lastProgressAt = DateTime.now();
    _stallRecoveries = 0;
    await _player?.seek(to);
  }

  Future<void> next() async {
    if (_queue.isEmpty) return;
    _index = (_index + 1) % _queue.length;
    await _load();
  }

  Future<void> prev() async {
    if (_queue.isEmpty) return;
    _index = (_index - 1 + _queue.length) % _queue.length;
    await _load();
  }

  Future<void> stop() async {
    final held = AudioFocus.instance.holds(this);
    await _player?.stop();
    playing = false;
    _stallRecoveries = 0;
    _lastProgressAt = DateTime.now();
    AudioFocus.instance.release(this);
    if (held) _clearMediaSession();
    notifyListeners();
  }

  /// 系统媒体面板（锁屏 / 通知栏 / 耳机键）。Web 端有它，Android 才把这一路
  /// 当成真正的媒体会话，切后台 / 熄屏时不会被浏览器冻掉；桌面 / 原生端是空实现。
  void _syncMediaSession() {
    final current = episode;
    // 只有持焦点的那一路能写：暂停方不能把音乐（或反过来）的面板抢过去
    if (current == null || !AudioFocus.instance.holds(this)) return;
    if (!kIsWeb) {
      // 原生 Android：推给前台服务，通知栏 / 锁屏才有控制、熄屏才不被冻结
      audioBackground.update(
        AudioSnapshot(
          owner: this,
          id: current.id,
          title: current.title,
          artist: I18n.instance.tr('blog.nav.aiNews'),
          album: '',
          playing: playing,
          position: position,
          duration: duration,
          onPlay: () {
            if (!playing) unawaited(toggle());
          },
          onPause: () {
            if (playing) unawaited(pause());
          },
          onNext: () => unawaited(next()),
          onPrevious: () => unawaited(prev()),
          onSeek: (to) => unawaited(seek(to)),
          onStop: () => unawaited(stop()),
        ),
      );
      return;
    }
    updateMediaSession(
      title: current.title,
      artist: I18n.instance.tr('blog.nav.aiNews'),
      album: '',
      playing: playing,
      onPlay: () {
        if (!playing) unawaited(toggle());
      },
      onPause: () {
        if (playing) unawaited(pause());
      },
      onNext: () => unawaited(next()),
      onPrevious: () => unawaited(prev()),
    );
    updateMediaSessionPosition(duration: duration, position: position);
  }

  void _clearMediaSession() {
    if (!kIsWeb) {
      audioBackground.clear(this);
      return;
    }
    // 把面板标成「没在播」，handle 留着也无害：下一次播放会重新注册
    updateMediaSession(
      title: '',
      artist: '',
      album: '',
      playing: false,
      onPlay: () {},
      onPause: () {},
      onNext: () {},
      onPrevious: () {},
    );
  }

  /// 页面不要调它：单例要跨页面存活。保留给应用整体退出时用。
  @override
  void dispose() {
    AudioFocus.instance.release(this);
    _watchdog?.cancel();
    _watchdog = null;
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    final p = _player;
    _player = null;
    unawaited(_disposePlayer(p));
    super.dispose();
  }

  /// 先同步 pause 再异步 dispose：异步 dispose 在热重载时容易被丢掉，
  /// 留下一个还在出声的 `<video>` 元素。
  Future<void> _disposePlayer(Player? p) async {
    if (p == null) return;
    try {
      await p.pause();
      await p.dispose();
    } catch (_) {
      // 已经销毁过就算了
    }
  }
}
