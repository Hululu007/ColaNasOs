import 'package:nas_core/nas_core.dart';

/// 电影合集：用户手动合集，或按片名系列启发式聚合。
class TvMovieCollection {
  const TvMovieCollection({
    required this.id,
    required this.name,
    required this.movies,
    this.userManaged = false,
    this.coverItemId,
  });

  final String id;
  final String name;
  final List<VideoItem> movies;
  final bool userManaged;
  final String? coverItemId;

  VideoItem? get firstMovie {
    if (movies.isEmpty) return null;
    final cover = coverItemId;
    if (cover != null) {
      for (final movie in movies) {
        if (movie.id == cover) return movie;
      }
    }
    return movies.first;
  }
}

/// 首页「全部影片」里的一项：单片或合集。
class TvMovieEntry {
  const TvMovieEntry.movie(VideoItem this.movie) : collection = null;

  const TvMovieEntry.collection(TvMovieCollection this.collection)
    : movie = null;

  final VideoItem? movie;
  final TvMovieCollection? collection;

  String get name => collection?.name ?? movie?.title ?? '';

  VideoItem? get heroMovie => collection?.firstMovie ?? movie;

  String get letter {
    final item = heroMovie;
    if (item == null) return '#';
    return movieLetter(item);
  }

  String get sortKey {
    final item = heroMovie;
    if (item == null) return name;
    return (item.originalName ?? item.title).toLowerCase();
  }
}

/// 「继续观看」里的电影条目。
class TvMovieContinue {
  const TvMovieContinue({
    required this.item,
    required this.percent,
    required this.updatedAt,
  });

  final VideoItem item;
  final int percent;
  final int updatedAt;

  double get progress => (percent / 100).clamp(0.0, 1.0);
}

/// 片名首字母：优先用原名，去掉 The / A / An，非 A-Z 归到 #。
String movieLetter(VideoItem item) {
  final raw = (item.originalName ?? item.title).trim();
  if (raw.isEmpty) return '#';
  final text = raw.replaceFirst(
    RegExp(r'^(the|a|an)\s+', caseSensitive: false),
    '',
  );
  if (text.isEmpty) return '#';
  final first = text[0].toUpperCase();
  return RegExp(r'^[A-Z]$').hasMatch(first) ? first : '#';
}

String movieSortKey(VideoItem item) =>
    (item.originalName ?? item.title).toLowerCase();

/// 片名系列基名：冒号前的主标题 + 去掉结尾序号。
String? movieSeriesBase(String title) {
  var value = title.trim();
  if (value.isEmpty) return null;
  final colon = value.split(RegExp(r'[：:]')).first.trim();
  if (colon.isNotEmpty) value = colon;
  value = value.replaceFirst(RegExp(r'^新[·・.\s]*'), '');
  value = value.replaceFirst(
    RegExp(r'[\s·・\-]*(?:\d{1,2}|[IVX]{1,4})$'),
    '',
  );
  value = value.trim();
  if (value.length < 2) return null;
  return value;
}

/// 按片名启发式聚合电影系列：同基名至少 2 部才成合集。
List<TvMovieCollection> buildMovieCollections(
  List<VideoItem> items, {
  Set<String> excluded = const <String>{},
}) {
  final groups = <String, List<VideoItem>>{};
  for (final item in items) {
    if (excluded.contains(item.id)) continue;
    final base = movieSeriesBase(item.title);
    if (base == null) continue;
    groups.putIfAbsent(base, () => <VideoItem>[]).add(item);
  }
  final result = <TvMovieCollection>[];
  for (final entry in groups.entries) {
    if (entry.value.length < 2) continue;
    final movies = [...entry.value]
      ..sort((a, b) {
        final year = (a.year ?? 0).compareTo(b.year ?? 0);
        if (year != 0) return year;
        return a.title.compareTo(b.title);
      });
    result.add(
      TvMovieCollection(
        id: 'series:${entry.key}',
        name: entry.key,
        movies: movies,
        coverItemId: movies.first.id,
      ),
    );
  }
  result.sort((a, b) => a.name.compareTo(b.name));
  return result;
}

/// 继续观看：按更新时间倒序，取未看完的电影。
List<TvMovieContinue> buildMovieContinue({
  required List<VideoProgressItem> progress,
  required Map<String, VideoItem> itemById,
  int limit = 20,
}) {
  final sorted = [...progress]
    ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  final result = <TvMovieContinue>[];
  for (final entry in sorted) {
    if (entry.percent <= 0 || entry.percent >= 95) continue;
    final item = itemById[entry.itemId];
    if (item == null) continue;
    result.add(
      TvMovieContinue(
        item: item,
        percent: entry.percent,
        updatedAt: entry.updatedAt,
      ),
    );
    if (result.length >= limit) break;
  }
  return result;
}

/// 相关推荐：同合集优先，其次同类型，最后补足同库影片。
List<VideoItem> relatedMovies({
  required VideoItem movie,
  required List<VideoItem> all,
  List<TvMovieCollection> collections = const <TvMovieCollection>[],
  int limit = 12,
}) {
  final picked = <VideoItem>[];
  final seen = <String>{movie.id};
  for (final collection in collections) {
    if (!collection.movies.any((item) => item.id == movie.id)) continue;
    for (final item in collection.movies) {
      if (seen.add(item.id)) picked.add(item);
    }
    break;
  }
  final genres = movie.genres.toSet();
  if (genres.isNotEmpty) {
    for (final item in all) {
      if (picked.length >= limit) break;
      if (seen.contains(item.id)) continue;
      if (item.genres.any(genres.contains) && seen.add(item.id)) {
        picked.add(item);
      }
    }
  }
  for (final item in all) {
    if (picked.length >= limit) break;
    if (seen.add(item.id)) picked.add(item);
  }
  return picked.take(limit).toList();
}
