/// 本地媒体库的数据模型（纯数据 + JSON，不碰 IO）。
///
/// 存进 `index/*.json` 的**所有路径都是相对 Offline 根目录的**（正斜杠）：
/// PC 换下载目录、把 Offline 整个搬到另一块盘，索引都不用改。
library;

import 'dart:convert';

/// 合集：电影 / 混合库视频各一条；电视剧按「部」聚合，即使只下了一集。
class LocalMediaGroup {
  LocalMediaGroup({
    required this.id,
    required this.kind,
    required this.libraryId,
    required this.title,
    this.libraryName = '',
    this.seriesKey,
    this.posterPath,
    this.fallbackPosterPath,
    this.totalEpisodes = 0,
    List<String>? itemIds,
    this.updatedAt = 0,
  }) : itemIds = itemIds ?? <String>[];

  /// 本地合集 id（电影 = 条目 id；剧集 = seriesKey 的摘要）
  final String id;

  /// `movie` / `series` / `video`
  final String kind;
  final String libraryId;

  /// 库名快照：离线时服务器列表拿不到，分组的 chip 要用它。
  /// 非 final：老记录可能没存库名，后续下载同库时会补上。
  String libraryName;
  final String title;
  final String? seriesKey;

  /// 整剧封面（剧集）或影片海报（电影），相对路径
  String? posterPath;

  /// 兜底封面（海报接口给的是首帧），仅在 posterPath 取不到时用
  String? fallbackPosterPath;

  /// 整剧总集数（只有剧集有）
  int totalEpisodes;
  final List<String> itemIds;
  int updatedAt;

  /// 已下载且可播的集数（删除 / 缺失后要重算）
  int get downloadedEpisodes => itemIds.length;

  bool get isSeries => kind == 'series';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'kind': kind,
    'libraryId': libraryId,
    'libraryName': libraryName,
    'title': title,
    if (seriesKey != null) 'seriesKey': seriesKey,
    if (posterPath != null) 'posterPath': posterPath,
    if (fallbackPosterPath != null) 'fallbackPosterPath': fallbackPosterPath,
    'totalEpisodes': totalEpisodes,
    'itemIds': itemIds,
    'updatedAt': updatedAt,
  };

  factory LocalMediaGroup.fromJson(Map<String, dynamic> json) => LocalMediaGroup(
    id: '${json['id'] ?? ''}',
    kind: '${json['kind'] ?? 'movie'}',
    libraryId: '${json['libraryId'] ?? ''}',
    libraryName: '${json['libraryName'] ?? ''}',
    title: '${json['title'] ?? ''}',
    seriesKey: json['seriesKey'] as String?,
    posterPath: json['posterPath'] as String?,
    fallbackPosterPath: json['fallbackPosterPath'] as String?,
    totalEpisodes: (json['totalEpisodes'] as num?)?.toInt() ?? 0,
    itemIds: (json['itemIds'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => '$e')
        .toList(),
    updatedAt: (json['updatedAt'] as num?)?.toInt() ?? 0,
  );
}

/// 本地媒体条目：一条 = 一个已下载并校验通过的文件。
class LocalMediaItem {
  LocalMediaItem({
    required this.id,
    required this.groupId,
    required this.libraryId,
    required this.title,
    required this.filePath,
    required this.bytes,
    this.season,
    this.episode,
    this.durationMs = 0,
    this.width = 0,
    this.height = 0,
    this.videoCodec = '',
    this.container = '',
    this.spec = const <String, dynamic>{},
    this.subtitlePaths = const <String>[],
    this.downloadedAt = 0,
    this.playbackMs = 0,
    this.sourceMissing = false,
  });

  /// == 源视频 id（video_items.id）。一台设备上一部片只留一条，这就是唯一键
  final String id;
  final String groupId;
  final String libraryId;
  final String title;

  /// 视频文件，相对 Offline 根
  final String filePath;
  final int bytes;
  final int? season;
  final int? episode;
  final int durationMs;
  final int width;
  final int height;
  final String videoCodec;

  /// mp4 / mkv
  final String container;

  /// 下载时的参数快照（`OfflineSpec` 的 JSON）
  final Map<String, dynamic> spec;

  /// 外挂字幕，相对路径；按顺序挂给播放器
  final List<String> subtitlePaths;
  final int downloadedAt;

  /// 本地播放进度（毫秒）。离线时也写，联网后再同步给服务端
  int playbackMs;

  /// 服务端已经找不到这个条目（文件改名 / 删库）。只影响「重新下载」，不影响离线播放
  bool sourceMissing;

  /// 规格文案：`1080P · H.265 · 1.8 Mbps`
  String get specLabel {
    final parts = <String>[];
    if (height > 0) parts.add('${height}P');
    final codec = videoCodec.toLowerCase();
    if (codec.contains('265') || codec.contains('hevc')) {
      parts.add('H.265');
    } else if (codec.contains('av1')) {
      parts.add('AV1');
    } else if (codec.contains('264') || codec.contains('avc')) {
      parts.add('H.264');
    }
    if (container.isNotEmpty) parts.add(container.toUpperCase());
    return parts.join(' · ');
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'groupId': groupId,
    'libraryId': libraryId,
    'title': title,
    'filePath': filePath,
    'bytes': bytes,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
    'durationMs': durationMs,
    'width': width,
    'height': height,
    'videoCodec': videoCodec,
    'container': container,
    'spec': spec,
    if (subtitlePaths.isNotEmpty) 'subtitlePaths': subtitlePaths,
    'downloadedAt': downloadedAt,
    'playbackMs': playbackMs,
    'sourceMissing': sourceMissing,
  };

  factory LocalMediaItem.fromJson(Map<String, dynamic> json) => LocalMediaItem(
    id: '${json['id'] ?? ''}',
    groupId: '${json['groupId'] ?? ''}',
    libraryId: '${json['libraryId'] ?? ''}',
    title: '${json['title'] ?? ''}',
    filePath: '${json['filePath'] ?? ''}',
    bytes: (json['bytes'] as num?)?.toInt() ?? 0,
    season: (json['season'] as num?)?.toInt(),
    episode: (json['episode'] as num?)?.toInt(),
    durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
    width: (json['width'] as num?)?.toInt() ?? 0,
    height: (json['height'] as num?)?.toInt() ?? 0,
    videoCodec: '${json['videoCodec'] ?? ''}',
    container: '${json['container'] ?? ''}',
    spec: (json['spec'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
    subtitlePaths: (json['subtitlePaths'] as List<dynamic>? ?? const <dynamic>[])
        .map((e) => '$e')
        .toList(),
    downloadedAt: (json['downloadedAt'] as num?)?.toInt() ?? 0,
    playbackMs: (json['playbackMs'] as num?)?.toInt() ?? 0,
    sourceMissing: json['sourceMissing'] == true,
  );
}

/// 下载任务（持久化到 `index/tasks.json`）。
///
/// 先落盘再发请求：应用被杀掉后重开，任务还在，能按 `downloadedBytes` 续传。
class OfflineTaskRecord {
  OfflineTaskRecord({
    required this.itemId,
    required this.jobId,
    required this.title,
    required this.libraryId,
    required this.spec,
    this.groupId,
    this.seriesTitle,
    this.state = OfflineTaskState.queued,
    this.progress = 0,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.etag = '',
    this.sha256 = '',
    this.artifactId = '',
    this.error,
    this.meta = const <String, dynamic>{},
    this.createdAt = 0,
  });

  /// 设备级唯一键：一个源视频只允许一条任务
  final String itemId;
  String jobId;
  String artifactId;
  final String libraryId;
  final String? groupId;

  /// 列表里显示用；`seriesTitle` 非空时是「剧名 · S1E2」
  final String title;
  final String? seriesTitle;
  final Map<String, dynamic> spec;

  OfflineTaskState state;

  /// 服务端编码进度（0~1）
  double progress;
  int downloadedBytes;
  int totalBytes;
  String etag;
  String sha256;
  String? error;

  /// 复现下载需要的上下文（库名 / 封面地址 / 季集号 / 总集数）。
  /// 不放进 `spec`：spec 是「产物参数」，meta 是「展示与归档用的元数据」。
  final Map<String, dynamic> meta;
  final int createdAt;

  bool get active =>
      state == OfflineTaskState.queued ||
      state == OfflineTaskState.transcoding ||
      state == OfflineTaskState.downloading ||
      state == OfflineTaskState.verifying;

  /// 0~1 的整体进度：编码阶段按编码进度折算前 30%，传输占后 70%
  double get overall {
    switch (state) {
      case OfflineTaskState.queued:
        return 0;
      case OfflineTaskState.transcoding:
        return progress.clamp(0.0, 1.0).toDouble() * 0.3;
      case OfflineTaskState.downloading:
      case OfflineTaskState.verifying:
        final done = totalBytes > 0 ? downloadedBytes / totalBytes : 0.0;
        return 0.3 + done.clamp(0.0, 1.0).toDouble() * 0.7;
      case OfflineTaskState.replacing:
        return 0.98;
      case OfflineTaskState.done:
        return 1;
      case OfflineTaskState.failed:
      case OfflineTaskState.canceled:
        return progress.clamp(0.0, 1.0).toDouble() * 0.3;
    }
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'itemId': itemId,
    'jobId': jobId,
    'artifactId': artifactId,
    'libraryId': libraryId,
    if (groupId != null) 'groupId': groupId,
    'title': title,
    if (seriesTitle != null) 'seriesTitle': seriesTitle,
    'spec': spec,
    'state': state.name,
    'progress': progress,
    'downloadedBytes': downloadedBytes,
    'totalBytes': totalBytes,
    'etag': etag,
    'sha256': sha256,
    if (error != null) 'error': error,
    if (meta.isNotEmpty) 'meta': meta,
    'createdAt': createdAt,
  };

  factory OfflineTaskRecord.fromJson(Map<String, dynamic> json) => OfflineTaskRecord(
    itemId: '${json['itemId'] ?? ''}',
    jobId: '${json['jobId'] ?? ''}',
    artifactId: '${json['artifactId'] ?? ''}',
    libraryId: '${json['libraryId'] ?? ''}',
    groupId: json['groupId'] as String?,
    title: '${json['title'] ?? ''}',
    seriesTitle: json['seriesTitle'] as String?,
    spec: (json['spec'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
    state: OfflineTaskState.values.firstWhere(
      (e) => e.name == json['state'],
      orElse: () => OfflineTaskState.queued,
    ),
    progress: (json['progress'] as num?)?.toDouble() ?? 0,
    downloadedBytes: (json['downloadedBytes'] as num?)?.toInt() ?? 0,
    totalBytes: (json['totalBytes'] as num?)?.toInt() ?? 0,
    etag: '${json['etag'] ?? ''}',
    sha256: '${json['sha256'] ?? ''}',
    error: json['error'] as String?,
    meta: (json['meta'] as Map?)?.cast<String, dynamic>() ?? const <String, dynamic>{},
    createdAt: (json['createdAt'] as num?)?.toInt() ?? 0,
  );
}

enum OfflineTaskState {
  queued,
  transcoding,
  downloading,
  verifying,
  replacing,
  done,
  failed,
  canceled,
}

/// 把服务端 state 映射成本地状态（服务端的 `ready` = 该下载了）
OfflineTaskState taskStateFromServer(String state) {
  switch (state) {
    case 'queued':
      return OfflineTaskState.queued;
    case 'transcoding':
      return OfflineTaskState.transcoding;
    case 'ready':
      return OfflineTaskState.downloading;
    case 'failed':
      return OfflineTaskState.failed;
    case 'canceled':
      return OfflineTaskState.canceled;
    default:
      return OfflineTaskState.queued;
  }
}

/// 索引文件的顶层结构：`{"version":1,"items":[...]}`
class IndexFile {
  IndexFile({this.version = 1, required this.items});

  final int version;
  final List<Map<String, dynamic>> items;

  static const int currentVersion = 1;

  String encode() => jsonEncode(<String, dynamic>{'version': version, 'items': items});

  static List<Map<String, dynamic>> decode(String raw) {
    if (raw.trim().isEmpty) return const <Map<String, dynamic>>[];
    final decoded = jsonDecode(raw);
    if (decoded is List) {
      // 老格式（裸数组）：能读就继续读，下次写盘会自动升级
      return decoded.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    if (decoded is Map && decoded['items'] is List) {
      return (decoded['items'] as List)
          .whereType<Map>()
          .map((e) => e.cast<String, dynamic>())
          .toList();
    }
    return const <Map<String, dynamic>>[];
  }
}
