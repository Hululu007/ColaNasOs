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
import 'tv_media_cover.dart';
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

  // 图片 / 混合库：文件夹视图（与 PC 端一致，不再整库平铺）。
  String _folderPath = '';
  String? _folderParent;
  List<VideoImageFolderNode> _folders = const <VideoImageFolderNode>[];
  List<VideoItem> _folderItems = const <VideoItem>[];
  List<VideoImageFolderSegment> _folderSegments =
      const <VideoImageFolderSegment>[];
  bool _folderLoading = false;

  // 日本电影库：演员列表 → 某位演员的作品。
  List<Map<String, dynamic>> _jpActors = const <Map<String, dynamic>>[];
  Map<String, dynamic>? _jpActor;
  List<VideoItem> _jpWorks = const <VideoItem>[];
  bool _jpLoading = false;

  /// 演员列表一次只渲染这么多张：500 个演员 = 500 个封面请求，
  /// 日本库的封面还在 SMB 网盘上，整批拉就是「打开很慢」。
  static const int _jpPageSize = 36;
  int _jpVisible = _jpPageSize;
  final ScrollController _jpScroll = ScrollController();

  final FocusNode _ownedFirstFocus = FocusNode(debugLabel: 'tv-video-first');
  FocusNode get _firstFocus => widget.firstFocusNode ?? _ownedFirstFocus;

  bool get _isSeriesLibrary =>
      widget.library.libType == 'tv' || widget.library.libType == 'short_tv';

  bool get _isMovieLibrary =>
      widget.library.libType == 'movie' || widget.library.libType == 'jp_movie';

  bool get _isJpLibrary => widget.library.libType == 'jp_movie';

  bool get _isImageLibrary =>
      widget.library.libType == 'image' || widget.library.libType == 'mixed';

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
      _movieDetail != null ||
      _jpActor != null ||
      _folderPath.isNotEmpty;

  @override
  void initState() {
    super.initState();
    widget.back.handler = _onBackPressed;
    widget.back.overlay = _hasOverlay;
    _jpScroll.addListener(_onJpScroll);
    if (_isSeriesLibrary) {
      _loadSeries();
    } else if (_isJpLibrary) {
      // 日本库按 PC 端口径先进演员列表；点演员再看她的作品。
      _loadJpActors();
    } else if (_isMovieLibrary) {
      _loadMovies();
    } else if (_isImageLibrary) {
      // 图片 / 混合库：文件夹视图（库根 = 第一层）。
      unawaited(_enterFolder(''));
    } else {
      _loadFlat();
    }
  }

  @override
  void dispose() {
    _jpScroll.removeListener(_onJpScroll);
    _jpScroll.dispose();
    if (widget.back.handler == _onBackPressed) {
      widget.back.handler = null;
      widget.back.overlay = null;
    }
    _ownedFirstFocus.dispose();
    super.dispose();
  }

  /// 滚到接近底部再补下一批演员（一次 48 张）。
  void _onJpScroll() {
    if (!_isJpLibrary || _jpActor != null) return;
    if (!_jpScroll.hasClients) return;
    final position = _jpScroll.position;
    if (position.pixels < position.maxScrollExtent - 600) return;
    if (_jpVisible >= _jpActors.length) return;
    setState(() {
      _jpVisible = (_jpVisible + _jpPageSize).clamp(0, _jpActors.length);
    });
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
        for (final entry in progressRes?.items ?? const <VideoProgressItem>[])
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
        for (final entry in progressRes?.items ?? const <VideoProgressItem>[])
          entry.itemId: entry,
      };

      // 用户合集：只保留当前库里真的有影片的，避免把别的库的合集混进来。
      final excluded = <String>{};
      final userCollections = <TvMovieCollection>[];
      final rawCollections = (userRes?.items ?? const <VideoCollection>[]).take(
        12,
      );
      final fetched = await Future.wait(
        rawCollections.map((raw) async {
          final res = await _safe(client.videoCollectionItems(id: raw.id));
          return (raw: raw, res: res);
        }),
      );
      for (final entry in fetched) {
        final movies =
            (entry.res?.items ?? const <VideoItem>[])
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
      final collections = <TvMovieCollection>[...userCollections, ...heuristic];

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

  // ---------------------------------------------------------------- 图片 / 混合库

  /// 进入某个文件夹（空串 = 库根）。一次拿「子文件夹 + 本层条目」。
  Future<void> _enterFolder(String path) async {
    final client = ApiSession.instance.client;
    setState(() {
      _folderLoading = true;
      _folderPath = path;
    });
    try {
      final foldersRes = await _safe(
        client.videoImageFolders(
          libraryId: widget.library.id,
          folderPath: path.isEmpty ? null : path,
        ),
      );
      final resolved = (foldersRes?.path ?? path).trim();
      final itemsRes = await _safe(
        client.videoList(
          libraryId: widget.library.id,
          folderPath: resolved.isEmpty ? null : resolved,
          folderMode: 'exact',
          limit: 200,
        ),
      );
      if (!mounted) return;
      setState(() {
        _folderPath = resolved;
        _folderParent = foldersRes?.parentPath;
        _folderSegments = foldersRes?.segments ?? const [];
        _folders = foldersRes?.folders ?? const <VideoImageFolderNode>[];
        _folderItems = itemsRes?.items ?? const <VideoItem>[];
        _folderLoading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _folderLoading = false;
        _error = '$e';
      });
    }
  }

  // ---------------------------------------------------------------- 日本库：演员

  Future<void> _loadJpActors() async {
    // 切 tab 回来会重建 State：有缓存就直接出，不再拉 900KB 的演员表。
    final cached = _TvJpActorCache.get(widget.library.id);
    if (cached != null) {
      setState(() {
        _jpActors = cached;
        _jpVisible = _jpPageSize;
        _jpLoading = false;
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() => _jpLoading = true);
    try {
      final res = await ApiSession.instance.client.videoJpActorList(
        libraryId: widget.library.id,
        limit: '500',
      );
      if (!mounted) return;
      final list = ((res['items'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      _TvJpActorCache.put(widget.library.id, list);
      setState(() {
        _jpActors = list;
        _jpVisible = _jpPageSize;
        _jpLoading = false;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _jpLoading = false;
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _openJpActor(Map<String, dynamic> actor) async {
    setState(() {
      _jpActor = actor;
      _jpWorks = const <VideoItem>[];
      _jpLoading = true;
    });
    try {
      final name = '${actor['name'] ?? ''}'.trim();
      final key = '${actor['key'] ?? ''}'.trim();
      final res = await ApiSession.instance.client.videoJpActorWorks(
        key: key.isEmpty ? null : key,
        name: name,
        libraryId: widget.library.id,
        limit: '2000',
      );
      if (!mounted) return;
      setState(() {
        _jpWorks = ((res['items'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => VideoItem.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _jpLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _jpLoading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _refreshProgress() async {
    if (_isJpLibrary || _isImageLibrary) return;
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
    // 日本库：作品 → 演员列表
    if (_jpActor != null) {
      setState(() => _jpActor = null);
      _restoreFirstFocus();
      return true;
    }
    // 文件夹视图：子目录 → 上一级
    if (_folderPath.isNotEmpty) {
      final parent = _folderParent ?? '';
      unawaited(_enterFolder(parent));
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
    // 日本库 / 图片库的加载态由各自的视图管（_loading 只服务剧 / 电影库）。
    if (_isJpLibrary) {
      return _jpActor != null ? _buildJpWorks() : _buildJpActors();
    }
    if (_isImageLibrary) return _buildFolders();
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return NasErrorState(
        message: _error!,
        onRetry: _isSeriesLibrary ? _loadSeries : _loadMovies,
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
        spacing: m.px(14),
        runSpacing: m.px(14),
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

  // ---------------------------------------------------------------- 网格工具

  /// 卡片网格：列数按屏宽自适应（与剧集 / 电影列表同一口径）。
  Widget _sixColumns(TvMetrics m, List<Widget> Function(double width) cells) {
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: m.px(6)),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final gap = m.px(14);
          final columns = tvGridColumns(constraints.maxWidth, m);
          // 减 1px：浮点误差会让最后一列掉到下一行
          final width =
              (constraints.maxWidth - gap * (columns - 1)) / columns - 1;
          return Wrap(
            spacing: gap,
            runSpacing: m.px(14),
            children: <Widget>[
              for (final cell in cells(width))
                SizedBox(width: width, child: cell),
            ],
          );
        },
      ),
    );
  }

  // ---------------------------------------------------------------- 图片 / 混合库

  String get _folderTitle {
    if (_folderSegments.isNotEmpty) return _folderSegments.last.name;
    return widget.library.name;
  }

  Widget _buildFolders() {
    if (_folderLoading && _folders.isEmpty && _folderItems.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return NasErrorState(
        message: _error!,
        onRetry: () => _enterFolder(_folderPath),
      );
    }
    if (_folders.isEmpty && _folderItems.isEmpty) {
      return NasEmptyState(
        title: tr('video.home.empty'),
        message: tr('video.home.emptyHint'),
        icon: Icons.folder_outlined,
      );
    }
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return SingleChildScrollView(
      padding: EdgeInsets.only(top: m.px(4), bottom: m.px(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TvSectionHeader(
            title: _folderTitle,
            trailing: Text(
              '${_folders.length + _folderItems.length} 项',
              style: TextStyle(
                fontSize: m.px(14),
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (_folders.isNotEmpty)
            _sixColumns(
              m,
              (w) => <Widget>[
                for (var i = 0; i < _folders.length; i += 1)
                  _TvFolderCard(
                    folder: _folders[i],
                    focusNode: i == 0 ? _firstFocus : null,
                    onTap: () => _enterFolder(_folders[i].path),
                  ),
              ],
            ),
          if (_folderItems.isNotEmpty) ...[
            SizedBox(height: m.px(18)),
            _sixColumns(
              m,
              (w) => <Widget>[
                for (var i = 0; i < _folderItems.length; i += 1)
                  _TvLibraryCard(
                    item: _folderItems[i],
                    width: w,
                    focusNode: _folders.isEmpty && i == 0 ? _firstFocus : null,
                    onTap: () => setState(() => _itemDetail = _folderItems[i]),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 日本库（演员）

  Widget _buildJpActors() {
    if (_jpLoading && _jpActors.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _loadJpActors);
    }
    if (_jpActors.isEmpty) {
      return NasEmptyState(
        title: tr('video.home.empty'),
        message: tr('video.home.emptyHint'),
        icon: Icons.person_outline,
      );
    }
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final shown = _jpVisible.clamp(0, _jpActors.length);
    return SingleChildScrollView(
      controller: _jpScroll,
      padding: EdgeInsets.only(top: m.px(4), bottom: m.px(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TvSectionHeader(
            title: tr('video.jp.actorTitle'),
            trailing: Text(
              shown < _jpActors.length
                  ? '$shown / ${_jpActors.length}'
                  : '${_jpActors.length}',
              style: TextStyle(
                fontSize: m.px(14),
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          _sixColumns(
            m,
            (w) => <Widget>[
              for (var i = 0; i < shown; i += 1)
                _TvActorCard(
                  actor: _jpActors[i],
                  focusNode: i == 0 ? _firstFocus : null,
                  onTap: () => _openJpActor(_jpActors[i]),
                ),
            ],
          ),
          if (shown < _jpActors.length)
            Padding(
              padding: EdgeInsets.only(top: m.px(18)),
              child: Center(
                child: Text(
                  '继续往下翻加载更多（$shown / ${_jpActors.length}）',
                  style: TextStyle(
                    fontSize: m.px(13),
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildJpWorks() {
    final actor = _jpActor;
    if (actor == null) return const SizedBox.shrink();
    if (_jpLoading && _jpWorks.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final name = '${actor['name'] ?? ''}'.trim();
    return SingleChildScrollView(
      padding: EdgeInsets.only(top: m.px(4), bottom: m.px(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TvSectionHeader(
            title: name.isEmpty ? widget.library.name : name,
            trailing: Text(
              tr('video.dup.actorCount', {'count': '${_jpWorks.length}'}),
              style: TextStyle(
                fontSize: m.px(14),
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          if (_jpWorks.isEmpty)
            Padding(
              padding: EdgeInsets.all(m.px(24)),
              child: Text(
                tr('video.home.empty'),
                style: TextStyle(
                  fontSize: m.px(16),
                  color: scheme.onSurfaceVariant,
                ),
              ),
            )
          else
            _sixColumns(
              m,
              (w) => <Widget>[
                for (var i = 0; i < _jpWorks.length; i += 1)
                  _TvLibraryCard(
                    item: _jpWorks[i],
                    width: w,
                    focusNode: i == 0 ? _firstFocus : null,
                    onTap: () => setState(() => _itemDetail = _jpWorks[i]),
                  ),
              ],
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
    this.width,
  });

  final VideoItem item;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  /// 网格按列数算出来的宽度；不传用设计稿默认值。
  final double? width;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = this.width ?? m.px(180);
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
          SizedBox(height: m.px(7)),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(14),
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          SizedBox(height: m.px(2)),
          Text(
            videoMetaLine(item),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(11),
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 文件夹卡（图片 / 混合库）：封面 + 名称 + 项数。
///
/// 和 PC 端一样「一个文件夹一张卡」，不再把整库几千张图平铺出来 ——
/// 平铺既慢（要拉全库 id）也不是用户找图的方式。
class _TvFolderCard extends StatelessWidget {
  const _TvFolderCard({
    required this.folder,
    required this.onTap,
    this.focusNode,
  });

  final VideoImageFolderNode folder;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cover = folder.cover is Map
        ? _videoItemOrNull(Map<String, dynamic>.from(folder.cover as Map))
        : null;
    final count = folder.count > 0
        ? folder.count
        : folder.imageCount + folder.videoCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvFocusCard(
          focusNode: focusNode,
          onTap: onTap,
          radius: m.px(14),
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: TvMediaCover(
              urls: <String?>[
                if (cover != null) videoPosterUrl(cover, size: 480),
              ],
              fallbackText: folder.name,
              icon: Icons.folder_outlined,
              cacheWidth: 480,
              borderRadius: m.px(14),
            ),
          ),
        ),
        SizedBox(height: m.px(9)),
        Text(
          folder.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.px(16),
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        SizedBox(height: m.px(3)),
        Text(
          '$count 项',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: m.px(12), color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 日本库演员卡：作品海报优先，没有就用演员头像（远程 CDN）。
///
/// 头像走远程 CDN，**不能带 Authorization**：会触发 CORS 预检被浏览器挡掉。
/// 只有本服务的海报接口才需要认证头。
class _TvActorCard extends StatelessWidget {
  const _TvActorCard({
    required this.actor,
    required this.onTap,
    this.focusNode,
  });

  final Map<String, dynamic> actor;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final rawCover = actor['coverItem'];
    final cover = rawCover is Map
        ? _videoItemOrNull(Map<String, dynamic>.from(rawCover))
        : null;
    final avatar = '${actor['avatarUrl'] ?? ''}'.trim();
    final urls = <String?>[
      if (cover != null) videoPosterUrl(cover, size: 480),
      if (cover == null && avatar.isNotEmpty) avatar,
    ];
    final count = actor['count'] ?? actor['items'];
    final name = '${actor['name'] ?? ''}'.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvFocusCard(
          focusNode: focusNode,
          onTap: onTap,
          radius: m.px(14),
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: TvMediaCover(
              urls: urls,
              fallbackText: name,
              icon: Icons.person_outline,
              // 卡片宽度 ~250 逻辑像素，360 足够清晰；别再按 480 拉
              // —— 日本库封面在 SMB 上，一次 36 张就是 36 次网盘读。
              cacheWidth: 360,
              headers: cover != null
                  ? videoArtHeaders
                  : const <String, String>{},
              borderRadius: m.px(14),
            ),
          ),
        ),
        SizedBox(height: m.px(9)),
        Text(
          name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.px(16),
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        SizedBox(height: m.px(3)),
        Text(
          count is int && count > 0
              ? tr('video.dup.actorCount', {'count': '$count'})
              : '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: m.px(12), color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// 服务端 JSON → VideoItem；字段不全（老条目 / 精简结构）时返回 null，绝不抛。
VideoItem? _videoItemOrNull(Map<String, dynamic> json) {
  try {
    return VideoItem.fromJson(json);
  } catch (_) {
    return null;
  }
}

/// 日本库演员表的进程内缓存（10 分钟）。
///
/// `/video/jp_actor/list?limit=500` 实测 900KB+，切回 tab 会重建 State 并重新拉一遍；
/// 库里演员不会秒变，缓存一份就能「切走再回来」秒开。
class _TvJpActorCache {
  _TvJpActorCache._();

  static const Duration _ttl = Duration(minutes: 10);
  static final Map<String, ({List<Map<String, dynamic>> items, DateTime at})>
  _map = <String, ({List<Map<String, dynamic>> items, DateTime at})>{};

  static List<Map<String, dynamic>>? get(String libraryId) {
    final hit = _map[libraryId];
    if (hit == null) return null;
    if (DateTime.now().difference(hit.at) > _ttl) {
      _map.remove(libraryId);
      return null;
    }
    return hit.items;
  }

  static void put(String libraryId, List<Map<String, dynamic>> items) {
    _map[libraryId] = (items: items, at: DateTime.now());
  }
}
