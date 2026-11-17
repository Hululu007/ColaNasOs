import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../video/series_display.dart';
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

  /// 拉整库条目。
  ///
  /// `sortBy: 'createTime' + sortOrder: 'desc'` 就是「最新入库在最前」：
  /// 返回顺序即排序依据，客户端不再有入库时间字段，靠顺序当时间代理。
  Future<List<VideoItem>> _loadAllItems({
    String? sortBy,
    String? sortOrder,
  }) async {
    final client = ApiSession.instance.client;
    final out = <VideoItem>[];
    String? cursor;
    for (var page = 0; page < 10; page += 1) {
      final res = await client.videoList(
        libraryId: widget.library.id,
        limit: 200,
        cursor: cursor,
        sortBy: sortBy,
        sortOrder: sortOrder,
      );
      out.addAll(res.items);
      cursor = res.nextCursor;
      if (cursor == null || cursor.isEmpty) break;
    }
    return out;
  }

  Future<void> _loadSeries() async {
    final client = ApiSession.instance.client;
    // 中文剧名是展示层补充：拉不到就继续用 series 原名，不能卡住首页。
    unawaited(
      SeriesDisplayStore.ensure().then((_) {
        if (mounted) setState(() {});
      }),
    );
    try {
      final seriesRes = await _safe(
        client.videoSeriesList(
          libraryId: widget.library.id,
          limit: 200,
          sortBy: 'updated',
        ),
      );
      // 条目按添加时间倒序：剧卡的「最新入库」直接取这部剧最靠前的那一集。
      final items = await _loadAllItems(
        sortBy: 'createTime',
        sortOrder: 'desc',
      );
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
      final all = _orderSeries([...parsed, ...folder], items);
      final continueItems = buildContinueEntries(
        progress: progressRes?.items ?? const <VideoProgressItem>[],
        itemById: itemById,
        roots: roots,
      );

      setState(() {
        _itemsById = itemById;
        _progressById = progressById;
        _recentSeries = all.take(20).toList();
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

  /// 剧卡排序：**有未看的在前**，组内按「这部剧最新一集的添加时间」倒序。
  ///
  /// `items` 已经按入库时间倒序，所以「这部剧在列表里第一次出现的位置」就是
  /// 它的最新添加时间。只要还有一集没看就算未看（`unwatched > 0`），
  /// 不会再出现「看了一半的剧被压在已看完后面」。
  List<TvSeriesCard> _orderSeries(
    List<TvSeriesCard> cards,
    List<VideoItem> items,
  ) {
    final itemIndex = <String, int>{
      for (var i = 0; i < items.length; i += 1) items[i].id: i,
    };
    final seriesIndex = <String, int>{};
    for (var i = 0; i < items.length; i += 1) {
      final name = (items[i].series ?? '').trim();
      if (name.isEmpty) continue;
      seriesIndex.putIfAbsent(name, () => i);
    }
    final order = <TvSeriesCard, int>{};
    for (final card in cards) {
      if (!card.isFolder) {
        order[card] = seriesIndex[card.name] ?? 1 << 30;
        continue;
      }
      var best = 1 << 30;
      for (final item in card.preloadedItems) {
        final index = itemIndex[item.id];
        if (index != null && index < best) best = index;
      }
      order[card] = best;
    }
    return [...cards]..sort((a, b) {
      final aUnwatched = a.unwatched > 0;
      final bUnwatched = b.unwatched > 0;
      if (aUnwatched != bUnwatched) return aUnwatched ? -1 : 1;
      final byOrder = (order[a] ?? 1 << 30).compareTo(order[b] ?? 1 << 30);
      if (byOrder != 0) return byOrder;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  }

  Future<void> _loadMovies() async {
    final client = ApiSession.instance.client;
    try {
      // 影片按添加时间倒序；未看的（含看到一半的）在下面再提到前面。
      final items = await _loadAllItems(
        sortBy: 'createTime',
        sortOrder: 'desc',
      );
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
      final collections = <TvMovieCollection>[
        ...userCollections,
        ...heuristic,
      ];

      // 全部影片：未看（含看到一半）在前，组内保持入库时间倒序。
      // 合集成员也在其中：合集是入口，不该让单部影片从列表里消失。
      final ordered = _orderMovies(items, progressById);
      final entries = <TvMovieEntry>[
        for (final movie in ordered) TvMovieEntry.movie(movie),
      ];

      setState(() {
        _itemsById = itemById;
        _progressById = progressById;
        _items = ordered;
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

  /// 影片排序：未看的在前（已看完 = `watched` 或进度 ≥ 95%），组内保持
  /// 传进来的顺序 —— 调用方给的是「添加时间倒序」，所以最新的永远在最前。
  List<VideoItem> _orderMovies(
    List<VideoItem> items,
    Map<String, VideoProgressItem> progressById,
  ) {
    final unwatched = <VideoItem>[];
    final watched = <VideoItem>[];
    for (final item in items) {
      final percent = progressById[item.id]?.percent ?? 0;
      (item.watched || percent >= 95 ? watched : unwatched).add(item);
    }
    return <VideoItem>[...unwatched, ...watched];
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
        // 看完一集 / 一部之后，「未看优先」的分组会变，列表要跟着重排，
        // 否则刚看完的剧还赖在最前面。
        final source = _itemsById.values.toList();
        if (_isSeriesLibrary) {
          _continueItems = buildContinueEntries(
            progress: res.items,
            itemById: _itemsById,
            roots: _roots,
          );
          final all = _orderSeries(_allSeries, source);
          _recentSeries = all.take(20).toList();
          _allSeries = all;
        } else {
          _movieContinue = buildMovieContinue(
            progress: res.items,
            itemById: _itemsById,
          );
          final ordered = _orderMovies(source, progressById);
          _items = ordered;
          _movieEntries = <TvMovieEntry>[
            for (final movie in ordered) TvMovieEntry.movie(movie),
          ];
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
