import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import '../music/music_playback.dart';
import '../video/video_card.dart';
import '../video/video_series_widgets.dart' show seriesArtUrl;
import 'tv_focus.dart';
import 'tv_video_section.dart';
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

  String? _lastSection;
  int _lastIndex = 0;

  Timer? _debounce;
  int _searchSeq = 0;

  bool _loading = false;
  String? _error;
  String _submitted = '';

  List<TvSeriesCard> _series = const <TvSeriesCard>[];
  List<VideoItem> _videos = const <VideoItem>[];
  List<MusicTrack> _tracks = const <MusicTrack>[];
  List<MusicAlbum> _albums = const <MusicAlbum>[];
  List<MusicArtist> _artists = const <MusicArtist>[];

  List<String> _history = const <String>[];
  List<String> _hot = const <String>[];

  VideoItem? _videoDetail;
  TvSeriesCard? _seriesDetail;
  String _seriesLibraryId = '';
  bool _preparing = false;

  @override
  void initState() {
    super.initState();
    // 键盘节点在 initState 建好：外壳可能一进来就 focus `firstFocusNode`，
    // 那个节点要真的挂在某个键上才有效。
    for (var r = 0; r < _rowChars.length; r += 1) {
      final row = <FocusNode>[];
      for (var c = 0; c < _rowChars[r].length; c += 1) {
        if (r == 0 && c == 0 && widget.firstFocusNode != null) {
          row.add(widget.firstFocusNode!);
        } else {
          final node = FocusNode(debugLabel: 'tv-key-$r-$c');
          _ownedNodes.add(node);
          row.add(node);
        }
      }
      _keys.add(row);
    }
    widget.back.handler = _onBackPressed;
    widget.back.overlay = _hasOverlay;
    _query.addListener(_onQueryChanged);
    _loadHistory();
    _loadHot();
  }

  @override
  void dispose() {
    if (widget.back.handler == _onBackPressed) {
      widget.back.handler = null;
      widget.back.overlay = null;
    }
    _debounce?.cancel();
    _query.removeListener(_onQueryChanged);
    _query.dispose();
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
    super.dispose();
  }

  bool _onBackPressed() => _handleBack();

  bool _hasOverlay() => _videoDetail != null || _seriesDetail != null;

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
    // 右侧有焦点 → 先收回键盘（设计：返回分两级，一次返回直接退出容易误触丢输入）
    if (_resultsFocused) {
      _focusKeyboard();
      return true;
    }
    return false;
  }

  void _restoreFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusKeyboard();
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
    _debounce = Timer(const Duration(milliseconds: 300), _search);
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
    if (!mounted) return;
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

  /// 热门搜索：库里的影视标题 + 最近听过的艺人。
  /// 真「全站热度」要额外的统计接口，为搜索页加一个不值当。
  Future<void> _loadHot() async {
    final client = ApiSession.instance.client;
    final out = <String>[];
    try {
      final res = await client.videoList(limit: 16);
      for (final item in res.items) {
        final series = (item.series ?? '').trim();
        final name = series.isNotEmpty ? series : item.title.trim();
        if (name.isNotEmpty && !out.contains(name)) out.add(name);
        if (out.length >= 8) break;
      }
    } catch (_) {
      // 影视取不到就只显示音乐侧
    }
    if (out.length < 10) {
      try {
        final hist = await client.musicHistory(limit: 20);
        for (final track in hist.items) {
          final name = (track.artist ?? '').trim();
          if (name.isNotEmpty && !out.contains(name)) out.add(name);
          if (out.length >= 10) break;
        }
      } catch (_) {
        // 忽略
      }
    }
    if (mounted) setState(() => _hot = out);
  }

  // ---------------------------------------------------------------- 搜索

  Future<void> _search() async {
    final q = _query.text.trim();
    final seq = ++_searchSeq;
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
    final results = await Future.wait<Object?>([
      _safe(client.videoList(q: q, limit: 100)),
      _safe(client.videoSeriesList(q: q, limit: 20)),
      _safe(client.musicList(q: q, limit: 40)),
      _safe(client.musicAlbums(q: q, limit: 20)),
      _safe(client.musicArtists(q: q, limit: 20)),
    ]);
    // 输入还在继续：这一批结果已经过期，直接丢掉（防抖后仍可能连发）
    if (!mounted || seq != _searchSeq) return;

    final videoRes = results[0] as VideoListResponse?;
    final seriesRes = results[1] as VideoSeriesListResponse?;
    final trackRes = results[2] as MusicListResponse?;
    final albumRes = results[3] as MusicAlbumListResponse?;
    final artistRes = results[4] as MusicArtistListResponse?;

    final videos = <VideoItem>[];
    final bySeries = <String, List<VideoItem>>{};
    for (final item in videoRes?.items ?? const <VideoItem>[]) {
      final name = (item.series ?? '').trim();
      if (name.isEmpty) {
        videos.add(item);
      } else {
        bySeries.putIfAbsent(name, () => <VideoItem>[]).add(item);
      }
    }
    final series = <TvSeriesCard>[
      for (final entry in bySeries.entries)
        _seriesCardFrom(name: entry.key, items: entry.value),
    ];
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
  List<String> get _visibleKeys => <String>[
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
    return KeyEventResult.ignored;
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
    return KeyEventResult.ignored;
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
    return KeyEventResult.ignored;
  }

  /// 结果变了就重建卡片节点，并在帧后把焦点校准到仍然存在的卡片上
  /// （否则输入一个字母让结果变少，焦点会掉回根节点，遥控器得从头按起）。
  void _rebuildCards() {
    final previous = _lastSection;
    final previousIndex = _lastIndex;
    for (final list in _cards.values) {
      for (final node in list) {
        node.dispose();
      }
    }
    _cards.clear();
    void build(String key, int count) {
      if (count <= 0) return;
      _cards[key] = List<FocusNode>.generate(
        count,
        (_) => FocusNode(debugLabel: 'tv-card-$key'),
      );
    }

    build('movie', _videos.length);
    build('tv', _series.length);
    build('track', _tracks.length);
    build('album', _albums.length);
    build('artist', _artists.length);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final keys = _visibleKeys;
      if (keys.isEmpty) return;
      final target = previous != null && keys.contains(previous) ? previous : keys.first;
      final nodes = _cards[target];
      if (nodes == null || nodes.isEmpty) return;
      final index = previousIndex.clamp(0, nodes.length - 1);
      _lastSection = target;
      _lastIndex = index;
      nodes[index].requestFocus();
    });
  }

  // ---------------------------------------------------------------- 打开

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
        NasSnack.show(context, tr('tv.search.noResult', {'q': card.name}));
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
      if (mounted) setState(() => _preparing = false);
    }
  }

  void _playTracks(List<MusicTrack> tracks, int index) {
    if (tracks.isEmpty) return;
    unawaited(_remember(_query.text));
    MusicPlaybackService.instance.playQueue(tracks, index);
  }

  Future<void> _playAlbum(MusicAlbum album) async {
    try {
      final res = await ApiSession.instance.client.musicList(
        album: album.name,
        limit: 200,
      );
      if (!mounted) return;
      if (res.items.isEmpty) {
        NasSnack.show(context, tr('tv.search.noResult', {'q': album.name}));
        return;
      }
      _playTracks(res.items, 0);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('tv.search.failed', {'error': '$e'}));
    }
  }

  Future<void> _playArtist(MusicArtist artist) async {
    try {
      final res = await ApiSession.instance.client.musicList(
        artist: artist.name,
        limit: 200,
      );
      if (!mounted) return;
      if (res.items.isEmpty) {
        NasSnack.show(context, tr('tv.search.noResult', {'q': artist.name}));
        return;
      }
      _playTracks(res.items, 0);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('tv.search.failed', {'error': '$e'}));
    }
  }

  // ---------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    final video = _videoDetail;
    if (video != null) {
      return TvVideoDetailView(
        item: video,
        preparing: _preparing,
        onPlay: () => _play(video),
        onBack: _handleBack,
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
                      child: _TvKey(
                        label: _rowChars[r][c],
                        focusNode: _keys[r][c],
                        height: m.px(58),
                        fontSize: m.px(24),
                        onTap: () => _append(_rowChars[r][c]),
                        onKey: (event) => _handleKey(event, r, c),
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
              child: _TvKey(
                label: tr('tv.search.clear'),
                focusNode: _clearKey,
                height: m.px(50),
                fontSize: m.px(18),
                onTap: () {
                  _query.clear();
                  _onQueryChanged();
                },
                onKey: (event) => _handleActionKey(event, left: true),
              ),
            ),
            SizedBox(width: m.px(10)),
            Expanded(
              child: _TvKey(
                label: tr('tv.search.backspace'),
                focusNode: _backspaceKey,
                height: m.px(50),
                fontSize: m.px(18),
                onTap: _backspace,
                onKey: (event) => _handleActionKey(event, left: false),
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

  /// 未输入时的默认栏目：热门搜索 + 历史记录
  Widget _defaultSections(TvMetrics m) {
    if (_hot.isEmpty && _history.isEmpty) {
      return Center(
        child: Text(
          tr('tv.search.empty'),
          style: TextStyle(fontSize: m.px(18), color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView(
      padding: EdgeInsets.only(bottom: m.px(24)),
      children: [
        if (_hot.isNotEmpty) _keywordSection(m, tr('tv.search.hot'), _hot),
        if (_history.isNotEmpty) _keywordSection(m, tr('tv.search.history'), _history),
      ],
    );
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
        _Section(
          title: title,
          count: shown,
          itemBuilder: card,
          focusNodes: _cards[key],
          onKey: _handleCardKey,
          sectionKey: key,
        ),
      );
    }

    add('movie', tr('tv.search.group.movie'), _videos.length, (i) {
      final item = _videos[i];
      return _TvResultCard(
        title: item.title,
        subtitle: (item.year ?? 0) > 0 ? '${item.year}' : '',
        coverUrl: videoPosterUrl(item, size: 360),
        headers: videoArtHeaders,
        focusNode: _cards['movie']?[i],
        onTap: () => setState(() => _videoDetail = item),
      );
    });
    add('tv', tr('tv.search.group.tv'), _series.length, (i) {
      final card = _series[i];
      return _TvResultCard(
        title: card.name,
        subtitle: card.episodes > 0 ? '${card.episodes} 集' : '',
        coverUrl: card.coverId == null ? null : seriesArtUrl(card.coverId!),
        focusNode: _cards['tv']?[i],
        onTap: () => _openSeries(card),
      );
    });
    add('track', tr('tv.search.group.track'), _tracks.length, (i) {
      final track = _tracks[i];
      return _TvResultCard(
        title: track.title,
        subtitle: track.artist ?? '',
        coverUrl: musicCoverUrlForTv(track.id),
        focusNode: _cards['track']?[i],
        onTap: () => _playTracks(_tracks, i),
      );
    });
    add('album', tr('tv.search.group.album'), _albums.length, (i) {
      final album = _albums[i];
      return _TvResultCard(
        title: album.name,
        subtitle: album.artist ?? '',
        coverUrl: album.coverTrackId == null ? null : musicCoverUrlForTv(album.coverTrackId!),
        focusNode: _cards['album']?[i],
        onTap: () => _playAlbum(album),
      );
    });
    add('artist', tr('tv.search.group.artist'), _artists.length, (i) {
      final artist = _artists[i];
      return _TvResultCard(
        title: artist.name,
        subtitle: '${artist.albums} ${tr('tv.search.group.album')}',
        coverUrl: artist.coverTrackId == null ? null : musicCoverUrlForTv(artist.coverTrackId!),
        circular: true,
        focusNode: _cards['artist']?[i],
        onTap: () => _playArtist(artist),
      );
    });
    return sections;
  }

  String? musicCoverUrlForTv(String id) => ApiSession.instance.coverUrl('music', id);
}

/// 一个栏目：标题 + 一行卡片（最多 5 张，不横向滚动）
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.count,
    required this.itemBuilder,
    required this.focusNodes,
    required this.onKey,
    required this.sectionKey,
  });

  final String title;
  final int count;
  final Widget Function(int index) itemBuilder;
  final List<FocusNode>? focusNodes;
  final KeyEventResult Function(String sectionKey, int index, KeyEvent event) onKey;
  final String sectionKey;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvSectionHeader(title: title),
        SizedBox(
          height: m.px(250),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // 卡片数已限到 5 张，一次放得下：关掉滚动，避免焦点跟着跑出屏幕
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.symmetric(horizontal: m.px(8), vertical: m.px(6)),
            itemCount: count,
            separatorBuilder: (_, _) => SizedBox(width: m.px(12)),
            itemBuilder: (context, i) {
              final card = itemBuilder(i);
              final node =
                  focusNodes != null && i < focusNodes!.length ? focusNodes![i] : null;
              if (node == null) return card;
              return Focus(
                focusNode: node,
                onKeyEvent: (n, event) => onKey(sectionKey, i, event),
                child: card,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 结果卡片：封面 + 标题 + 副标题
class _TvResultCard extends StatelessWidget {
  const _TvResultCard({
    required this.title,
    required this.subtitle,
    required this.coverUrl,
    required this.onTap,
    this.headers = const <String, String>{},
    this.circular = false,
    this.focusNode,
  });

  final String title;
  final String subtitle;
  final String? coverUrl;
  final VoidCallback onTap;
  final Map<String, String> headers;
  final bool circular;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final width = m.px(150);
    final height = circular ? width : width * 1.5;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            focusNode: focusNode,
            onTap: onTap,
            radius: m.px(14),
            focusScale: 1.05,
            child: SizedBox(
              width: width,
              height: height,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(circular ? width : m.px(14)),
                child: coverUrl == null
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
          ),
          SizedBox(height: m.px(10)),
          Text(
            title,
            maxLines: 2,
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
    );
  }
}

/// 屏上键盘的一个键：聚焦时描边 + 放大（TvFocusCard 自带焦点描边与缩放）
class _TvKey extends StatelessWidget {
  const _TvKey({
    required this.label,
    required this.focusNode,
    required this.height,
    required this.fontSize,
    required this.onTap,
    required this.onKey,
  });

  final String label;
  final FocusNode focusNode;
  final double height;
  final double fontSize;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent event) onKey;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    return Focus(
      focusNode: focusNode,
      onKeyEvent: (node, event) => onKey(event),
      child: TvFocusCard(
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
      ),
    );
  }
}
