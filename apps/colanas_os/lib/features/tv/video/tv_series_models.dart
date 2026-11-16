import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

/// 一部剧在 TV 首页的聚合卡片。既可能来自服务端 `series` 聚合，
/// 也可能是本地文件夹聚合（没有 TMDB / 文件名不带 SxxExx 的健身课等）。
class TvSeriesCard {
  const TvSeriesCard({
    required this.name,
    required this.seasons,
    required this.episodes,
    this.watchedEpisodes = 0,
    this.coverId,
    this.posterId,
    this.folderPath,
    this.firstItem,
    this.year,
    this.overview,
    this.preloadedItems = const <VideoItem>[],
  });

  final String name;
  final int seasons;
  final int episodes;
  final int watchedEpisodes;

  /// 服务端聚合时「有海报的那一集」的 id。
  final String? coverId;
  final String? posterId;

  /// 文件夹聚合时该剧的根目录（相对/绝对路径，与 `video/list` 一致）。
  /// 为空表示服务端 series 聚合。
  final String? folderPath;
  final VideoItem? firstItem;
  final int? year;
  final String? overview;

  /// 文件夹聚合时已经拿到的全部条目，进详情不需要再请求。
  final List<VideoItem> preloadedItems;

  bool get isFolder => folderPath != null || preloadedItems.isNotEmpty;

  int get unwatched => (episodes - watchedEpisodes).clamp(0, episodes);

  bool get allWatched => episodes > 0 && unwatched == 0;
}

/// 剧集里的一集（含季/集号与进度），首页「继续观看」和详情选集共用。
class TvEpisodeRef {
  const TvEpisodeRef({
    required this.item,
    required this.seriesName,
    required this.season,
    required this.episode,
    required this.seasonLabel,
    required this.percent,
    required this.watched,
  });

  final VideoItem item;
  final String seriesName;
  final int season;
  final int episode;
  final String seasonLabel;
  final int percent;
  final bool watched;

  double get progress => (percent / 100).clamp(0.0, 1.0);

  String get code =>
      'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';

  String get resolution {
    final height = item.height ?? 0;
    if (height >= 2000) return '4K';
    if (height > 0) return '${height}p';
    return '';
  }
}

/// 「继续观看」一条：剧名 + 当前集的 S/E + 进度。
class TvContinueEntry {
  const TvContinueEntry({
    required this.item,
    required this.seriesName,
    required this.season,
    required this.episode,
    required this.percent,
    required this.updatedAt,
  });

  final VideoItem item;
  final String seriesName;
  final int season;
  final int episode;
  final int percent;
  final int updatedAt;

  double get progress => (percent / 100).clamp(0.0, 1.0);

  String get code =>
      'S${season.toString().padLeft(2, '0')}E${episode.toString().padLeft(2, '0')}';
}

String _norm(String path) => path.replaceAll('\\', '/');

String _trimSlashes(String path) =>
    _norm(path).replaceAll(RegExp(r'/+$'), '');

/// 条目归属的来源根（多来源库取最长匹配）。
String? rootOfItem(VideoItem item, List<String> roots) {
  final path = _norm(item.path);
  String? best;
  for (final raw in roots) {
    final root = _trimSlashes(raw);
    if (root.isEmpty) continue;
    if (path == root || path.startsWith('$root/')) {
      if (best == null || root.length > best.length) best = root;
    }
  }
  return best;
}

/// 把 `S01` / `第 1 季` / `Season 1` / 纯数字目录解析成季号。
int? parseSeasonNumber(String? raw) {
  final value = (raw ?? '').trim();
  if (value.isEmpty) return null;
  final patterns = <RegExp>[
    RegExp(r'[Ss](\d{1,2})'),
    RegExp(r'第\s*([0-9一二三四五六七八九十]+)\s*季'),
    RegExp(r'[Ss]eason\s*(\d{1,2})', caseSensitive: false),
    RegExp(r'^(\d{1,2})$'),
  ];
  for (final pattern in patterns) {
    final match = pattern.firstMatch(value);
    if (match == null) continue;
    final text = match.group(1)!;
    final ascii = int.tryParse(text);
    if (ascii != null) return ascii;
    return _cnNumber(text);
  }
  return null;
}

int? _cnNumber(String value) {
  const digits = <String, int>{
    '一': 1,
    '二': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
    '十': 10,
  };
  if (digits.containsKey(value)) return digits[value];
  if (value.startsWith('十') && value.length == 2) {
    return 10 + (digits[value[1]] ?? 0);
  }
  if (value.endsWith('十') && value.length == 2) {
    return (digits[value[0]] ?? 0) * 10;
  }
  return null;
}

/// 某一集在文件夹聚合里的季 / 集信息。
class _FolderEpisode {
  const _FolderEpisode({
    required this.seriesName,
    required this.groupPath,
    required this.season,
    required this.seasonLabel,
    required this.episode,
  });

  final String seriesName;
  final String groupPath;
  final int season;
  final String seasonLabel;
  final int episode;
}

/// 给「没有 series 信息」的条目按文件夹算季/集。
///
/// 规则：来源根下第一层目录 = 剧；再下一层 = 季；没有子目录归入第 1 季。
/// 根目录下的散文件单独成卡（每部一条）。
Map<String, _FolderEpisode> _folderIndex(
  List<VideoItem> items,
  List<String> roots,
) {
  final result = <String, _FolderEpisode>{};
  final counters = <String, int>{};
  final seasonByFolder = <String, int>{};
  final nextSeason = <String, int>{};

  // 先按路径排序，保证同一季里的集号稳定。
  final sorted = [...items]
    ..sort((a, b) => _norm(a.path).compareTo(_norm(b.path)));

  for (final item in sorted) {
    if ((item.series ?? '').trim().isNotEmpty) continue;
    final path = _norm(item.path);
    final root = rootOfItem(item, roots);
    final base = root ?? _parentOf(path);
    final rel = path.startsWith('$base/') ? path.substring(base.length + 1) : path;
    final parts = rel.split('/').where((part) => part.isNotEmpty).toList();
    if (parts.length < 2) {
      // 根目录散文件：以自身为一部。
      result[item.id] = _FolderEpisode(
        seriesName: item.title,
        groupPath: path,
        season: 1,
        seasonLabel: tr('video.series.season', {'n': '1'}),
        episode: 1,
      );
      continue;
    }
    final seriesFolder = parts.first;
    final groupPath = '$base/$seriesFolder';
    final seasonFolder = parts.length >= 3 ? parts[1] : null;
    var season = parseSeasonNumber(seasonFolder);
    if (season == null || season <= 0) {
      if (seasonFolder == null) {
        season = 1;
      } else {
        final seasonKey = '$groupPath/$seasonFolder';
        season = seasonByFolder.putIfAbsent(seasonKey, () {
          final next = nextSeason[groupPath] ?? 1;
          nextSeason[groupPath] = next + 1;
          return next;
        });
      }
    }
    final seasonLabel = (seasonFolder ?? '').trim().isEmpty
        ? tr('video.series.season', {'n': '$season'})
        : seasonFolder!;
    final key = '$groupPath/$season';
    counters[key] = (counters[key] ?? 0) + 1;
    result[item.id] = _FolderEpisode(
      seriesName: seriesFolder,
      groupPath: groupPath,
      season: season,
      seasonLabel: seasonLabel,
      episode: counters[key]!,
    );
  }
  return result;
}

String _parentOf(String path) {
  final index = path.lastIndexOf('/');
  return index <= 0 ? path : path.substring(0, index);
}

/// 文件夹聚合：把 `series == null` 的条目按「来源根 + 第一层目录」聚成剧卡。
List<TvSeriesCard> buildFolderSeries({
  required List<VideoItem> items,
  required List<String> roots,
  required Map<String, VideoProgressItem> progressById,
}) {
  final groups = <String, List<VideoItem>>{};
  final singles = <VideoItem>[];
  for (final item in items) {
    if ((item.series ?? '').trim().isNotEmpty) continue;
    final path = _norm(item.path);
    final root = rootOfItem(item, roots);
    final base = root ?? _parentOf(path);
    final rel = path.startsWith('$base/') ? path.substring(base.length + 1) : path;
    final parts = rel.split('/').where((part) => part.isNotEmpty).toList();
    if (parts.length < 2) {
      singles.add(item);
      continue;
    }
    final groupPath = '$base/${parts.first}';
    groups.putIfAbsent(groupPath, () => <VideoItem>[]).add(item);
  }

  final cards = <TvSeriesCard>[];
  for (final entry in groups.entries) {
    final groupItems = entry.value;
    final index = _folderIndex(groupItems, roots);
    final seasons = <int>{};
    for (final item in groupItems) {
      final meta = index[item.id];
      if (meta != null) seasons.add(meta.season);
    }
    final watched = groupItems.where((item) {
      if (item.watched) return true;
      return (progressById[item.id]?.percent ?? 0) >= 95;
    }).length;
    final coverItem = groupItems.firstWhere(
      (item) => item.hasArt,
      orElse: () => groupItems.first,
    );
    final folderName = _norm(entry.key).split('/').last;
    cards.add(
      TvSeriesCard(
        name: folderName,
        seasons: seasons.isEmpty ? 1 : seasons.length,
        episodes: groupItems.length,
        watchedEpisodes: watched,
        folderPath: entry.key,
        firstItem: coverItem,
        year: coverItem.year,
        overview: groupItems
            .map((item) => item.overview)
            .firstWhere((value) => (value ?? '').trim().isNotEmpty, orElse: () => null),
        preloadedItems: groupItems,
      ),
    );
  }

  for (final item in singles) {
    cards.add(
      TvSeriesCard(
        name: item.title,
        seasons: 1,
        episodes: 1,
        watchedEpisodes:
            item.watched || (progressById[item.id]?.percent ?? 0) >= 95 ? 1 : 0,
        folderPath: null,
        firstItem: item,
        year: item.year,
        overview: item.overview,
        preloadedItems: <VideoItem>[item],
      ),
    );
  }
  cards.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return cards;
}

/// 详情页的选集：文件夹聚合按子目录算季，服务端聚合直接用 season/episode。
List<TvEpisodeRef> buildEpisodes({
  required TvSeriesCard card,
  required List<VideoItem> items,
  required List<String> roots,
  required Map<String, VideoProgressItem> progressById,
}) {
  final folderIndex = _folderIndex(items, roots);
  final refs = <TvEpisodeRef>[];
  for (final item in items) {
    final meta = folderIndex[item.id];
    final season = card.isFolder
        ? (meta?.season ?? 1)
        : (item.season ?? 1);
    var episode = card.isFolder
        ? (meta?.episode ?? 1)
        : (item.episode ?? 0);
    final percent = progressById[item.id]?.percent ?? 0;
    refs.add(
      TvEpisodeRef(
        item: item,
        seriesName: card.name,
        season: season,
        episode: episode,
        seasonLabel: card.isFolder
            ? (meta?.seasonLabel ?? tr('video.series.season', {'n': '$season'}))
            : tr('video.series.season', {'n': '$season'}),
        percent: percent,
        watched: item.watched || percent >= 95,
      ),
    );
  }
  refs.sort((a, b) {
    final season = a.season.compareTo(b.season);
    if (season != 0) return season;
    final episode = a.episode.compareTo(b.episode);
    if (episode != 0) return episode;
    return a.item.title.compareTo(b.item.title);
  });
  // 没有集号的文件按排序补号，保证卡片上 S/E 可读。
  var lastSeason = -1;
  var counter = 0;
  for (var i = 0; i < refs.length; i += 1) {
    final ref = refs[i];
    if (ref.season != lastSeason) {
      lastSeason = ref.season;
      counter = 0;
    }
    counter += 1;
    if (ref.episode <= 0) {
      refs[i] = TvEpisodeRef(
        item: ref.item,
        seriesName: ref.seriesName,
        season: ref.season,
        episode: counter,
        seasonLabel: ref.seasonLabel,
        percent: ref.percent,
        watched: ref.watched,
      );
    }
  }
  return refs;
}

/// 「继续观看」：从进度列表里取未看完的最近条目，同一部剧只留一条。
List<TvContinueEntry> buildContinueEntries({
  required List<VideoProgressItem> progress,
  required Map<String, VideoItem> itemById,
  required List<String> roots,
  int limit = 20,
}) {
  final folderIndex = _folderIndex(itemById.values.toList(), roots);
  final sorted = [...progress]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final seen = <String>{};
  final out = <TvContinueEntry>[];
  for (final entry in sorted) {
    if (entry.percent <= 0 || entry.percent >= 95) continue;
    final item = itemById[entry.itemId];
    if (item == null) continue;
    final meta = folderIndex[item.id];
    final seriesName = (item.series ?? '').trim().isNotEmpty
        ? item.series!
        : (meta?.seriesName ?? item.title);
    if (!seen.add(seriesName)) continue;
    out.add(
      TvContinueEntry(
        item: item,
        seriesName: seriesName,
        season: item.season ?? meta?.season ?? 1,
        episode: item.episode ?? meta?.episode ?? 1,
        percent: entry.percent,
        updatedAt: entry.updatedAt,
      ),
    );
    if (out.length >= limit) break;
  }
  return out;
}

/// 文件夹聚合里某一集的季 / 集（给继续观看兜底）。
({int season, int episode})? folderEpisodeOf(
  VideoItem item,
  List<VideoItem> all,
  List<String> roots,
) {
  final meta = _folderIndex(all, roots)[item.id];
  if (meta == null) return null;
  return (season: meta.season, episode: meta.episode);
}
