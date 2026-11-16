import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../video/video_card.dart';
import 'movie/tv_movie_collection_page.dart';
import 'movie/tv_movie_detail.dart';
import 'movie/tv_movie_home.dart';
import 'movie/tv_movie_models.dart';
import 'tv_focus.dart';
import 'tv_video_section.dart';
import 'video/tv_series_detail.dart';
import 'video/tv_series_home.dart';
import 'video/tv_series_models.dart';

/// TV 影视库分区。
///
/// - 电视剧 / 短剧库：按剧聚合（服务端 series + 本地文件夹兜底），首页只出剧卡；
/// - 电影 / 日本电影库：Hero 剧照墙 + 泳道 + 合集 + A-Z 索引；
/// - 图片 / 混合库：保持逐条图片墙。
class TvVideoLibrarySection extends StatefulWidget {
  const TvVideoLibrarySection({
    super.key,
    required this.library,
    required this.back,
    this.firstFocusNode,
  });

  final VideoLibraryItem library;
  final TvBackController back;
  final FocusNode? firstFocusNode;

  @override
  State<TvVideoLibrarySection> createState() => _TvVideoLibrarySectionState();
}

class _TvVideoLibrarySectionState extends State<TvVideoLibrarySection> {
  bool _loading = true;
  String? _error;
  bool _preparing = false;

  // 电视剧 / 短剧：聚合后的剧卡与继续观看。
  List<TvContinueEntry> _continueItems = const <TvContinueEntry>[];
  List<TvSeriesCard> _recentSeries = const <TvSeriesCard>[];
  List<TvSeriesCard> _allSeries = const <TvSeriesCard>[];
  Map<String, VideoProgressItem> _progressById =
      const <String, VideoProgressItem>{};
  Map<String, VideoItem> _itemsById = const <String, VideoItem>{};
  TvSeriesCard? _seriesDetail;

  // 图片 / 电影：逐条列表 + 单片详情。
  List<VideoItem> _items = const <VideoItem>[];
  VideoItem? _itemDetail;

  // 电影：继续观看 / 最近添加 / 合集 / A-Z 条目 + 合集页 / 详情页。
  List<VideoItem> _recentMovies = const <VideoItem>[];
  List<TvMovieCollection> _movieCollections = const <TvMovieCollection>[];
  List<TvMovieEntry> _movieEntries = const <TvMovieEntry>[];
  List<TvMovieContinue> _movieContinue = const <TvMovieContinue>[];
  TvMovieCollection? _movieCollection;
  VideoItem? _movieDetail;

  final FocusNode _ownedFirstFocus = FocusNode(debugLabel: 'tv-video-first');
  FocusNode get _firstFocus => widget.firstFocusNode ?? _ownedFirstFocus;

  bool get _isSeriesLibrary =>
      widget.library.libType == 'tv' || widget.library.libType == 'short_tv';

  bool get _isMovieLibrary =>
      widget.library.libType == 'movie' || widget.library.libType == 'jp_movie';

  List<String> get _roots {
    final roots = <String>[
      for (final source in widget.library.sources ?? const <VideoSourceItem>[])
        if (source.path.trim().isNotEmpty) source.path,
    ];
    if (roots.isEmpty && widget.library.path.trim().isNotEmpty) {
      roots.add(widget.library.path);
    }
    return roots;
  }

  bool _onBackPressed() => _handleBack();

  bool _hasOverlay() =>
      _seriesDetail != null ||
      _itemDetail != null ||
      _movieCollection != null ||
      _movieDetail != null;

  @override
  void initState() {
    super.initState();
    widget.back.handler = _onBackPressed;
    widget.back.overlay = _hasOverlay;
    if (_isSeriesLibrary) {
      _loadSeries();
    } else if (_isMovieLibrary) {
      _loadMovies();
    } else {
      _loadFlat();
    }
  }

  @override
  void dispose() {
    if (widget.back.handler == _onBackPressed) {
      widget.back.handler = null;
      widget.back.overlay = null;
    }
    _ownedFirstFocus.dispose();
    super.dispose();
  }

  Future<T?> _safe<T>(Future<T> future) async {
    try {
      return await future;
    } catch (_) {
      return null;
    }
  }

  Future<List<VideoItem>> _loadAllItems() async {
    final client = ApiSession.instance.client;
    final out = <VideoItem>[];
    String? cursor;
    for (var page = 0; page < 10; page += 1) {
      final res = await client.videoList(
        libraryId: widget.library.id,
        limit: 200,
        cursor: cursor,
      );
      out.addAll(res.items);
      cursor = res.nextCursor;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  Future<void> _loadSeries() async {
    final client = ApiSession.instance.client;
    try {
      final seriesRes = await _safe(
        client.videoSeriesList(
          libraryId: widget.library.id,
          limit: 200,
          sortBy: 'updated',
        ),
      );
      final items = await _loadAllItems();
      final progressRes = await _safe(
        client.videoProgressList(libraryId: widget.library.id, limit: 200),
      );
      if (!mounted) return;

      final progressById = <String, VideoProgressItem>{
        for (final entry
            in progressRes?.items ?? const <VideoProgressItem>[])
          entry.itemId: entry,
      };
      final itemById = <String, VideoItem>{
        for (final item in items) item.id: item,
      };
      final roots = _roots;

      final parsed = <TvSeriesCard>[
        for (final series in seriesRes?.items ?? const <VideoSeriesItem>[])
          TvSeriesCard(
            name: series.name,
            seasons: series.seasons,
            episodes: series.episodes,
            watchedEpisodes: series.watchedEpisodes ?? 0,
            coverId: series.coverId,
            posterId: series.posterId,
            firstItem: itemById[series.coverId],
            year: itemById[series.coverId]?.year,
            overview: itemById[series.coverId]?.overview,
          ),
      ];
      final folder = buildFolderSeries(
        items: items,
        roots: roots,
        progressById: progressById,
      );
      final recent = <TvSeriesCard>[...parsed, ...folder];
      final all = <TvSeriesCard>[...parsed, ...folder]
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      final continueItems = buildContinueEntries(
        progress: progressRes?.items ?? const <VideoProgressItem>[],
        itemById: itemById,
        roots: roots,
      );

      setState(() {
        _itemsById = itemById;
        _progressById = progressById;
        _recentSeries = recent.take(20).toList();
        _allSeries = all;
        _continueItems = continueItems;
        _loading = false;
        _error = (seriesRes == null && items.isEmpty && progressRes == null)
            ? tr('common.error')
            : null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadMovies() async {
    final client = ApiSession.instance.client;
    try {
      final items = await _loadAllItems();
      final progressRes = await _safe(
        client.videoProgressList(libraryId: widget.library.id, limit: 200),
      );
      final recentRes = await _safe(
        client.videoList(
          libraryId: widget.library.id,
          sortBy: 'createTime',
          sortOrder: 'desc',
          limit: 30,
        ),
      );
      final userRes = await _safe(client.videoCollectionList());
      if (!mounted) return;

      final itemById = <String, VideoItem>{
        for (final item in items) item.id: item,
      };
      final progressById = <String, VideoProgressItem>{
        for (final entry
            in progressRes?.items ?? const <VideoProgressItem>[])
          entry.itemId: entry,
      };

      // 用户合集：只保留当前库里真的有影片的，避免把别的库的合集混进来。
      final excluded = <String>{};
      final userCollections = <TvMovieCollection>[];
      final rawCollections = (userRes?.items ?? const <VideoCollection>[]).take(12);
      final fetched = await Future.wait(
        rawCollections.map((raw) async {
          final res = await _safe(client.videoCollectionItems(id: raw.id));
          return (raw: raw, res: res);
        }),
      );
      for (final entry in fetched) {
        final movies = (entry.res?.items ?? const <VideoItem>[])
            .where((movie) => movie.libraryId == widget.library.id)
            .toList()
          ..sort((a, b) => (a.year ?? 0).compareTo(b.year ?? 0));
        if (movies.isEmpty) continue;
        userCollections.add(
          TvMovieCollection(
            id: entry.raw.id,
            name: entry.raw.name,
            movies: movies,
            userManaged: true,
            coverItemId: entry.raw.coverItemId,
          ),
        );
        excluded.addAll(movies.map((movie) => movie.id));
      }

      // 片名启发式合集（同基名 >= 2 部），用户合集里的影片不再重复参与。
      final heuristic = buildMovieCollections(items, excluded: excluded);
      for (final collection in heuristic) {
        excluded.addAll(collection.movies.map((movie) => movie.id));
      }
      final collections = <TvMovieCollection>[
        ...userCollections,
        ...heuristic,
      ];

      final entries = <TvMovieEntry>[
        for (final collection in collections) TvMovieEntry.collection(collection),
        for (final movie in items)
          if (!excluded.contains(movie.id)) TvMovieEntry.movie(movie),
      ]..sort((a, b) {
          if (a.letter != b.letter) {
            if (a.letter == '#') return 1;
            if (b.letter == '#') return -1;
            return a.letter.compareTo(b.letter);
          }
          return a.sortKey.compareTo(b.sortKey);
        });

      setState(() {
        _itemsById = itemById;
        _progressById = progressById;
        _items = items;
        _recentMovies = recentRes?.items ?? const <VideoItem>[];
        _movieCollections = collections;
        _movieEntries = entries;
        _movieContinue = buildMovieContinue(
          progress: progressRes?.items ?? const <VideoProgressItem>[],
          itemById: itemById,
        );
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _loadFlat() async {
    try {
      final res = await ApiSession.instance.client.videoList(
        libraryId: widget.library.id,
        limit: 200,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _refreshProgress() async {
    if (!_isSeriesLibrary && !_isMovieLibrary) return;
    try {
      final res = await ApiSession.instance.client.videoProgressList(
        libraryId: widget.library.id,
        limit: 200,
      );
      if (!mounted) return;
      final progressById = <String, VideoProgressItem>{
        for (final entry in res.items) entry.itemId: entry,
      };
      setState(() {
        _progressById = progressById;
        if (_isSeriesLibrary) {
          _continueItems = buildContinueEntries(
            progress: res.items,
            itemById: _itemsById,
            roots: _roots,
          );
        } else {
          _movieContinue = buildMovieContinue(
            progress: res.items,
            itemById: _itemsById,
          );
        }
      });
    } catch (_) {
      // 进度刷新失败不影响已经显示的首页。
    }
  }

  bool _handleBack() {
    if (_seriesDetail != null) {
      setState(() => _seriesDetail = null);
      _restoreFirstFocus();
      return true;
    }
    if (_movieDetail != null) {
      setState(() => _movieDetail = null);
      _restoreFirstFocus();
      return true;
    }
    if (_movieCollection != null) {
      setState(() => _movieCollection = null);
      _restoreFirstFocus();
      return true;
    }
    if (_itemDetail != null) {
      setState(() => _itemDetail = null);
      _restoreFirstFocus();
      return true;
    }
    return false;
  }

  void _restoreFirstFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  Future<void> _play(VideoItem item) async {
    if (_preparing) return;
    setState(() => _preparing = true);
    try {
      await playTvVideo(context, item);
      if (mounted) await _refreshProgress();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('video.playUrlFailed', {'error': '$e'}))),
      );
    } finally {
      if (mounted) setState(() => _preparing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final movie = _movieDetail;
    if (movie != null) {
      return TvMovieDetailPage(
        key: ValueKey<String>('movie-${movie.id}'),
        movie: movie,
        all: _items,
        collections: _movieCollections,
        percent: _progressById[movie.id]?.percent ?? 0,
        preparing: _preparing,
        onPlay: () => _play(movie),
        onSelectMovie: (next) => setState(() => _movieDetail = next),
      );
    }
    final collection = _movieCollection;
    if (collection != null) {
      return TvMovieCollectionPage(
        key: ValueKey<String>('collection-${collection.id}'),
        collection: collection,
        firstFocusNode: _firstFocus,
        onOpenMovie: (item) => setState(() => _movieDetail = item),
      );
    }
    final series = _seriesDetail;
    if (series != null) {
      return TvSeriesDetailPage(
        key: ValueKey<String>('series-${series.name}'),
        card: series,
        libraryId: widget.library.id,
        roots: _roots,
        progressById: _progressById,
        onPlay: _play,
      );
    }
    final item = _itemDetail;
    if (item != null) {
      return TvVideoDetailView(
        item: item,
        preparing: _preparing,
        onPlay: () => _play(item),
        onBack: _handleBack,
      );
    }
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return NasErrorState(
        message: _error!,
        onRetry: _isSeriesLibrary
            ? _loadSeries
            : _isMovieLibrary
            ? _loadMovies
            : _loadFlat,
      );
    }
    if (_isSeriesLibrary) {
      return TvSeriesHome(
        continueItems: _continueItems,
        recent: _recentSeries,
        all: _allSeries,
        firstFocusNode: _firstFocus,
        onOpenSeries: (card) => setState(() => _seriesDetail = card),
        onPlayContinue: (entry) => _play(entry.item),
      );
    }
    if (_isMovieLibrary) {
      return TvMovieHome(
        continueItems: _movieContinue,
        recent: _recentMovies,
        collections: _movieCollections,
        entries: _movieEntries,
        firstFocusNode: _firstFocus,
        progressOf: (id) => _progressById[id]?.percent ?? 0,
        onOpenMovie: (movie) => setState(() => _movieDetail = movie),
        onOpenCollection: (collection) =>
            setState(() => _movieCollection = collection),
        onPlayContinue: _play,
      );
    }
    return _buildFlatGrid();
  }

  Widget _buildFlatGrid() {
    if (_items.isEmpty) {
      return NasEmptyState(
        title: tr('video.home.empty'),
        message: tr('video.home.emptyHint'),
        icon: Icons.movie_outlined,
      );
    }
    final m = TvMetricsScope.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.only(top: m.px(4), bottom: m.px(24)),
      child: Wrap(
        spacing: m.px(24),
        runSpacing: m.px(26),
        children: [
          for (var i = 0; i < _items.length; i += 1)
            _TvLibraryCard(
              item: _items[i],
              focusNode: i == 0 ? _firstFocus : null,
              onTap: () => setState(() => _itemDetail = _items[i]),
            ),
        ],
      ),
    );
  }
}

class _TvLibraryCard extends StatelessWidget {
  const _TvLibraryCard({
    required this.item,
    required this.onTap,
    this.focusNode,
  });

  final VideoItem item;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(180);
    final isImage = item.mediaType == 'image';
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            focusNode: focusNode,
            onTap: onTap,
            radius: m.px(14),
            child: SizedBox(
              width: width,
              height: width * (isImage ? 3 / 4 : 3 / 2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(m.px(14)),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    NasCoverImage(
                      url: videoPosterUrl(item, size: (width * 2).round()),
                      fit: BoxFit.cover,
                      headers: videoArtHeaders,
                      fallbackText: item.title,
                      cacheWidth: (width * 2).round(),
                      borderRadius: 0,
                    ),
                    if (item.watched)
                      Positioned(
                        top: m.px(8),
                        left: m.px(8),
                        child: Icon(
                          Icons.check_circle,
                          size: m.px(20),
                          color: Colors.greenAccent,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          SizedBox(height: m.px(10)),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(17),
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          SizedBox(height: m.px(3)),
          Text(
            videoMetaLine(item),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(13),
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
