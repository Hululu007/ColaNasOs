import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart' show formatBytes, tr;
import 'package:path/path.dart' as p;

import '../../../core/session.dart';
import 'offline_background.dart';
import 'offline_models.dart';
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

  Future<OfflineStore> _open() async {
    final root = await OfflineStorage.rootPath(custom: customRoot);
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
    // 上次没下完的任务：重开后自动接着跑（不等用户点）
    _schedulePump();
    return store;
  }

  /// 换下载目录：只切索引位置，不动旧目录里的文件（迁移在 P7）
  Future<void> setCustomRoot(String? root) async {
    customRoot = root;
    _store = null;
    await ensureStore();
    libraryRevision.value++;
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
    var foreground = false;
    try {
      while (true) {
        final store = _store;
        if (store == null) break;
        final next = store.tasks.values
            .where((t) => t.active && !_canceled.contains(t.itemId))
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
        if (next.isEmpty) break;
        if (!foreground) {
          // 第一条任务开跑就拉起前台服务：Android 息屏会冻结进程，
          // 没有它下载会停在半路，用户回来看到「进度不动」。
          foreground = true;
          unawaited(
            OfflineBackground.start(
              tr('video.offline.title'),
              '${next.first.title} · ${tr('video.offline.preparing')}',
            ),
          );
        }
        await _run(store, next.first);
      }
    } finally {
      _pumping = false;
      if (foreground) unawaited(OfflineBackground.stop());
    }
  }

  /// 把当前任务的进度推到通知栏（2 秒节流；状态一变立刻推）。
  void _pushNotification(OfflineTaskRecord task) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (task.state.name == _lastNotifyState && nowMs - _lastNotifyAt < 2000) return;
    _lastNotifyAt = nowMs;
    _lastNotifyState = task.state.name;
    switch (task.state) {
      case OfflineTaskState.queued:
      case OfflineTaskState.transcoding:
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
        if (_canceled.contains(req.itemId)) throw const TransferCanceled();
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
        isCanceled: () => _canceled.contains(req.itemId),
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
      if (err is TransferCanceled || _canceled.contains(req.itemId)) {
        store.removeTask(req.itemId);
        await store.saveTasks();
        _canceled.remove(req.itemId);
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
        downloadedAt: nowMs,
      ),
    );

    store.removeTask(req.itemId);
    await store.saveLibrary();
    await store.saveTasks();
    _publishTasks();
    libraryRevision.value++;
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
