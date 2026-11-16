import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../video/video_card.dart';
import '../../video/video_genre_labels.dart';
import '../../video/video_series_widgets.dart';
import '../tv_focus.dart';
import '../tv_media_cover.dart';
import 'tv_movie_models.dart';
import 'tv_movie_widgets.dart';

/// 电影库首页：顶部沉浸式剧照墙 + 继续观看 / 最近添加 / 系列电影泳道 +
/// A-Z 分组网格与右侧字母索引条。
///
/// 全库影片不再一屏平铺：只有「全部影片」按首字母分组，右侧索引条可
/// 直接用方向键进入、确认键跳到对应分组；索引条始终可见但不抢默认焦点。
class TvMovieHome extends StatefulWidget {
  const TvMovieHome({
    super.key,
    required this.continueItems,
    required this.recent,
    required this.collections,
    required this.entries,
    required this.onOpenMovie,
    required this.onOpenCollection,
    required this.onPlayContinue,
    this.firstFocusNode,
    this.progressOf,
  });

  final List<TvMovieContinue> continueItems;
  final List<VideoItem> recent;
  final List<TvMovieCollection> collections;

  /// 全库条目（单片或合集），已按分组键排好序。
  final List<TvMovieEntry> entries;

  final void Function(VideoItem item) onOpenMovie;
  final void Function(TvMovieCollection collection) onOpenCollection;
  final void Function(VideoItem item) onPlayContinue;
  final FocusNode? firstFocusNode;
  final int Function(String id)? progressOf;

  @override
  State<TvMovieHome> createState() => _TvMovieHomeState();
}

class _TvMovieHomeState extends State<TvMovieHome> {
  static const String _continueLane = 'continue';
  static const String _recentLane = 'recent';
  static const String _collectionLane = 'collections';

  final Map<String, FocusNode> _nodes = <String, FocusNode>{};
  final Map<String, int> _lastLaneIndex = <String, int>{};
  final Map<String, GlobalKey> _groupKeys = <String, GlobalKey>{};
  final FocusNode _ownedFirst = FocusNode(debugLabel: 'tv-movie-first');

  /// 背景剧照与 Hero 文案共用的当前影片（焦点变化只重建这两块）。
  final ValueNotifier<VideoItem?> _hero = ValueNotifier<VideoItem?>(null);

  Map<String, List<TvMovieEntry>> _groups = const <String, List<TvMovieEntry>>{};
  List<({String id, int count})> _lanes = const <({String id, int count})>[];
  String? _focusLane;
  String? _lastEntryId;

  FocusNode get _firstFocus => widget.firstFocusNode ?? _ownedFirst;

  /// 「最近添加」始终单独成行：小库（十几部）里它和全库数量相同，
  /// 但泳道结构本身是电影首页的信息层级，不能因为数量相等就消失。
  bool get _showRecent => widget.recent.length > 1;

  String? get _firstKey {
    if (widget.continueItems.isNotEmpty) return '$_continueLane:0';
    if (_showRecent) return '$_recentLane:0';
    if (widget.collections.isNotEmpty) return '$_collectionLane:0';
    if (widget.entries.isNotEmpty) return _gridKey(widget.entries.first);
    return null;
  }

  String _gridKey(TvMovieEntry entry) {
    final id = entry.movie?.id ?? entry.collection?.id ?? entry.name;
    return 'grid:$id';
  }

  FocusNode _node(String key) {
    if (key == _firstKey) return _firstFocus;
    return _nodes.putIfAbsent(key, () => FocusNode(debugLabel: 'tv-movie-$key'));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _hero.value ??= _initialHero();
  }

  VideoItem? _initialHero() {
    if (widget.continueItems.isNotEmpty) return widget.continueItems.first.item;
    if (widget.recent.isNotEmpty) return widget.recent.first;
    if (widget.collections.isNotEmpty) return widget.collections.first.firstMovie;
    if (widget.entries.isNotEmpty) return widget.entries.first.heroMovie;
    return null;
  }

  @override
  void dispose() {
    for (final entry in _nodes.entries) {
      if (identical(entry.value, widget.firstFocusNode)) continue;
      entry.value.dispose();
    }
    _ownedFirst.dispose();
    _hero.dispose();
    super.dispose();
  }

  void _setHero(VideoItem? item) {
    if (item == null) return;
    if (identical(_hero.value, item)) return;
    _hero.value = item;
  }

  void _rememberLane(String lane, int index, VideoItem? item) {
    _focusLane = lane;
    _lastLaneIndex[lane] = index;
    _setHero(item);
  }

  void _rememberEntry(TvMovieEntry entry) {
    _focusLane = null;
    _lastEntryId = entry.movie?.id ?? entry.collection?.id;
    _setHero(entry.heroMovie);
  }

  void _rememberRail(String letter) {
    _focusLane = null;
    _scrollToGroup(letter);
  }

  void _ensureVisible(FocusNode node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = node.context;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _scrollToGroup(String letter) {
    final key = _groupKeys.putIfAbsent(letter, () => GlobalKey());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = key.currentContext;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.08,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _jumpToGroup(String letter) {
    final list = _groups[letter];
    if (list == null || list.isEmpty) return;
    final node = _node(_gridKey(list.first));
    node.requestFocus();
    _ensureVisible(node);
  }

  TvMovieEntry? get _firstGridEntry {
    final id = _lastEntryId;
    if (id != null) {
      for (final entry in widget.entries) {
        if ((entry.movie?.id ?? entry.collection?.id) == id) return entry;
      }
    }
    return widget.entries.isEmpty ? null : widget.entries.first;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final up = key == LogicalKeyboardKey.arrowUp;
    final down = key == LogicalKeyboardKey.arrowDown;
    if (!up && !down) return KeyEventResult.ignored;
    final lane = _focusLane;
    if (lane == null) return KeyEventResult.ignored;
    final index = _lanes.indexWhere((item) => item.id == lane);
    if (index < 0) return KeyEventResult.ignored;

    // 最后一条泳道 ↓：落进「全部影片」网格里上次停留的卡片。
    if (down && index == _lanes.length - 1) {
      final entry = _firstGridEntry;
      if (entry == null) return KeyEventResult.ignored;
      final target = _node(_gridKey(entry));
      target.requestFocus();
      _ensureVisible(target);
      return KeyEventResult.handled;
    }

    final targetIndex = index + (down ? 1 : -1);
    // 第一条泳道 ↑ 交给外壳（内容区首行 ↑ → 顶部 tab）。
    if (targetIndex < 0 || targetIndex >= _lanes.length) {
      return KeyEventResult.ignored;
    }
    final target = _lanes[targetIndex];
    if (target.count <= 0) return KeyEventResult.ignored;
    final targetNode = _node(
      '${target.id}:${(_lastLaneIndex[target.id] ?? 0).clamp(0, target.count - 1)}',
    );
    targetNode.requestFocus();
    _ensureVisible(targetNode);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final showContinue = widget.continueItems.isNotEmpty;
    final showRecent = _showRecent;
    final showCollections = widget.collections.isNotEmpty;
    final showGrid = widget.entries.isNotEmpty;

    _lanes = <({String id, int count})>[
      if (showContinue)
        (id: _continueLane, count: widget.continueItems.length),
      if (showRecent) (id: _recentLane, count: widget.recent.length),
      if (showCollections)
        (id: _collectionLane, count: widget.collections.length),
    ];

    final groups = <String, List<TvMovieEntry>>{};
    for (final entry in widget.entries) {
      groups.putIfAbsent(entry.letter, () => <TvMovieEntry>[]).add(entry);
    }
    _groups = groups;
    final letters = groups.keys.toList()
      ..sort((a, b) {
        if (a == '#') return 1;
        if (b == '#') return -1;
        return a.compareTo(b);
      });

    if (_lanes.isEmpty && !showGrid) {
      return NasEmptyState(
        title: tr('video.home.empty'),
        message: tr('video.home.emptyHint'),
        icon: Icons.movie_outlined,
      );
    }

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned.fill(child: _buildBackdrop()),
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.only(
                top: m.px(6),
                right: m.px(42),
                bottom: m.px(28),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildHeroBlock(m),
                  if (showContinue) ...[
                    TvCardRow(
                      title: tr('video.home.continue'),
                      children: [
                        for (var i = 0; i < widget.continueItems.length; i += 1)
                          TvMovieContinueCard(
                            entry: widget.continueItems[i],
                            focusNode: _node('$_continueLane:$i'),
                            onFocused: () => _rememberLane(
                              _continueLane,
                              i,
                              widget.continueItems[i].item,
                            ),
                            onTap: () => widget.onPlayContinue(
                              widget.continueItems[i].item,
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: m.px(22)),
                  ],
                  if (showRecent) ...[
                    TvCardRow(
                      title: tr('video.home.recentAdd'),
                      children: [
                        for (var i = 0; i < widget.recent.length; i += 1)
                          TvMoviePosterCard(
                            item: widget.recent[i],
                            focusNode: _node('$_recentLane:$i'),
                            percent:
                                widget.progressOf?.call(widget.recent[i].id) ??
                                0,
                            onFocused: () => _rememberLane(
                              _recentLane,
                              i,
                              widget.recent[i],
                            ),
                            onTap: () =>
                                widget.onOpenMovie(widget.recent[i]),
                          ),
                      ],
                    ),
                    SizedBox(height: m.px(22)),
                  ],
                  if (showCollections) ...[
                    TvCardRow(
                      title: tr('tv.movie.collections'),
                      children: [
                        for (var i = 0; i < widget.collections.length; i += 1)
                          TvMovieCollectionCard(
                            collection: widget.collections[i],
                            focusNode: _node('$_collectionLane:$i'),
                            onFocused: () => _rememberLane(
                              _collectionLane,
                              i,
                              widget.collections[i].firstMovie,
                            ),
                            onTap: () => widget.onOpenCollection(
                              widget.collections[i],
                            ),
                          ),
                      ],
                    ),
                    SizedBox(height: m.px(22)),
                  ],
                  if (showGrid) _buildGrid(m, letters),
                ],
              ),
            ),
          ),
          if (showGrid && letters.length > 1)
            Positioned(right: m.px(2), top: 0, bottom: 0, child: _buildRail(m, letters)),
        ],
      ),
    );
  }

  /// 沉浸式剧照墙：整页背景随当前焦点影片切换（淡入淡出），
  /// 再压两层深色渐变保证泳道文字可读。
  Widget _buildBackdrop() {
    return ValueListenableBuilder<VideoItem?>(
      valueListenable: _hero,
      builder: (context, item, _) {
        return Stack(
          fit: StackFit.expand,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 420),
              child: item == null
                  ? const SizedBox.expand(key: ValueKey<String>('empty'))
                  : SizedBox.expand(
                      key: ValueKey<String>(item.id),
                      child: TvMediaCover(
                        urls: <String?>[
                          videoPosterUrl(item, kind: 'fanart', size: 1600),
                          videoPosterUrl(item, size: 800),
                          episodeStillFallbackUrl(item.id),
                        ],
                        fallbackText: item.title,
                        icon: Icons.movie_outlined,
                        cacheWidth: 1600,
                      ),
                    ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.centerLeft,
                  end: Alignment.centerRight,
                  colors: [
                    Colors.black.withValues(alpha: 0.90),
                    Colors.black.withValues(alpha: 0.62),
                    Colors.black.withValues(alpha: 0.34),
                  ],
                  stops: const [0, 0.55, 1],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.55),
                    Colors.black.withValues(alpha: 0.35),
                    Colors.black.withValues(alpha: 0.88),
                  ],
                  stops: const [0, 0.4, 1],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeroBlock(TvMetrics m) {
    return SizedBox(
      height: m.px(230),
      child: ValueListenableBuilder<VideoItem?>(
        valueListenable: _hero,
        builder: (context, item, _) {
          if (item == null) return const SizedBox.shrink();
          final meta = <String>[
            if ((item.year ?? 0) > 0) '${item.year}',
            if ((item.runtimeMin ?? 0) > 0)
              tr('video.detail.minutes', {'count': '${item.runtimeMin}'}),
            if ((item.score ?? 0) > 0) item.score!.toStringAsFixed(1),
            if (item.genres.isNotEmpty) genreLabel(item.genres.first),
          ].join(' · ');
          return Padding(
            padding: EdgeInsets.fromLTRB(
              m.px(10),
              m.px(18),
              m.px(30),
              m.px(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                Text(
                  item.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: m.px(40),
                    height: 1.08,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: m.px(8)),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: m.px(16),
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.82),
                  ),
                ),
                if ((item.overview ?? '').trim().isNotEmpty) ...[
                  SizedBox(height: m.px(8)),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: m.px(880)),
                    child: Text(
                      item.overview!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: m.px(14),
                        height: 1.45,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildGrid(TvMetrics m, List<String> letters) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TvSectionHeader(
          title: tr('tv.movie.all'),
          trailing: Text(
            tr('tv.movie.count', {'n': '${widget.entries.length}'}),
            style: TextStyle(
              fontSize: m.px(14),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        for (final letter in letters) ...[
          Padding(
            key: _groupKeys.putIfAbsent(letter, () => GlobalKey()),
            padding: EdgeInsets.fromLTRB(
              m.px(10),
              m.px(4),
              m.px(8),
              m.px(10),
            ),
            child: Row(
              children: [
                Text(
                  letter,
                  style: TextStyle(
                    fontSize: m.px(20),
                    fontWeight: FontWeight.w900,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                SizedBox(width: m.px(10)),
                Expanded(
                  child: Container(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.12),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.only(left: m.px(8), bottom: m.px(12)),
            child: Wrap(
              spacing: m.px(20),
              runSpacing: m.px(20),
              children: [
                for (final entry in _groups[letter] ?? const <TvMovieEntry>[])
                  _buildEntryCard(entry),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildEntryCard(TvMovieEntry entry) {
    final movie = entry.movie;
    void onFocused() => _rememberEntry(entry);
    if (movie != null) {
      return TvMoviePosterCard(
        item: movie,
        focusNode: _node(_gridKey(entry)),
        percent: widget.progressOf?.call(movie.id) ?? 0,
        onFocused: onFocused,
        onTap: () => widget.onOpenMovie(movie),
      );
    }
    final collection = entry.collection!;
    return TvMovieCollectionCard(
      collection: collection,
      focusNode: _node(_gridKey(entry)),
      onFocused: onFocused,
      onTap: () => widget.onOpenCollection(collection),
    );
  }

  Widget _buildRail(TvMetrics m, List<String> letters) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: m.px(30),
      padding: EdgeInsets.symmetric(vertical: m.px(6)),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(m.px(15)),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final slot = constraints.maxHeight / letters.length;
          return Column(
            children: [
              for (final letter in letters)
                SizedBox(
                  height: slot,
                  width: double.infinity,
                  child: Center(
                    child: TvFocusCard(
                      focusNode: _node('rail:$letter'),
                      onFocused: () => _rememberRail(letter),
                      onTap: () => _jumpToGroup(letter),
                      radius: m.px(6),
                      focusScale: 1,
                      child: Container(
                        width: m.px(24),
                        height: slot,
                        alignment: Alignment.center,
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            letter,
                            style: TextStyle(
                              fontSize: m.px(12),
                              fontWeight: FontWeight.w800,
                              color: scheme.onSurface.withValues(alpha: 0.78),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
