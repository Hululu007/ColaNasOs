import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart' show formatBytes, tr;
import 'package:path/path.dart' as p;

import '../../../core/session.dart';
import '../../../core/settings_store.dart';
import 'offline_background.dart';
import 'offline_models.dart';
import 'offline_preferences.dart';
import 'offline_storage.dart';
import 'offline_store.dart';
import 'offline_transfer.dart';

/// 一次下载请求（UI 从 `VideoItem` 攒出来，管理器不依赖任何页面类型）。
class OfflineRequest {
  const OfflineRequest({
    required this.itemId,
    required this.libraryId,
    required this.title,
    required this.spec,
    this.libraryName = '',
    this.seriesKey,
    this.seriesTitle,
    this.season,
    this.episode,
    this.totalEpisodes = 0,
    this.posterUrl,
    this.fallbackPosterUrl,
    this.replace = false,
    this.fetchSubtitles = false,
  });

  final String itemId;
  final String libraryId;
  final String libraryName;
  final String title;

  /// 目标参数（服务端 quote 收敛后的那份）
  final OfflineSpec spec;

  /// 剧集聚合键（`libraryId\u0000series`）；电影为空
  final String? seriesKey;
  final String? seriesTitle;
  final int? season;
  final int? episode;
  final int totalEpisodes;

  /// 整剧封面 / 影片海报的绝对地址（已含 baseUrl）
  final String? posterUrl;

  /// 海报接口拿不到时退回首帧（`/video/poster`）
  final String? fallbackPosterUrl;

  /// 用户已确认覆盖本机旧版本
  final bool replace;

  /// 下载完成后把外挂字幕（srt / ass → 服务端转 WebVTT）一并存到本地。
  /// 与 `spec.subtitleMode` 分开：那是「要不要把字幕烧/挂进视频文件」，
  /// 这是「要不要额外存几份字幕文件供播放器切换」。
  final bool fetchSubtitles;

  /// 合集 id：剧集按 seriesKey 摘要，电影就是条目 id
  String get groupId => seriesKey == null
      ? itemId
      : 'series:${sha1.convert(utf8.encode(seriesKey!)).toString().substring(0, 16)}';

  Map<String, dynamic> toMeta() => <String, dynamic>{
    'libraryName': libraryName,
    if (seriesKey != null) 'seriesKey': seriesKey,
    if (seriesTitle != null) 'seriesTitle': seriesTitle,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
    'totalEpisodes': totalEpisodes,
    'fetchSubtitles': fetchSubtitles,
    if (posterUrl != null) 'posterUrl': posterUrl,
    if (fallbackPosterUrl != null) 'fallbackPosterUrl': fallbackPosterUrl,
  };

  static OfflineRequest fromTask(OfflineTaskRecord task) {
    final meta = task.meta;
    return OfflineRequest(
      itemId: task.itemId,
      libraryId: task.libraryId,
      libraryName: '${meta['libraryName'] ?? ''}',
      title: task.title,
      spec: _specOf(task.spec),
      seriesKey: meta['seriesKey'] as String?,
      seriesTitle: meta['seriesTitle'] as String?,
      season: (meta['season'] as num?)?.toInt(),
      episode: (meta['episode'] as num?)?.toInt(),
      totalEpisodes: (meta['totalEpisodes'] as num?)?.toInt() ?? 0,
      posterUrl: meta['posterUrl'] as String?,
      fallbackPosterUrl: meta['fallbackPosterUrl'] as String?,
      fetchSubtitles: meta['fetchSubtitles'] == true,
    );
  }

  static OfflineSpec _specOf(Map<String, dynamic> spec) => OfflineSpec(
    preset: '${spec['preset'] ?? 'custom'}',
    codec: '${spec['codec'] ?? 'h265'}',
    height: (spec['height'] as num?)?.toInt() ?? 0,
    videoKbps: (spec['videoKbps'] as num?)?.toInt() ?? 0,
    audioKbps: (spec['audioKbps'] as num?)?.toInt() ?? 128,
    audioIndex: (spec['audioIndex'] as num?)?.toInt() ?? 0,
    container: '${spec['container'] ?? 'mp4'}',
    subtitleMode: '${spec['subtitleMode'] ?? 'none'}',
  );
}

/// 离线下载的执行器：建任务 → 等编码 → 断点续传 → 校验 → 入库。
///
/// 形态照 `TransferManager`：**单例 + ValueNotifier**，任务状态不放在页面 State 里
/// —— 用户切走页面、锁屏、甚至杀掉应用，任务记录都还在 `index/tasks.json`，
/// 重开就能接着下。
class OfflineDownloadManager {
  OfflineDownloadManager._();

  static final OfflineDownloadManager instance = OfflineDownloadManager._();

  /// 当前设备上的下载任务（按创建时间倒序）
  final ValueNotifier<List<OfflineTaskRecord>> tasks =
      ValueNotifier<List<OfflineTaskRecord>>(const <OfflineTaskRecord>[]);

  /// 本地库发生变化时 +1，页面据此重读
  final ValueNotifier<int> libraryRevision = ValueNotifier<int>(0);

  /// 自定义下载目录（PC 设置项；P7 接持久化，现在只在本进程内生效）
  String? customRoot;

  OfflineStore? _store;
  Future<OfflineStore>? _loading;
  bool _pumping = false;

  /// 同时跑几条（转码在服务端是串行的，下载是网络 IO，2 条刚好：
  /// 一条在等编码时另一条可以下，又不至于把上行/磁盘抢满）
  static const int _maxConcurrent = 2;

  /// 自动重试上限（只对网络类错误；编码失败重试没有意义）
  static const int _maxAttempts = 3;

  int _inflight = 0;
  final Set<String> _running = <String>{};

  /// 暂停原因：`user`（用户点的）/ `wifi`（仅 WiFi 策略下网络切走）
  final Map<String, String> _pauseReasons = <String, String>{};

  /// 最近一次已知的网络状态。拿不到就按「不是 WiFi」处理，绝不猜成 WiFi。
  bool _wifi = false;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  final Set<String> _canceled = <String>{};
  int _lastProgressAt = 0;
  int _lastNotifyAt = 0;
  String _lastNotifyState = '';

  OfflineStore? get store => _store;

  bool get supported => OfflineStorage.supported;

  /// 打开本地库（幂等）。页面首帧 / 下载前都会调一次。
  Future<OfflineStore> ensureStore() {
    final ready = _store;
    if (ready != null) return Future<OfflineStore>.value(ready);
    final pending = _loading;
    if (pending != null) return pending;
    final future = _open();
    _loading = future;
    return future.whenComplete(() => _loading = null);
  }

  /// 自定义下载目录的持久化键（客户端设置，只影响本机）
  static const String rootSettingKey = 'video.offline.root';

  Future<OfflineStore> _open() async {
    final saved = SettingsStore.instance.getString(rootSettingKey);
    final root = await OfflineStorage.rootPath(custom: customRoot ?? saved);
    await OfflineStorage.ensureLayout(root);
    final store = OfflineStore(root);
    await store.load();
    // 先收拾上次没走完的覆盖替换，再跟磁盘对账（顺序不能反：
    // 恢复可能把新旧文件换位，对账要看到最终结果）
    final recovered = await store.recoverReplacement();
    if (recovered != null) {
      debugPrint('[offline] 覆盖替换恢复：$recovered');
    }
    await store.reconcile();
    _store = store;
    _publishTasks();
    _watchNetwork();
    // 上次没下完的任务：重开后自动接着跑（不等用户点）
    _schedulePump();
    return store;
  }

  /// 换下载目录：**迁移**已有文件过去，失败则原样保留旧目录。
  ///
  /// 步骤与失败语义：
  ///   1. 目标建目录 + 写 `index/migrating.json`（崩溃标记）；
  ///   2. 逐文件 copy，每个文件立即校验大小；
  ///   3. 全部通过才切设置（`video.offline.root`）并重开索引；
  ///   4. 新库条目数不少于旧库才删旧目录 —— 少了就停下来把旧的留着。
  ///
  /// 任何一步抛错，目标目录里这次拷的东西会被清掉，旧目录一点没动。
  /// 中途断电：设置还没切，下次启动仍然读旧目录；目标里留着标记，
  /// 再迁移到同一目录时会先清空重来。
  Future<void> migrateRoot(
    String newRoot, {
    void Function(int done, int total)? onProgress,
  }) async {
    final store = await ensureStore();
    final from = store.root;
    if (p.equals(p.normalize(from), p.normalize(newRoot))) return;

    await OfflineStorage.ensureLayout(newRoot);
    final marker = File(p.join(newRoot, 'index', 'migrating.json'));
    if (await marker.exists()) {
      // 上次没搬完：目标里的半成品不能信，清掉重来
      for (final dir in <String>['videos', 'posters', 'backdrops', 'subtitles', 'index', 'temp']) {
        final sub = Directory(p.join(newRoot, dir));
        if (await sub.exists()) await sub.delete(recursive: true);
      }
      await OfflineStorage.ensureLayout(newRoot);
    }
    await marker.writeAsString(
      jsonEncode({'from': from, 'startedAt': DateTime.now().millisecondsSinceEpoch}),
      flush: true,
    );

    try {
      // 逐文件 copy + 校验（细节在 store 里，单测覆盖）
      await store.copyLibraryTo(newRoot, onProgress: onProgress);

      // 切设置 + 重开索引（`_open()` 会跑恢复与对账）
      await SettingsStore.instance.setString(rootSettingKey, newRoot);
      customRoot = newRoot;
      _store = null;
      final reloaded = await ensureStore();
      await marker.delete();

      // 新库比旧库少 → 说明拷丢了，绝不删旧目录
      if (reloaded.items.length < store.items.length) {
        libraryRevision.value++;
        throw StateError('新目录条目数比旧目录少（${reloaded.items.length} < ${store.items.length}），已保留旧目录');
      }

      try {
        await Directory(from).delete(recursive: true);
      } catch (_) {
        // 有文件被占用（播放器还开着）：旧目录留着，用户可手动删
      }
      libraryRevision.value++;
    } catch (err) {
      // 回滚：把这次拷到目标里的东西清掉，旧目录原样不动
      if (!p.equals(p.normalize((_store?.root) ?? from), p.normalize(newRoot))) {
        for (final dir in <String>['videos', 'posters', 'backdrops', 'subtitles', 'index', 'temp']) {
          final sub = Directory(p.join(newRoot, dir));
          try {
            if (await sub.exists()) await sub.delete(recursive: true);
          } catch (_) {
            // 删不动就算了，标记还在，下次会清
          }
        }
      }
      rethrow;
    }
  }

  // ---------------------------------------------------------------- 对外动作

  /// 开始下载。同一视频已有活动任务时直接返回那条，不重复建。
  Future<OfflineTaskRecord> start(OfflineRequest req) async {
    final store = await ensureStore();
    final existing = store.tasks[req.itemId];
    if (existing != null && existing.active) return existing;

    final record = OfflineTaskRecord(
      itemId: req.itemId,
      jobId: '',
      libraryId: req.libraryId,
      groupId: req.groupId,
      title: req.title,
      seriesTitle: req.seriesTitle,
      spec: <String, dynamic>{
        'preset': req.spec.preset,
        'codec': req.spec.codec,
        'height': req.spec.height,
        'videoKbps': req.spec.videoKbps,
        'audioKbps': req.spec.audioKbps,
        'audioIndex': req.spec.audioIndex,
        'container': req.spec.container,
        'subtitleMode': req.spec.subtitleMode,
      },
      meta: <String, dynamic>{...req.toMeta(), 'replace': req.replace},
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    // 先落盘再发请求：崩溃后重开才知道「这条下载到哪儿了」
    store.tasks[req.itemId] = record;
    await store.saveTasks();
    _canceled.remove(req.itemId);
    _publishTasks();
    _schedulePump();
    return record;
  }

  /// 监听网络切换。只在「仅 WiFi」开关打开时才影响调度。
  void _watchNetwork() {
    if (_connSub != null) return;
    try {
      _connSub = Connectivity().onConnectivityChanged.listen(_applyConnectivity);
    } catch (_) {
      // 桌面 / 单测里插件可能没实现：退化成「不知道」，不拦下载
    }
    unawaited(_refreshNetwork());
  }

  Future<void> _refreshNetwork() async {
    try {
      _applyConnectivity(await Connectivity().checkConnectivity());
    } catch (_) {
      // 拿不到就保持上一次的判断
    }
  }

  void _applyConnectivity(List<ConnectivityResult> results) {
    final wifi =
        results.contains(ConnectivityResult.wifi) || results.contains(ConnectivityResult.ethernet);
    final was = _wifi;
    _wifi = wifi;
    if (wifi == was) return;

    final store = _store;
    if (store == null) return;
    if (wifi) {
      // WiFi 回来：把等网络的任务重新排队，并叫醒调度器
      var changed = false;
      for (final task in store.tasks.values) {
        if (task.state != OfflineTaskState.waitingWifi) continue;
        task.state = OfflineTaskState.queued;
        task.nextTryAt = 0;
        _pauseReasons.remove(task.itemId);
        changed = true;
      }
      if (changed) {
        unawaited(store.saveTasks());
        _publishTasks();
      }
      _schedulePump();
    } else if (OfflinePreferences.wifiOnly) {
      // WiFi 掉了且开了「仅 WiFi」：正在传的在下一个数据块收手
      for (final task in store.tasks.values) {
        if (!task.canRun) continue;
        _pauseReasons[task.itemId] = 'wifi';
      }
    }
  }

  /// 暂停一条任务（编码阶段也支持：服务端会把这一片转完，产物缓存着，
  /// 继续时直接下载，不重编）
  Future<void> pause(String itemId) async {
    final store = await ensureStore();
    final task = store.tasks[itemId];
    if (task == null || !task.canRun) return;
    _pauseReasons[itemId] = 'user';
    task.state = OfflineTaskState.paused;
    await store.saveTasks();
    _publishTasks();
  }

  /// 继续一条被暂停 / 等网络的任务
  Future<void> resume(String itemId) async {
    final store = await ensureStore();
    final task = store.tasks[itemId];
    if (task == null) return;
    if (task.state != OfflineTaskState.paused &&
        task.state != OfflineTaskState.waitingWifi) {
      return;
    }
    _pauseReasons.remove(itemId);
    task.state = OfflineTaskState.queued;
    task.nextTryAt = 0;
    task.error = null;
    await store.saveTasks();
    _publishTasks();
    _schedulePump();
  }

  /// 手动重试一条失败的任务（编码失败也走这里：用户点重试 = 新的一次机会）
  Future<void> retry(String itemId) async {
    final store = await ensureStore();
    final task = store.tasks[itemId];
    if (task == null || task.active) return;
    task.attempts = 0;
    task.nextTryAt = 0;
    task.error = null;
    task.state = OfflineTaskState.queued;
    await store.saveTasks();
    _canceled.remove(itemId);
    _publishTasks();
    _schedulePump();
  }

  /// 取消：先让本地循环收手，再通知服务端杀掉编码
  Future<void> cancel(String itemId) async {
    final store = await ensureStore();
    final task = store.tasks[itemId];
    if (task == null) return;
    _canceled.add(itemId);
    task.state = OfflineTaskState.canceled;
    _publishTasks();
    if (task.jobId.isNotEmpty) {
      try {
        await ApiSession.instance.client.offlineJobCancel(id: task.jobId);
      } catch (_) {
        // 服务端已经结束 / 连不上都不影响本地收手
      }
    }
    final part = File(p.join(store.root, 'temp', '$itemId.part'));
    try {
      if (await part.exists()) await part.delete();
    } catch (_) {
      // 被占用：下次启动清理
    }
    store.removeTask(itemId);
    await store.saveTasks();
    _publishTasks();
  }

  /// 删除本地副本（多选删除就是逐个调用后一次性落盘）
  ///
  /// 只删本设备的文件，不碰服务器；封面在引用归零时才一起删。
  Future<void> deleteItems(Iterable<String> ids) async {
    final store = await ensureStore();
    final idList = ids.toList();
    if (idList.isEmpty) return;

    // 先把候选封面记下来：removeItems 会把空合集一起删掉，之后查不到
    final posterCandidates = <String>{};
    for (final id in idList) {
      final group = store.groups[store.item(id)?.groupId ?? ''];
      if (group == null) continue;
      if (group.posterPath != null) posterCandidates.add(group.posterPath!);
      if (group.fallbackPosterPath != null) posterCandidates.add(group.fallbackPosterPath!);
    }

    final removed = store.removeItems(idList);
    for (final item in removed) {
      await _deleteQuietly(File(store.absolute(item.filePath)));
      for (final sub in item.subtitlePaths) {
        await _deleteQuietly(File(store.absolute(sub)));
      }
    }

    for (final poster in posterCandidates) {
      if (store.posterInUse(poster)) continue;
      await _deleteQuietly(File(store.absolute(poster)));
    }

    await store.saveLibrary();
    libraryRevision.value++;
  }

  /// 记录播放进度（离线也写；联网后再由播放页同步给服务端）
  Future<void> savePlayback(String itemId, int positionMs) async {
    final store = _store;
    if (store == null) return;
    final item = store.item(itemId);
    if (item == null) return;
    if ((item.playbackMs - positionMs).abs() < 5000) return; // 5s 内不重复写盘
    item.playbackMs = positionMs;
    await store.saveLibrary();
    // 顺手回写服务端：离线看完的那一集，回到网页端不该还是「没看过」。
    // 失败无所谓（断网时本来就连不上），本地这份才是离线场景的真相。
    unawaited(_syncProgress(item, positionMs));
  }

  /// 把本地进度同步给服务端。
  ///
  /// `position` 的格式是 **毫秒数转成的字符串** —— 与短剧连播页同一个口径
  /// （详情页的续播提示按 `int.tryParse` 解析）。别写成 `12:34`，那边会退化成
  /// 「按百分比估」的旧路径。
  Future<void> _syncProgress(LocalMediaItem item, int positionMs) async {
    if (item.durationMs <= 0 || positionMs <= 0) return;
    final percent = ((positionMs / item.durationMs) * 100).clamp(0.0, 100.0).round();
    try {
      await ApiSession.instance.client.videoProgressSave(
        body: VideoProgressBody(
          id: item.id,
          percent: percent,
          position: '$positionMs',
        ),
      );
    } catch (_) {
      // 离线 / 条目已被删：不打扰用户
    }
  }

  // ---------------------------------------------------------------- 内部

  void _publishTasks() {
    final store = _store;
    final list = store == null
        ? const <OfflineTaskRecord>[]
        : store.tasks.values.toList()
          ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    tasks.value = List<OfflineTaskRecord>.unmodifiable(list);

    // 通知栏跟着当前任务走（只在有活动任务时推）
    final active = list.where((t) => t.active).toList();
    if (active.isNotEmpty) _pushNotification(active.first);
  }

  void _schedulePump() {
    if (_pumping) return;
    _pumping = true;
    unawaited(_pump());
  }

  /// 串行处理：一路编码 + 下载已经能把带宽和内网 IO 吃满，多路只会互相拖
  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    var foreground = false;
    try {
      while (true) {
        final store = _store;
        if (store == null) break;
        final pending = store.tasks.values
            .where((t) => t.readyToRun && !_canceled.contains(t.itemId) && !_running.contains(t.itemId))
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

        if (pending.isEmpty) {
          // 还有在跑的 / 在退避等待的就等一等；都没有了就收工
          final waiting = store.tasks.values.any((t) => t.canRun);
          if (_inflight == 0 && !waiting) break;
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }

        for (final task in pending) {
          if (_inflight >= _maxConcurrent) break;
          if (!foreground) {
            foreground = true;
            unawaited(
              OfflineBackground.start(
                tr('video.offline.title'),
                '${task.title} · ${tr('video.offline.preparing')}',
              ),
            );
          }
          _running.add(task.itemId);
          _inflight += 1;
          unawaited(
            _run(store, task).whenComplete(() {
              _running.remove(task.itemId);
              _inflight -= 1;
            }),
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    } finally {
      _pumping = false;
      if (foreground) unawaited(OfflineBackground.stop());
    }
  }

  /// 网络类错误才值得自动重试：编码失败、校验失败重跑一遍还是同样结果。
  bool _isTransient(Object err) {
    if (err is SocketException || err is HttpException || err is TimeoutException) return true;
    if (err is http.ClientException) return true;
    if (err is TransferFailed) {
      final m = err.message;
      return m.startsWith('HTTP 5') || m.contains('Connection') || m.contains('timed out');
    }
    return false;
  }

  /// 退避：5s / 15s / 45s
  static int _backoffMs(int attempt) => 5000 * (attempt <= 1 ? 1 : (attempt == 2 ? 3 : 9));

  /// 把当前任务的进度推到通知栏（2 秒节流；状态一变立刻推）。
  void _pushNotification(OfflineTaskRecord task) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (task.state.name == _lastNotifyState && nowMs - _lastNotifyAt < 2000) return;
    _lastNotifyAt = nowMs;
    _lastNotifyState = task.state.name;
    switch (task.state) {
      case OfflineTaskState.queued:
      case OfflineTaskState.transcoding:
      case OfflineTaskState.paused:
      case OfflineTaskState.waitingWifi:
        unawaited(
          OfflineBackground.update(
            '${task.title} · ${tr('video.offline.preparing')}',
            progress: (task.progress * 100).round(),
          ),
        );
      case OfflineTaskState.downloading:
      case OfflineTaskState.verifying:
      case OfflineTaskState.replacing:
        unawaited(
          OfflineBackground.update(
            '${task.title} · ${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)}',
            progress: task.downloadedBytes,
            max: task.totalBytes > 0 ? task.totalBytes : 1,
          ),
        );
      case OfflineTaskState.done:
      case OfflineTaskState.failed:
      case OfflineTaskState.canceled:
        break;
    }
  }

  Future<void> _run(OfflineStore store, OfflineTaskRecord task) async {
    final req = OfflineRequest.fromTask(task);
    final client = ApiSession.instance.client;
    try {
      // 仅 WiFi：移动网络下干脆不开工，界面显示「等待 WiFi」。
      // 不报错也不用退避 —— 网络一回来 _applyConnectivity 会把状态翻回 queued。
      if (OfflinePreferences.wifiOnly && !_wifi) {
        task.state = OfflineTaskState.waitingWifi;
        task.nextTryAt = 0;
        await store.saveTasks();
        _publishTasks();
        return;
      }
      // 1) 建任务（幂等键把「同一次下载」钉死，重试不会翻倍）
      if (task.jobId.isEmpty) {
        final job = await client.offlineJobCreate(
          body: OfflineCreateJobBody(
            itemId: req.itemId,
            preset: req.spec.preset,
            codec: req.spec.codec,
            height: req.spec.height,
            videoKbps: req.spec.videoKbps,
            audioIndex: req.spec.audioIndex,
            audioBitrateKbps: req.spec.audioKbps,
            subtitleMode: req.spec.subtitleMode,
            operation: task.meta['replace'] == true ? 'replace' : 'create',
            idempotencyKey: 'offline:${req.itemId}:${task.createdAt}',
          ),
        );
        task.jobId = job.id;
        await store.saveTasks();
      }

      // 2) 等编码（服务端进度是 ffmpeg 的 out_time，不是估的）
      while (true) {
        // 暂停 / 取消在轮询边界收手：编码是服务端跑的，这里只是不再盯着
        if (_canceled.contains(req.itemId) || _pauseReasons.containsKey(req.itemId)) {
          throw const TransferCanceled();
        }
        final job = await client.offlineJobGet(id: task.jobId);
        final state = '${job.state}';
        if (state == 'failed') throw TransferFailed(job.error ?? '服务端编码失败');
        if (state == 'canceled') throw const TransferCanceled();
        if (state == 'ready') {
          task.progress = 1;
          break;
        }
        task.state = state == 'queued'
            ? OfflineTaskState.queued
            : OfflineTaskState.transcoding;
        task.progress = (job.progress / 100).clamp(0.0, 1.0).toDouble();
        _publishTasks();
        await Future<void>.delayed(const Duration(seconds: 1));
      }

      // 3) 产物元信息
      final artifact = await client.offlineJobArtifact(id: task.jobId);
      task.artifactId = artifact.id;
      task.totalBytes = artifact.size;
      task.sha256 = artifact.sha256;
      task.etag = artifact.etag;
      await store.saveTasks();

      // 4) 断点续传下载
      final part = File(p.join(store.root, 'temp', '${req.itemId}.part'));
      var resumeFrom = 0;
      if (await part.exists()) {
        // etag 变了说明服务端重编了产物：旧字节作废
        resumeFrom = task.etag == artifact.etag ? await part.length() : 0;
        if (resumeFrom == 0) await _deleteQuietly(part);
      }
      task.state = OfflineTaskState.downloading;
      task.downloadedBytes = resumeFrom;
      _publishTasks();

      final outcome = await OfflineTransfer.download(
        uri: Uri.parse(
          '${ApiSession.instance.baseUrl}/api/v1/offline-downloads/artifacts/${artifact.id}',
        ),
        headers: ApiSession.instance.authHeaders,
        target: part,
        etag: task.etag,
        expectedBytes: artifact.size,
        resumeFrom: resumeFrom,
        // 限速按用户设置；0 = 不限
        maxBytesPerSecond: OfflinePreferences.maxKbps * 1000 ~/ 8,
        isCanceled: () =>
            _canceled.contains(req.itemId) || _pauseReasons.containsKey(req.itemId),
        onProgress: (received) {
          task.downloadedBytes = received;
          final now = DateTime.now().millisecondsSinceEpoch;
          if (now - _lastProgressAt < 300) return;
          _lastProgressAt = now;
          _publishTasks();
        },
      );

      // 5) 校验（服务端给了 sha256 就必须对上，不信「大小对了就行」）
      task.state = OfflineTaskState.verifying;
      _publishTasks();
      if (artifact.sha256.isNotEmpty && outcome.sha256 != artifact.sha256) {
        await _deleteQuietly(part);
        throw TransferFailed('文件校验失败（sha256 不一致），请重试');
      }

      // 6) 入库
      task.state = OfflineTaskState.replacing;
      _publishTasks();
      await _commit(store, req, task, part, artifact);
    } catch (err) {
      if (_pauseReasons.containsKey(req.itemId)) {
        // 暂停不是失败：任务和已下的临时文件都留着，继续时按 Range 接着下
        final reason = _pauseReasons.remove(req.itemId);
        task.state = reason == 'wifi'
            ? OfflineTaskState.waitingWifi
            : OfflineTaskState.paused;
        await store.saveTasks();
      } else if (err is TransferCanceled || _canceled.contains(req.itemId)) {
        store.removeTask(req.itemId);
        await store.saveTasks();
        _canceled.remove(req.itemId);
      } else if (_isTransient(err) && task.attempts < _maxAttempts) {
        // 网络断了 / 服务端 5xx：退避后自动重排，不用用户盯着点重试
        task.attempts += 1;
        final waitMs = _backoffMs(task.attempts);
        task.state = OfflineTaskState.queued;
        task.error = '$err';
        task.nextTryAt = DateTime.now().millisecondsSinceEpoch + waitMs;
        await store.saveTasks();
        debugPrint('[offline] 第 ${task.attempts} 次失败，${waitMs}ms 后重试：$err');
      } else {
        task.state = OfflineTaskState.failed;
        task.error = '$err';
        await store.saveTasks();
      }
      _publishTasks();
    }
  }

  /// 把临时文件换成正式文件并更新索引
  Future<void> _commit(
    OfflineStore store,
    OfflineRequest req,
    OfflineTaskRecord task,
    File part,
    OfflineArtifact artifact,
  ) async {
    final ext = artifact.container == 'mkv' ? 'mkv' : 'mp4';
    final relVideo = 'videos/${req.itemId}.$ext';
    final dst = File(store.absolute(relVideo));
    await dst.parent.create(recursive: true);

    // 覆盖本机旧版本时先把旧文件挪开（同卷 rename 是原子的）：
    // 任一步崩溃都能从 replace.log 恢复，且旧片在提交前一直可播。
    final log = File(p.join(store.root, 'index', 'replace.log'));
    final relBack = 'videos/${req.itemId}.$ext.old';
    final relPart = 'temp/${req.itemId}.part';
    if (await dst.exists()) {
      final back = File('${dst.path}.old');
      await _deleteQuietly(back);
      // 三个路径都记相对值：整个 Offline 目录搬走后照样能恢复
      await log.writeAsString(
        jsonEncode({'dst': relVideo, 'back': relBack, 'part': relPart}),
        flush: true,
      );
      await dst.rename(back.path);
    }

    await _installFile(part, dst);

    if (await log.exists()) {
      final back = File('${dst.path}.old');
      await _deleteQuietly(back);
      await _deleteQuietly(log);
    }

    // 同目录写一份 meta.json：索引丢了还能靠它重建（文件名就是条目 id）
    final metaFile = File('${dst.path}.json');
    await metaFile.writeAsString(
      jsonEncode(<String, dynamic>{
        'itemId': req.itemId,
        'libraryId': req.libraryId,
        'title': req.title,
        'series': req.seriesKey,
        'season': req.season,
        'episode': req.episode,
        'bytes': artifact.size,
        'sha256': artifact.sha256,
        'width': artifact.width,
        'height': artifact.height,
        'durationMs': artifact.durationMs,
        'videoCodec': artifact.videoCodec,
        'container': artifact.container,
        'spec': task.spec,
        'downloadedAt': DateTime.now().millisecondsSinceEpoch,
      }),
      flush: true,
    );

    // 外挂字幕：服务端把 srt / ass 统一转成 WebVTT 返回，落到 subtitles/ 供播放器切换
    final subtitleRels = req.fetchSubtitles ? await _fetchSubtitles(store, req) : <String>[];

    // 封面：整剧一张，多集共用同一份文件（按 URL 摘要命名，天然去重）
    final posterRel = await _downloadPoster(store, req);

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final groupId = req.groupId;
    final group = store.groups[groupId];
    final resolvedPoster = posterRel ?? group?.posterPath;
    if (group == null) {
      await store.putGroup(
        LocalMediaGroup(
          id: groupId,
          kind: req.seriesKey == null ? 'movie' : 'series',
          libraryId: req.libraryId,
          libraryName: req.libraryName,
          title: req.seriesTitle ?? req.title,
          seriesKey: req.seriesKey,
          posterPath: resolvedPoster,
          fallbackPosterPath: group?.fallbackPosterPath,
          totalEpisodes: req.totalEpisodes,
          itemIds: <String>[req.itemId],
          updatedAt: nowMs,
        ),
      );
    } else {
      if (!group.itemIds.contains(req.itemId)) group.itemIds.add(req.itemId);
      if (resolvedPoster != null) group.posterPath = resolvedPoster;
      if (req.totalEpisodes > group.totalEpisodes) group.totalEpisodes = req.totalEpisodes;
      if (group.libraryName.isEmpty) group.libraryName = req.libraryName;
      group.updatedAt = nowMs;
    }

    await store.putItem(
      LocalMediaItem(
        id: req.itemId,
        groupId: groupId,
        libraryId: req.libraryId,
        title: req.title,
        filePath: relVideo,
        bytes: artifact.size,
        season: req.season,
        episode: req.episode,
        durationMs: artifact.durationMs,
        width: artifact.width,
        height: artifact.height,
        videoCodec: artifact.videoCodec,
        container: artifact.container,
        spec: task.spec,
        subtitlePaths: subtitleRels,
        downloadedAt: nowMs,
      ),
    );

    store.removeTask(req.itemId);
    await store.saveLibrary();
    await store.saveTasks();
    _publishTasks();
    libraryRevision.value++;
  }

  /// 抓外挂字幕。一个都没有 / 服务端转不了（图形字幕）都返回空数组，不打断入库。
  Future<List<String>> _fetchSubtitles(OfflineStore store, OfflineRequest req) async {
    try {
      final list = await ApiSession.instance.client.videoSubtitles(id: req.itemId);
      // `#embedded:N` 是容器内的字幕轨：视频里本来就有，单独存一份没有意义
      final picked = list.items
          .where((s) => !s.name.startsWith('#embedded:'))
          .take(3)
          .toList();
      final out = <String>[];
      for (final sub in picked) {
        final parsed = await ApiSession.instance.client.videoSubtitle(
          id: req.itemId,
          name: sub.name,
        );
        if (parsed.vtt.trim().isEmpty) continue;
        final safe = sub.name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
        final rel = 'subtitles/${req.itemId}.$safe.vtt';
        final file = File(store.absolute(rel));
        await file.parent.create(recursive: true);
        await file.writeAsString(parsed.vtt, flush: true);
        out.add(rel);
      }
      return out;
    } catch (_) {
      // 字幕是锦上添花：拿不到就算了，别让整次下载失败
      return const <String>[];
    }
  }

  Future<String?> _downloadPoster(OfflineStore store, OfflineRequest req) async {
    final candidates = <String>[
      if (req.posterUrl != null) req.posterUrl!,
      if (req.fallbackPosterUrl != null) req.fallbackPosterUrl!,
    ];
    for (final url in candidates) {
      final name = '${sha1.convert(utf8.encode(url))}.jpg';
      final rel = 'posters/$name';
      final file = File(store.absolute(rel));
      if (await file.exists()) return rel;
      final ok = await OfflineTransfer.fetchToFile(
        uri: Uri.parse(url),
        headers: ApiSession.instance.authHeaders,
        target: file,
      );
      if (ok) return rel;
    }
    return null;
  }

  /// 同卷用 rename（原子）；跨卷 rename 会失败，退化成 copy + 校验 + 删源
  Future<void> _installFile(File from, File to) async {
    try {
      await from.rename(to.path);
      return;
    } on FileSystemException {
      // 跨卷 / 目标被占用
    }
    await from.copy(to.path);
    if (await to.length() != await from.length()) {
      await _deleteQuietly(to);
      throw TransferFailed('写入目标目录失败（磁盘空间不足或没有权限）');
    }
    await _deleteQuietly(from);
  }

  Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 被播放器占用：留给下次启动的 reconcile
    }
  }
}
