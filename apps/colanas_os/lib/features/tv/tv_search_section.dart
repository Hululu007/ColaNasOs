import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../music/music_playback.dart';
import '../video/series_display.dart';
import '../video/video_card.dart';
import 'tv_focus.dart';
import 'tv_media_cover.dart';
import 'tv_video_section.dart' show playTvVideo;
import 'music/tv_music_detail.dart';
import 'movie/tv_movie_detail.dart';
import 'movie/tv_movie_models.dart';
import 'video/tv_series_detail.dart';
import 'video/tv_series_models.dart';

/// TV 端**全站**搜索（电影 / 电视剧 / 歌曲 / 专辑 / 歌手）。
///
/// 布局（对齐设计稿）：
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │ [ 搜索框：已输入的字母 ]                        │
/// ├───────────────────┬──────────────────────────┤
/// │  Q W E R T Y ...  │  电影                       │
/// │  A S D F G H ...  │  [卡][卡][卡][卡][卡]        │
/// │  Z X C V B N M    │  电视剧                     │
/// │  [清空]  [退格]    │  [卡][卡]                   │
/// └───────────────────┴──────────────────────────┘
/// ```
///
/// 焦点只有两条路：键盘 ←→ 右侧栏目。
///   · 键盘某行最右列按 → ：进右侧第一个栏目的第一张卡；
///   · 卡片最左列按 ← ：回键盘；
///   · 栏目内 ←→ 横移，到最右**拦住**（不横向滚动，也不跨栏目）；
///   · ↑↓ 跳到上/下一个栏目的同一列，不足则落最后一张；
///   · 返回键：右侧有焦点 → 先收键盘；键盘上有焦点 → 交给外壳（回上一个 tab）。
///
/// 输入即搜（300ms 防抖），不需要再按「搜索」按钮 —— 遥控器每输入一个字母
/// 还要挪到按钮上按一下，是这类页面最烦的地方。
class TvSearchSection extends StatefulWidget {
  const TvSearchSection({super.key, required this.back, this.firstFocusNode});

  final TvBackController back;
  final FocusNode? firstFocusNode;

  @override
  State<TvSearchSection> createState() => _TvSearchSectionState();
}

class _TvSearchSectionState extends State<TvSearchSection> {
  static const String _historyKey = 'tv.search.history';
  static const int _historyMax = 8;

  /// 设计约束：栏目最多 5 张卡、不横向滚动
  static const int _sectionMax = 5;

  static const List<String> _rowChars = <String>['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];

  final TextEditingController _query = TextEditingController();
  final FocusNode _clearKey = FocusNode(debugLabel: 'tv-key-clear');
  final FocusNode _backspaceKey = FocusNode(debugLabel: 'tv-key-backspace');

  /// 每行字母一套焦点节点
  final List<List<FocusNode>> _keys = <List<FocusNode>>[];
  final Set<FocusNode> _ownedNodes = <FocusNode>{};

  /// 栏目 → 每张卡的焦点节点
  final Map<String, List<FocusNode>> _cards = <String, List<FocusNode>>{};

  /// 结果刷新时被换下来的旧节点：还要等这一帧用新节点建完才能 dispose
  final Set<FocusNode> _retired = <FocusNode>{};

  String? _lastSection;
  int _lastIndex = 0;

  Timer? _debounce;
  int _searchSeq = 0;

  /// 组件是否还活着。`mounted` 在元素 unmount 的瞬间仍是 true（`State._element`
  /// 要等 `dispose()` 返回后才清空），异步回调正好落在那个窗口里 setState 就会撞
  /// "markNeedsBuild on defunct element"。搜索页有几个 100ms 级的网络回调，
  /// 退出页面时必然踩得到 —— 用自己维护的标记把这个窗口关掉。
  bool _alive = true;

  bool get _canSetState => _alive && mounted;

  bool _loading = false;
  String? _error;
  String _submitted = '';

  List<TvSeriesCard> _series = const <TvSeriesCard>[];
  List<VideoItem> _videos = const <VideoItem>[];
  List<MusicTrack> _tracks = const <MusicTrack>[];
  List<MusicAlbum> _albums = const <MusicAlbum>[];
  List<MusicArtist> _artists = const <MusicArtist>[];

  List<String> _history = const <String>[];

  /// 未输入时右侧展示的「最近添加」：电影单体 + 电视剧（整部剧一张卡）。
  List<VideoItem> _recentMovies = const <VideoItem>[];
  List<TvSeriesCard> _recentSeries = const <TvSeriesCard>[];

  /// 库 id → 库类型。搜索结果必须按库类型分流，否则电视剧库里的散文件
  /// （健身课、单集视频）会混进「电影」栏目。
  Map<String, String> _libTypes = const <String, String>{};
  List<VideoLibraryItem> _libs = const <VideoLibraryItem>[];

  /// 电视剧库的来源根，给「按文件夹聚合成剧」用。
  List<String> _libRoots = const <String>[];

  VideoItem? _videoDetail;
  TvSeriesCard? _seriesDetail;
  String _seriesLibraryId = '';
  TvMusicDetailSpec? _musicDetail;
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    // 键盘节点在 initState 建好：外壳可能一进来就 focus `firstFocusNode`，
    // 那个节点要真的挂在某个键上才有效。
    for (var r = 0; r < _rowChars.length; r += 1) {
      final row = <FocusNode>[];
      for (var c = 0; c < _rowChars[r].length; c += 1) {
        // ⛔ `firstFocusNode` 是外壳按 tab 长期持有的节点（`tv_shell._contentNodeFor`），
        // 这里只是**借用**。以前把它一起塞进 `_ownedNodes`，退出这个 tab 时顺手
        // dispose 掉了外壳的节点 —— 再切回来，外壳把同一个（已销毁的）节点交给
        // 下一张卡片，于是抛 "A FocusNode was used after being disposed"。
        final borrowed = r == 0 && c == 0 && widget.firstFocusNode != null;
        final node = borrowed
            ? widget.firstFocusNode!
            : FocusNode(debugLabel: 'tv-key-$r-$c');
        if (!borrowed) _ownedNodes.add(node);
        // 方向键挂在节点上，节点交给 TvFocusCard 独占使用。
        // ⛔ 外面不能再套 Focus(focusNode: 同一个节点)：一个 FocusNode 只能挂一个
        // Focus，否则直接抛 "Tried to make a child into a parent of itself"。
        final rowIndex = r;
        final colIndex = c;
        node.onKeyEvent = (_, event) => _handleKey(event, rowIndex, colIndex);
        row.add(node);
      }
      _keys.add(row);
    }
    _clearKey.onKeyEvent = (_, event) => _handleActionKey(event, left: true);
    _backspaceKey.onKeyEvent = (_, event) => _handleActionKey(event, left: false);
    widget.back.handler = _onBackPressed;
    widget.back.overlay = _hasOverlay;
    _query.addListener(_onQueryChanged);
    _loadHistory();
    _loadLibraries();
    // 中文剧名：服务端 `series` 列是英文发布名，展示要换成 TMDB / 路径里的中文名。
    unawaited(
      SeriesDisplayStore.ensure().then((_) {
        if (!_canSetState) return;
        setState(() {});
      }),
    );
  }

  @override
  void dispose() {
    _alive = false;
    if (widget.back.handler == _onBackPressed) {
      widget.back.handler = null;
      widget.back.overlay = null;
    }
    _debounce?.cancel();
    _query.removeListener(_onQueryChanged);
    _query.dispose();
    // 借来的节点只摘回调，绝不 dispose（它归外壳，切 tab 还要用）
    widget.firstFocusNode?.onKeyEvent = null;
    for (final node in _ownedNodes) {
      node.dispose();
    }
    for (final node in <FocusNode>[_clearKey, _backspaceKey]) {
      node.dispose();
    }
    for (final list in _cards.values) {
      for (final node in list) {
        node.dispose();
      }
    }
    // 上一批卡片节点可能还在「等这一帧建完再收」的队列里
    for (final node in _retired) {
      node.dispose();
    }
    _retired.clear();
    super.dispose();
  }

  bool _onBackPressed() => _handleBack();

  bool _hasOverlay() =>
      _videoDetail != null || _seriesDetail != null || _musicDetail != null;

  bool _handleBack() {
    if (_videoDetail != null) {
      setState(() => _videoDetail = null);
      _restoreFocus();
      return true;
    }
    if (_seriesDetail != null) {
      setState(() => _seriesDetail = null);
      _restoreFocus();
      return true;
    }
    if (_musicDetail != null) {
      setState(() => _musicDetail = null);
      _restoreFocus();
      return true;
    }
    // 右侧有焦点 → 先收回键盘（设计：返回分两级，一次返回直接退出容易误触丢输入）
    if (_resultsFocused) {
      _focusKeyboard();
      return true;
    }
    return false;
  }

  void _restoreFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_canSetState) _focusKeyboard();
    });
  }

  Future<T?> _safe<T>(Future<T> future) async {
    try {
      return await future;
    } catch (_) {
      return null;
    }
  }

  // ---------------------------------------------------------------- 输入

  void _onQueryChanged() {
    _debounce?.cancel();
    // 450ms：遥控器连按字母时，300ms 会在一串按键里跑起好几轮查询
    _debounce = Timer(const Duration(milliseconds: 450), _search);
    setState(() {}); // 顶部搜索框要立刻回显按键
  }

  void _append(String char) {
    final text = _query.text + char;
    _query.text = text;
    _query.selection = TextSelection.collapsed(offset: text.length);
  }

  void _backspace() {
    final text = _query.text;
    if (text.isEmpty) return;
    final next = text.substring(0, text.length - 1);
    _query.text = next;
    _query.selection = TextSelection.collapsed(offset: next.length);
  }

  Future<void> _loadHistory() async {
    final raw = SettingsStore.instance.getString(_historyKey) ?? '';
    if (!_canSetState) return;
    setState(() {
      _history = raw
          .split('\u0000')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    });
  }

  Future<void> _remember(String keyword) async {
    final q = keyword.trim();
    if (q.isEmpty) return;
    final next = <String>[q, ..._history.where((e) => e != q)].take(_historyMax).toList();
    setState(() => _history = next);
    await SettingsStore.instance.setString(_historyKey, next.join('\u0000'));
  }

  /// 先拿库列表：搜索与「最近添加」都要按库类型把电影 / 电视剧分开。
  Future<void> _loadLibraries() async {
    try {
      final res = await ApiSession.instance.client.videoLibraryList();
      final types = <String, String>{};
      final roots = <String>[];
      for (final lib in res.items) {
        types[lib.id] = lib.libType;
        final isTv = lib.libType == 'tv' || lib.libType == 'short_tv';
        if (!isTv) continue;
        final sources = lib.sources ?? const <VideoSourceItem>[];
        for (final source in sources) {
          final path = source.path.trim();
          if (path.isNotEmpty) roots.add(path);
        }
        if (sources.isEmpty && lib.path.trim().isNotEmpty) {
          roots.add(lib.path.trim());
        }
      }
      if (!_canSetState) return;
      _libTypes = types;
      _libRoots = roots;
      _libs = res.items;
    } catch (_) {
      // 库列表拉不到就按老逻辑（有 series / 集号的归剧，其余归电影）
    }
    await _loadRecent();
  }

  bool _isTvLibrary(String id) {
    final type = _libTypes[id];
    return type == 'tv' || type == 'short_tv';
  }

  bool _isMovieLibrary(String id) {
    final type = _libTypes[id];
    return type == 'movie' || type == 'jp_movie';
  }

  /// 未输入时的右侧内容：最近添加的电影 + 最近添加的电视剧（整部剧一张卡）。
  ///
  /// 只取**电影库 / 电视剧库**：混合库（下载目录）里什么都有，按「整库最近
  /// 200 条」拉会把搜索页占满，而且全是下载杂项。按库分别拉 12 条，
  /// 保证每个库都有代表、又不会互相挤掉。
  Future<void> _loadRecent() async {
    final client = ApiSession.instance.client;
    try {
      final libs = _libs
          .where((lib) => _isTvLibrary(lib.id) || _isMovieLibrary(lib.id))
          .toList();
      final movies = <VideoItem>[];
      final tvItems = <VideoItem>[];
      if (libs.isEmpty) {
        // 库列表没拿到：退回整库最近 200 条，按剧集信息分流。
        final res = await client.videoList(
          sortBy: 'createTime',
          sortOrder: 'desc',
          limit: 200,
        );
        for (final item in res.items) {
          if (item.mediaType == 'image') continue;
          if ((item.series ?? '').trim().isNotEmpty ||
              item.season != null ||
              item.episode != null) {
            tvItems.add(item);
          } else {
            movies.add(item);
          }
        }
      } else {
        final responses = await Future.wait(
          libs.map(
            (lib) => _safe(
              client.videoList(
                libraryId: lib.id,
                sortBy: 'createTime',
                sortOrder: 'desc',
                limit: 12,
              ),
            ),
          ),
        );
        for (var i = 0; i < libs.length; i += 1) {
          final items = responses[i]?.items ?? const <VideoItem>[];
          if (_isTvLibrary(libs[i].id)) {
            tvItems.addAll(items);
          } else {
            movies.addAll(items.where((item) => item.mediaType != 'image'));
          }
        }
      }
      if (!_canSetState) return;
      final series = _orderRecentSeries(_groupSeriesCards(tvItems), tvItems);
      setState(() {
        _recentMovies = movies.take(10).toList();
        _recentSeries = series.take(10).toList();
      });
      _rebuildCards();
    } catch (_) {
      // 最近添加拉不到就只显示历史记录
    }
  }

  /// 剧卡按「这部剧最新一集在时间倒序列表里的位置」排。
  List<TvSeriesCard> _orderRecentSeries(
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
      final byOrder = (order[a] ?? 1 << 30).compareTo(order[b] ?? 1 << 30);
      if (byOrder != 0) return byOrder;
      return a.name.compareTo(b.name);
    });
  }

  /// 电视剧库条目 → 剧卡：有 `series` 的按剧名聚，没有的按文件夹聚
  /// （与服务端聚合口径一致，整部剧只出一张卡）。
  List<TvSeriesCard> _groupSeriesCards(List<VideoItem> items) {
    if (items.isEmpty) return const <TvSeriesCard>[];
    final bySeries = <String, List<VideoItem>>{};
    final loose = <VideoItem>[];
    for (final item in items) {
      final name = (item.series ?? '').trim();
      if (name.isEmpty) {
        loose.add(item);
        continue;
      }
      bySeries.putIfAbsent(name, () => <VideoItem>[]).add(item);
    }
    return <TvSeriesCard>[
      for (final entry in bySeries.entries)
        _seriesCardFrom(name: entry.key, items: entry.value),
      ...buildFolderSeries(
        items: loose,
        roots: _libRoots,
        progressById: const <String, VideoProgressItem>{},
      ),
    ];
  }

  // ---------------------------------------------------------------- 搜索

  Future<void> _search() async {
    final q = _query.text.trim();
    final seq = ++_searchSeq;
    if (!_canSetState) return;
    if (q.isEmpty) {
      setState(() {
        _submitted = '';
        _loading = false;
        _error = null;
        _videos = const <VideoItem>[];
        _series = const <TvSeriesCard>[];
        _tracks = const <MusicTrack>[];
        _albums = const <MusicAlbum>[];
        _artists = const <MusicArtist>[];
      });
      _rebuildCards();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _submitted = q;
      _videoDetail = null;
      _seriesDetail = null;
    });

    final client = ApiSession.instance.client;
    // 一两个字（ad / 周）命中面太大，专辑 / 歌手的分组聚合又最慢 —— 先不给。
    // 等用户多打两个字（≥3）再补上这两个栏目。
    final rich = q.length >= 3;
    final futures = <Future<Object?>>[
      _safe(client.videoList(q: q, limit: 60)),
      _safe(client.videoSeriesList(q: q, limit: 20)),
      _safe(client.musicList(q: q, limit: 30)),
    ];
    if (rich) {
      futures.add(_safe(client.musicAlbums(q: q, limit: 16)));
      futures.add(_safe(client.musicArtists(q: q, limit: 16)));
    }
    final results = await Future.wait<Object?>(futures);
    // 输入还在继续：这一批结果已经过期，直接丢掉（防抖后仍可能连发）
    if (!_canSetState || seq != _searchSeq) return;

    final videoRes = results[0] as VideoListResponse?;
    final seriesRes = results[1] as VideoSeriesListResponse?;
    final trackRes = results[2] as MusicListResponse?;
    final albumRes = results.length > 3 ? results[3] as MusicAlbumListResponse? : null;
    final artistRes = results.length > 4 ? results[4] as MusicArtistListResponse? : null;

    final videos = <VideoItem>[];
    final tvItems = <VideoItem>[];
    final bySeries = <String, List<VideoItem>>{};
    for (final item in videoRes?.items ?? const <VideoItem>[]) {
      if (item.mediaType == 'image') continue;
      // 电视剧库的条目全部按「剧」聚合：里面的散文件（健身课、单集视频）
      // 也属于电视剧库，不能落到「电影」栏目里。
      if (_isTvLibrary(item.libraryId)) {
        tvItems.add(item);
        continue;
      }
      final name = (item.series ?? '').trim();
      // 带集号的条目一定是剧的某一集：不管有没有 series 字段，都归到剧名下，
      // 不然搜索「XXX」会刷出一排「第 1 集 / 第 2 集」，用户要的是那部剧。
      final looksEpisode = item.season != null || item.episode != null;
      if (name.isEmpty && !looksEpisode) {
        videos.add(item);
      } else {
        final key = name.isEmpty ? seriesKeyOfTitle(item.title) : name;
        bySeries.putIfAbsent(key, () => <VideoItem>[]).add(item);
      }
    }
    final series = <TvSeriesCard>[
      for (final entry in bySeries.entries)
        _seriesCardFrom(name: entry.key, items: entry.value),
    ];
    for (final card in _groupSeriesCards(tvItems)) {
      if (series.any((item) => item.name == card.name)) continue;
      series.add(card);
    }
    for (final item in seriesRes?.items ?? const <VideoSeriesItem>[]) {
      if (series.any((card) => card.name == item.name)) continue;
      series.add(
        TvSeriesCard(
          name: item.name,
          seasons: item.seasons,
          episodes: item.episodes,
          watchedEpisodes: item.watchedEpisodes ?? 0,
          coverId: item.coverId,
          posterId: item.posterId,
        ),
      );
    }

    setState(() {
      _videos = videos;
      _series = series;
      _tracks = trackRes?.items ?? const <MusicTrack>[];
      _albums = albumRes?.items ?? const <MusicAlbum>[];
      _artists = artistRes?.items ?? const <MusicArtist>[];
      _loading = false;
      _error = (videoRes == null &&
              seriesRes == null &&
              trackRes == null &&
              albumRes == null &&
              artistRes == null)
          ? tr('common.error')
          : null;
    });
    _rebuildCards();
  }

  /// 剧卡封面：本地 / 刮削海报（多级兜底）→ TMDB 剧海报（公网 CDN，不需要鉴权）。
  List<String?> _seriesCoverList(TvSeriesCard card) => <String?>[
    ...seriesCoverUrls(card, size: 360),
    SeriesDisplayStore.posterOf(card.name),
  ];

  /// 把同一部剧的条目聚成剧卡（首页卡片与详情页共用同一结构）。
  TvSeriesCard _seriesCardFrom({
    required String name,
    required List<VideoItem> items,
  }) {
    final sorted = [...items]..sort((a, b) {
      final season = (a.season ?? 1).compareTo(b.season ?? 1);
      if (season != 0) return season;
      return (a.episode ?? 0).compareTo(b.episode ?? 0);
    });
    final cover = sorted.firstWhere(
      (item) => item.hasArt,
      orElse: () => sorted.first,
    );
    final seasons = <int>{for (final item in sorted) item.season ?? 1};
    return TvSeriesCard(
      name: name,
      seasons: seasons.isEmpty ? 1 : seasons.length,
      episodes: sorted.length,
      watchedEpisodes: sorted.where((item) => item.watched).length,
      coverId: cover.id,
      firstItem: cover,
      year: cover.year,
      overview: sorted
          .map((item) => item.overview)
          .firstWhere(
            (value) => (value ?? '').trim().isNotEmpty,
            orElse: () => null,
          ),
      preloadedItems: sorted,
    );
  }

  // ---------------------------------------------------------------- 焦点

  /// 栏目的可见顺序（空栏目不渲染，也就不参与焦点）
  List<String> get _visibleKeys => _submitted.isEmpty
      ? <String>[
          if (_recentMovies.isNotEmpty) 'recentMovie',
          if (_recentSeries.isNotEmpty) 'recentTv',
        ]
      : <String>[
          if (_videos.isNotEmpty) 'movie',
          if (_series.isNotEmpty) 'tv',
          if (_tracks.isNotEmpty) 'track',
          if (_albums.isNotEmpty) 'album',
          if (_artists.isNotEmpty) 'artist',
        ];

  bool get _resultsFocused =>
      _cards.values.any((list) => list.any((node) => node.hasFocus));

  void _focusKeyboard() {
    if (_keys.isNotEmpty && _keys[0].isNotEmpty) {
      _keys[0][0].requestFocus();
    }
  }

  void _focusFirstResult() {
    final keys = _visibleKeys;
    if (keys.isEmpty) return;
    final nodes = _cards[keys.first];
    if (nodes == null || nodes.isEmpty) return;
    _lastSection = keys.first;
    _lastIndex = 0;
    nodes.first.requestFocus();
  }

  void _moveSection(String sectionKey, int index, int delta) {
    final keys = _visibleKeys;
    final current = keys.indexOf(sectionKey);
    if (current < 0) return;
    final target = current + delta;
    if (target < 0 || target >= keys.length) return;
    final nodes = _cards[keys[target]];
    if (nodes == null || nodes.isEmpty) return;
    final next = index.clamp(0, nodes.length - 1);
    _lastSection = keys[target];
    _lastIndex = next;
    nodes[next].requestFocus();
  }

  KeyEventResult _handleCardKey(String sectionKey, int index, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    _lastSection = sectionKey;
    _lastIndex = index;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index > 0) {
        _cards[sectionKey]?[index - 1].requestFocus();
        _lastIndex = index - 1;
      } else {
        _focusKeyboard();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      final nodes = _cards[sectionKey];
      if (nodes == null) return KeyEventResult.handled;
      if (index >= nodes.length - 1) {
        // 到最右就拦住：不横向滚，也不跨栏目
        return KeyEventResult.handled;
      }
      nodes[index + 1].requestFocus();
      _lastIndex = index + 1;
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSection(sectionKey, index, -1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveSection(sectionKey, index, 1);
      return KeyEventResult.handled;
    }
    return _handleTypeKey(event);
  }

  /// 物理键盘直接输入（PC 客户端 / 网页预览）。
  ///
  /// 搜索框只回显、输入全靠屏上键盘 —— 在电脑上看着一个键盘却必须用鼠标一个个点，
  /// 是最容易被当成「搜索坏了」的地方。字母 / 数字直接落进查询串，退格删一个字。
  KeyEventResult _handleTypeKey(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _backspace();
      return KeyEventResult.handled;
    }
    final char = event.character;
    if (char == null || char.isEmpty) return KeyEventResult.ignored;
    // 控制字符（回车 / Tab / 方向键）交给外层的焦点逻辑，不当输入
    if (char.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
      return KeyEventResult.ignored;
    }
    // 一个字符最多 4 个 code unit（emoji/组合符号），再多就是整句粘贴，忽略
    if (char.length > 4) return KeyEventResult.ignored;
    _append(char);
    return KeyEventResult.handled;
  }

  KeyEventResult _handleKey(KeyEvent event, int row, int col) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final rows = _keys;

    if (key == LogicalKeyboardKey.arrowRight) {
      if (col >= rows[row].length - 1) {
        _focusFirstResult();
      } else {
        rows[row][col + 1].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (col > 0) rows[row][col - 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (row > 0) {
        final target = rows[row - 1];
        target[col.clamp(0, target.length - 1)].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (row == rows.length - 1) {
        _clearKey.requestFocus();
      } else {
        final target = rows[row + 1];
        target[col.clamp(0, target.length - 1)].requestFocus();
      }
      return KeyEventResult.handled;
    }
    return _handleTypeKey(event);
  }

  KeyEventResult _handleActionKey(KeyEvent event, {required bool left}) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      final last = _keys.isEmpty ? null : _keys.last;
      if (last != null && last.isNotEmpty) last[0].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (!left) _clearKey.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (left) {
        _backspaceKey.requestFocus();
      } else {
        _focusFirstResult();
      }
      return KeyEventResult.handled;
    }
    return _handleTypeKey(event);
  }

  /// 结果变了就重建卡片节点，并在帧后把焦点校准到仍然存在的卡片上
  /// （否则输入一个字母让结果变少，焦点会掉回根节点，遥控器得从头按起）。
  ///
  /// 两条必须守住的规矩：
  ///  1. 焦点本来不在结果里（用户在屏上键盘打字）就**不要**接焦点 —— 否则第一个
  ///     字母搜出结果的一瞬间焦点被拽到卡片上，后面的字母全按在卡片上，
  ///     「ads」永远只输得进「a」。
  ///  2. 旧节点这一帧还挂在 `TvSearchCard` 上，立刻 dispose 会让下一帧的
  ///     `FocusableActionDetector` 拿到已销毁的节点，直接抛
  ///     "A FocusNode was used after being disposed"。等帧末再收。
  void _rebuildCards() {
    final previous = _lastSection;
    final previousIndex = _lastIndex;
    // 必须在回收节点之前取：节点没了 hasFocus 就永远 false
    final hadResultFocus = _resultsFocused;
    for (final list in _cards.values) {
      _retired.addAll(list);
    }
    _cards.clear();
    void build(String key, int count) {
      if (count <= 0) return;
      _cards[key] = List<FocusNode>.generate(count, (i) {
        final node = FocusNode(debugLabel: 'tv-card-$key-$i');
        node.onKeyEvent = (_, event) => _handleCardKey(key, i, event);
        return node;
      });
    }

    build('recentMovie', _recentMovies.length);
    build('recentTv', _recentSeries.length);
    build('movie', _videos.length);
    build('tv', _series.length);
    build('track', _tracks.length);
    build('album', _albums.length);
    build('artist', _artists.length);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (hadResultFocus) {
        final keys = _visibleKeys;
        if (keys.isEmpty) {
          // 结果被搜空了：别把焦点丢在根节点上，退回键盘继续输入
          _focusKeyboard();
        } else {
          final target = previous != null && keys.contains(previous) ? previous : keys.first;
          final nodes = _cards[target];
          if (nodes != null && nodes.isNotEmpty) {
            final index = previousIndex.clamp(0, nodes.length - 1);
            _lastSection = target;
            _lastIndex = index;
            nodes[index].requestFocus();
          }
        }
      }
      _disposeRetired();
    });
  }

  /// 收掉换下来的旧节点（`dispose()` 里也会调，重复调用安全）
  void _disposeRetired() {
    for (final node in _retired.toList()) {
      _retired.remove(node);
      node.dispose();
    }
  }

  // ---------------------------------------------------------------- 打开

  /// 电影：进单片详情页（大图 + 简介 + 播放按钮）
  void _openVideo(VideoItem item) {
    unawaited(_remember(_query.text));
    setState(() {
      _videoDetail = item;
      _seriesDetail = null;
      _musicDetail = null;
    });
  }

  Future<void> _openSeries(TvSeriesCard card) async {
    if (card.preloadedItems.isNotEmpty) {
      setState(() {
        _seriesDetail = card;
        _seriesLibraryId = card.preloadedItems.first.libraryId;
      });
      unawaited(_remember(_query.text));
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ApiSession.instance.client.videoSeriesItems(
        name: card.name,
        limit: 200,
      );
      if (!mounted) return;
      if (res.items.isEmpty) {
        setState(() => _loading = false);
        NasSnack.show(
          context,
          tr('tv.search.noResult', {
            'q': SeriesDisplayStore.nameOf(card.name) ?? card.name,
          }),
        );
        return;
      }
      final first = res.items.first;
      setState(() {
        _loading = false;
        _seriesLibraryId = first.libraryId;
        _seriesDetail = TvSeriesCard(
          name: card.name,
          seasons: card.seasons,
          episodes: card.episodes,
          watchedEpisodes: card.watchedEpisodes,
          coverId: card.coverId,
          posterId: card.posterId,
          firstItem: first,
          preloadedItems: res.items,
        );
      });
      unawaited(_remember(_query.text));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = tr('tv.search.failed', {'error': '$e'});
      });
    }
  }

  Future<void> _play(VideoItem item) async {
    if (_preparing) return;
    setState(() => _preparing = true);
    try {
      unawaited(_remember(_query.text));
      await playTvVideo(context, item);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('video.playUrlFailed', {'error': '$e'}))),
      );
    } finally {
      if (_canSetState) setState(() => _preparing = false);
    }
  }

  /// 点一首歌：进它所在的专辑，并从这一首开始播。
  ///
  /// 队列必须是**整张专辑**：只把这一首塞进队列的话，「下一首」到此为止，
  /// 用户会以为播放器坏了。
  Future<void> _openTrack(MusicTrack track) async {
    unawaited(_remember(_query.text));
    final album = (track.album ?? '').trim();
    final artist = (track.artist ?? '').trim();
    if (album.isEmpty) {
      // 散装曲目（没有专辑信息）：播这一首就好，没有可进的详情页
      MusicPlaybackService.instance.playQueue(<MusicTrack>[track], 0);
      return;
    }
    final tracks = ApiSession.instance.client
        .musicList(album: album, limit: 200)
        .then<List<MusicTrack>>((res) => res.items);
    setState(() {
      _musicDetail = TvMusicDetailSpec(
        kind: TvMusicDetailKind.album,
        title: album,
        subtitle: artist.isEmpty ? null : artist,
        year: track.year,
        coverTrackId: track.id,
        tracks: tracks,
        sampleTracks: <MusicTrack>[track],
      );
    });
    await _startQueue(tracks, track.id, fallback: track);
  }

  Future<void> _openAlbum(MusicAlbum album) async {
    unawaited(_remember(_query.text));
    final tracks = ApiSession.instance.client
        .musicList(album: album.name, limit: 200)
        .then<List<MusicTrack>>((res) => res.items);
    setState(() {
      _musicDetail = TvMusicDetailSpec(
        kind: TvMusicDetailKind.album,
        title: album.name,
        subtitle: album.artist,
        year: album.year,
        coverTrackId: album.coverTrackId,
        tracks: tracks,
        trackCountHint: album.tracks,
        durationHint: album.durationMs,
      );
    });
    // 点专辑 = 想听这张：进详情的同时起播第一首
    await _startQueue(tracks, null);
  }

  Future<void> _openArtist(MusicArtist artist) async {
    unawaited(_remember(_query.text));
    await _openArtistByName(
      artist.name,
      coverTrackId: artist.coverTrackId,
      trackCount: artist.tracks,
      durationMs: artist.durationMs,
    );
  }

  /// 详情抽屉里的「查看歌手」也走这里（`autoplay: false`：用户只是想看他有哪些歌）
  Future<void> _openArtistByName(
    String name, {
    String? coverTrackId,
    int? trackCount,
    int? durationMs,
    bool autoplay = true,
  }) async {
    final tracks = ApiSession.instance.client
        .musicList(artist: name, limit: 200)
        .then<List<MusicTrack>>((res) => res.items);
    setState(() {
      _musicDetail = TvMusicDetailSpec(
        kind: TvMusicDetailKind.artist,
        title: name,
        subtitle: tr('music.nav.artists'),
        coverTrackId: coverTrackId,
        tracks: tracks,
        // 搜索结果里已经拿到的这个歌手的歌：列表接口因目录权限返空时兜底
        sampleTracks: _tracks
            .where((track) => (track.artist ?? '') == name)
            .toList(growable: false),
        trackCountHint: trackCount,
        durationHint: durationMs,
      );
    });
    if (autoplay) await _startQueue(tracks, null);
  }

  /// 拉到的曲目到了就整队列起播（`startId` 给了就定位到那首）
  Future<void> _startQueue(
    Future<List<MusicTrack>> tracks,
    String? startId, {
    MusicTrack? fallback,
  }) async {
    try {
      final items = await tracks;
      if (!_canSetState) return;
      if (items.isEmpty) {
        if (fallback != null) {
          MusicPlaybackService.instance.playQueue(<MusicTrack>[fallback], 0);
        }
        return;
      }
      final index = startId == null
          ? 0
          : items.indexWhere((track) => track.id == startId);
      MusicPlaybackService.instance.playQueue(items, index < 0 ? 0 : index);
    } catch (_) {
      if (!_canSetState || fallback == null) return;
      MusicPlaybackService.instance.playQueue(<MusicTrack>[fallback], 0);
    }
  }

  // ---------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    final video = _videoDetail;
    if (video != null) {
      // 用电影 tab 同一个详情页：大图 + 简介 + **默认聚焦的播放按钮**，
      // 进页面按一下 OK 就直接播（搜索页自带的精简版没有这个焦点）。
      return TvMovieDetailPage(
        key: ValueKey<String>('search-movie-${video.id}'),
        movie: video,
        all: _videos,
        collections: const <TvMovieCollection>[],
        percent: 0,
        preparing: _preparing,
        onPlay: () => _play(video),
        onSelectMovie: (next) => setState(() => _videoDetail = next),
      );
    }
    final series = _seriesDetail;
    if (series != null) {
      return TvSeriesDetailPage(
        key: ValueKey<String>('search-series-${series.name}'),
        card: series,
        libraryId: _seriesLibraryId,
        roots: const <String>[],
        progressById: const <String, VideoProgressItem>{},
        onPlay: _play,
      );
    }
    final music = _musicDetail;
    if (music != null) {
      return TvMusicDetailPage(
        key: ValueKey<String>('search-music-${music.kind.name}-${music.title}'),
        spec: music,
        onOpenArtist: (artist) => _openArtistByName(artist, autoplay: false),
      );
    }

    final m = TvMetricsScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searchDisplay(m),
        SizedBox(height: m.px(14)),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 左 ~35% 键盘 / 右 ~65% 栏目
              Expanded(flex: 35, child: _keyboard(m)),
              SizedBox(width: m.px(18)),
              Expanded(flex: 65, child: _results(m)),
            ],
          ),
        ),
      ],
    );
  }

  /// 顶部搜索框：只负责回显（输入来自屏上键盘），带一个块状光标
  Widget _searchDisplay(TvMetrics m) {
    final scheme = Theme.of(context).colorScheme;
    final text = _query.text;
    return Container(
      height: m.px(58),
      padding: EdgeInsets.symmetric(horizontal: m.px(20)),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(m.px(12)),
        border: Border.all(
          color: text.isEmpty
              ? scheme.outlineVariant
              : scheme.primary.withValues(alpha: 0.7),
          width: text.isEmpty ? 1 : 2,
        ),
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: m.px(22), color: scheme.onSurfaceVariant),
          SizedBox(width: m.px(12)),
          Expanded(
            child: Text(
              text.isEmpty ? tr('tv.search.hint') : text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.px(22),
                fontWeight: text.isEmpty ? FontWeight.w400 : FontWeight.w700,
                color: text.isEmpty ? scheme.onSurfaceVariant : scheme.onSurface,
                letterSpacing: 1.5,
              ),
            ),
          ),
          if (_loading)
            SizedBox(
              width: m.px(18),
              height: m.px(18),
              child: const CircularProgressIndicator(strokeWidth: 2),
            ),
        ],
      ),
    );
  }

  Widget _keyboard(TvMetrics m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var r = 0; r < _rowChars.length; r += 1)
          Padding(
            padding: EdgeInsets.only(bottom: m.px(10)),
            child: Row(
              children: [
                for (var c = 0; c < _rowChars[r].length; c += 1)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: m.px(4)),
                      child: TvSearchKey(
                        label: _rowChars[r][c],
                        focusNode: _keys[r][c],
                        height: m.px(58),
                        fontSize: m.px(24),
                        onTap: () => _append(_rowChars[r][c]),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        SizedBox(height: m.px(6)),
        Row(
          children: [
            Expanded(
              child: TvSearchKey(
                label: tr('tv.search.clear'),
                focusNode: _clearKey,
                height: m.px(50),
                fontSize: m.px(18),
                onTap: () {
                  _query.clear();
                  _onQueryChanged();
                },
              ),
            ),
            SizedBox(width: m.px(10)),
            Expanded(
              child: TvSearchKey(
                label: tr('tv.search.backspace'),
                focusNode: _backspaceKey,
                height: m.px(50),
                fontSize: m.px(18),
                onTap: _backspace,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _results(TvMetrics m) {
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _search);
    }
    if (_submitted.isEmpty) return _defaultSections(m);

    final sections = _resultSections(m);
    if (sections.isEmpty) {
      return Center(
        child: Text(
          _loading ? tr('common.loading') : tr('tv.search.noResult', {'q': _submitted}),
          style: TextStyle(fontSize: m.px(18), color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.only(bottom: m.px(24)),
      children: sections,
    );
  }

  /// 未输入时的默认栏目：最近添加（电影 / 电视剧）+ 历史记录
  Widget _defaultSections(TvMetrics m) {
    final sections = <Widget>[
      ..._recentSections(m),
      if (_history.isNotEmpty)
        _keywordSection(m, tr('tv.search.history'), _history),
    ];
    if (sections.isEmpty) {
      return Center(
        child: Text(
          tr('tv.search.empty'),
          style: TextStyle(fontSize: m.px(18), color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.only(bottom: m.px(24)),
      children: sections,
    );
  }

  /// 「最近添加」两行：电影一行、电视剧一行（整部剧只出一张卡）。
  List<Widget> _recentSections(TvMetrics m) {
    final title = tr('video.home.recentAdd');
    return <Widget>[
      if (_recentMovies.isNotEmpty)
        TvSearchRow(
          title: '$title · ${tr('tv.search.group.movie')}',
          count: _recentMovies.length,
          itemBuilder: (i) {
            final item = _recentMovies[i];
            return TvSearchCard(
              title: item.title,
              subtitle: (item.year ?? 0) > 0 ? '${item.year}' : '',
              coverUrl: videoPosterUrl(item, size: 360),
              headers: videoArtHeaders,
              focusNode: _cards['recentMovie']?[i],
              onTap: () => _openVideo(item),
            );
          },
        ),
      if (_recentSeries.isNotEmpty)
        TvSearchRow(
          title: '$title · ${tr('tv.search.group.tv')}',
          count: _recentSeries.length,
          itemBuilder: (i) {
            final card = _recentSeries[i];
            return TvSearchCard(
              title: SeriesDisplayStore.nameOf(card.name) ?? card.name,
              subtitle: card.episodes > 0 ? '${card.episodes} 集' : '',
              coverUrls: _seriesCoverList(card),
              focusNode: _cards['recentTv']?[i],
              onTap: () => _openSeries(card),
            );
          },
        ),
    ];
  }

  Widget _keywordSection(TvMetrics m, String title, List<String> keywords) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvSectionHeader(title: title),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: m.px(10), vertical: m.px(6)),
          child: Wrap(
            spacing: m.px(10),
            runSpacing: m.px(10),
            children: [
              for (final keyword in keywords)
                TvFocusCard(
                  radius: m.px(10),
                  onTap: () {
                    _query.text = keyword;
                    _query.selection = TextSelection.collapsed(offset: keyword.length);
                    _onQueryChanged();
                  },
                  child: Container(
                    padding: EdgeInsets.symmetric(horizontal: m.px(18), vertical: m.px(10)),
                    child: Text(
                      keyword,
                      style: TextStyle(fontSize: m.px(18), fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 栏目顺序：电影 → 电视剧 → 歌曲 → 专辑 → 歌手（空栏目不渲染）
  List<Widget> _resultSections(TvMetrics m) {
    final sections = <Widget>[];

    void add(String key, String title, int count, Widget Function(int) card) {
      if (count <= 0) return;
      final shown = count > _sectionMax ? _sectionMax : count;
      sections.add(
        TvSearchRow(title: title, count: shown, itemBuilder: card),
      );
    }

    add('movie', tr('tv.search.group.movie'), _videos.length, (i) {
      final item = _videos[i];
      return TvSearchCard(
        title: item.title,
        subtitle: (item.year ?? 0) > 0 ? '${item.year}' : '',
        coverUrl: videoPosterUrl(item, size: 360),
        headers: videoArtHeaders,
        focusNode: _cards['movie']?[i],
        // 电影：进单片详情页（封面 + 简介 + 播放）
        onTap: () => _openVideo(item),
      );
    });
    add('tv', tr('tv.search.group.tv'), _series.length, (i) {
      final card = _series[i];
      return TvSearchCard(
        title: SeriesDisplayStore.nameOf(card.name) ?? card.name,
        subtitle: card.episodes > 0 ? '${card.episodes} 集' : '',
        coverUrls: _seriesCoverList(card),
        focusNode: _cards['tv']?[i],
        onTap: () => _openSeries(card),
      );
    });
    add('track', tr('tv.search.group.track'), _tracks.length, (i) {
      final track = _tracks[i];
      return TvSearchCard(
        title: track.title,
        subtitle: track.artist ?? '',
        coverUrl: musicCoverUrlForTv(track.id),
        focusNode: _cards['track']?[i],
        onTap: () => _openTrack(track),
      );
    });
    add('album', tr('tv.search.group.album'), _albums.length, (i) {
      final album = _albums[i];
      return TvSearchCard(
        title: album.name,
        subtitle: album.artist ?? '',
        coverUrl: album.coverTrackId == null ? null : musicCoverUrlForTv(album.coverTrackId!),
        focusNode: _cards['album']?[i],
        onTap: () => _openAlbum(album),
      );
    });
    add('artist', tr('tv.search.group.artist'), _artists.length, (i) {
      final artist = _artists[i];
      return TvSearchCard(
        title: artist.name,
        subtitle: '${artist.albums} ${tr('tv.search.group.album')}',
        coverUrl: artist.coverTrackId == null ? null : musicCoverUrlForTv(artist.coverTrackId!),
        circular: true,
        focusNode: _cards['artist']?[i],
        onTap: () => _openArtist(artist),
      );
    });
    return sections;
  }

  String? musicCoverUrlForTv(String id) => ApiSession.instance.coverUrl('music', id);
}

/// 从标题里去掉集数后缀，拿它当剧名。
///
/// 有些库的剧集条目没有 `series` 字段，只有「第 12 集」这种标题；
/// 按标题聚合才不至于把同一��剧拆成 24 个栏目。
// ⛔ 不做「光秃秃的数字」那一条：电影《2012》会被砍成「20」。
// 纯数字只认带分隔符的写法（「剧名 - 03」）。
final RegExp _episodeSuffix = RegExp(
  r'\s*(?:[-–—]\s*)?(?:第\s*\d+\s*[集话話]|EP?\s*\d+|S\d+\s*E\d+|[-–—]\s*\d{1,3})\s*$',
  caseSensitive: false,
);

String seriesKeyOfTitle(String title) {
  final text = title.trim();
  final stripped = text.replaceFirst(_episodeSuffix, '').trim();
  return stripped.isEmpty ? text : stripped;
}

/// 一个栏目：标题 + 一行卡片（最多 5 张，不横向滚动）
class TvSearchRow extends StatelessWidget {
  const TvSearchRow({
    super.key,
    required this.title,
    required this.count,
    required this.itemBuilder,
  });

  final String title;
  final int count;
  final Widget Function(int index) itemBuilder;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvSectionHeader(title: title),
        SizedBox(
          // 海报 2:3（宽 150 → 高 210）+ 标题两行 + 副标题一行，留 20 余量
          height: m.px(300),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // 卡片数已限到 5 张，一次放得下：关掉滚动，避免焦点跟着跑出屏幕
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: m.px(8), vertical: m.px(6)),
            itemCount: count,
            separatorBuilder: (_, _) => SizedBox(width: m.px(12)),
            // 卡片内部已经把节点交给 TvFocusCard，这里再包 Focus 会重复占用同一节点
            itemBuilder: (context, i) => itemBuilder(i),
          ),
        ),
      ],
    );
  }
}

/// 结果卡片：封面 + 标题 + 副标题
class TvSearchCard extends StatelessWidget {
  const TvSearchCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.coverUrl,
    this.coverUrls,
    this.headers = const <String, String>{},
    this.circular = false,
    this.focusNode,
  });

  final String title;
  final String subtitle;
  final String? coverUrl;

  /// 多级兜底封面（影视剧用）：逐个尝试，最后落到名称渐变占位。
  /// 单级 `coverUrl` 一张 404 就整块空白，剧卡的封面地址本来就有好几级。
  final List<String?>? coverUrls;

  final VoidCallback onTap;
  final Map<String, String> headers;
  final bool circular;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final width = m.px(150);
    // 竖版海报 3:2，但别到 1.5 —— 加上两行文字会超出栏目的固定高度
    final height = circular ? width : width * 1.4;
    // 整张卡（封面 + 文字）都要能点：只把封面做成焦点卡时，点标题一行完全没反应，
    // 用户会以为「搜索结果点了不管用」。
    return SizedBox(
      width: width,
      child: TvFocusCard(
        focusNode: focusNode,
        onTap: onTap,
        radius: m.px(14),
        focusScale: 1.05,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: width,
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(circular ? width : m.px(14)),
                child: coverUrls != null && coverUrls!.isNotEmpty
                    ? TvMediaCover(
                        urls: coverUrls!,
                        fallbackText: title,
                        cacheWidth: (width * 2).round(),
                      )
                    : coverUrl == null || coverUrl!.isEmpty
                    ? Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        child: Icon(
                          Icons.music_note,
                          size: m.px(40),
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      )
                    : NasCoverImage(
                        url: coverUrl!,
                        fit: BoxFit.cover,
                        headers: headers,
                        fallbackText: title,
                        cacheWidth: (width * 2).round(),
                        borderRadius: 0,
                      ),
              ),
            ),
            SizedBox(height: m.px(10)),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: m.px(16), fontWeight: FontWeight.w600),
            ),
            if (subtitle.isNotEmpty)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: m.px(14),
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 屏上键盘的一个键：聚焦时描边 + 放大（TvFocusCard 自带焦点描边与缩放）
class TvSearchKey extends StatelessWidget {
  const TvSearchKey({
    super.key,
    required this.label,
    required this.focusNode,
    required this.height,
    required this.fontSize,
    required this.onTap,
  });

  final String label;
  final FocusNode focusNode;
  final double height;
  final double fontSize;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    return TvFocusCard(
      focusNode: focusNode,
      onTap: onTap,
      focusScale: 1.07,
      radius: m.px(10),
      child: Container(
        height: height,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(m.px(10)),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }
}
