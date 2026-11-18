import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../video/series_display.dart';
import '../../video/video_card.dart';
import '../../video/video_series_widgets.dart';
import '../tv_focus.dart';
import '../tv_media_cover.dart';
import 'tv_series_models.dart';

/// 剧集库首页：继续观看（16:9 + 进度）+ 最近更新 / 全部剧集（2:3 总封面）。
///
/// 顶级泳道只出现「剧」，单集只出现在「继续观看」里，不再把整库单集平铺。
class TvSeriesHome extends StatefulWidget {
  const TvSeriesHome({
    super.key,
    required this.continueItems,
    required this.recent,
    required this.all,
    required this.onOpenSeries,
    required this.onPlayContinue,
    this.firstFocusNode,
  });

  final List<TvContinueEntry> continueItems;
  final List<TvSeriesCard> recent;
  final List<TvSeriesCard> all;
  final void Function(TvSeriesCard card) onOpenSeries;
  final void Function(TvContinueEntry entry) onPlayContinue;
  final FocusNode? firstFocusNode;

  @override
  State<TvSeriesHome> createState() => _TvSeriesHomeState();
}

class _TvSeriesHomeState extends State<TvSeriesHome> {
  static const String _continueLane = 'continue';
  static const String _recentLane = 'recent';
  static const String _allLane = 'all';

  /// 「全部剧集」一行 6 列，往下排任意多行。
  static const int _columns = 6;

  final Map<String, FocusNode> _nodes = <String, FocusNode>{};
  final Map<String, int> _lastIndex = <String, int>{};
  final FocusNode _ownedFirst = FocusNode(debugLabel: 'tv-series-first');

  List<({String id, int count})> _lanes = const [];
  String? _focusedLane;

  /// 网格里上次停留的位置：从泳道 ↓ 落进网格时接着上次的卡片。
  int _lastGridIndex = 0;

  FocusNode get _firstFocus => widget.firstFocusNode ?? _ownedFirst;

  bool get _showRecent =>
      widget.recent.isNotEmpty && widget.all.length > widget.recent.length;

  @override
  void initState() {
    super.initState();
    _nodes['${_firstLaneId()}:0'] = _firstFocus;
  }

  String _firstLaneId() {
    if (widget.continueItems.isNotEmpty) return _continueLane;
    if (_showRecent) return _recentLane;
    return _allLane;
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      if (identical(node, widget.firstFocusNode)) continue;
      if (identical(node, _ownedFirst)) continue;
      node.dispose();
    }
    _ownedFirst.dispose();
    super.dispose();
  }

  FocusNode _node(String lane, int index) {
    final key = '$lane:$index';
    if (lane == _firstLaneId() && index == 0) return _firstFocus;
    return _nodes.putIfAbsent(
      key,
      () => FocusNode(debugLabel: 'tv-series-$key'),
    );
  }

  void _remember(String lane, int index) {
    final changed = _focusedLane != lane;
    _focusedLane = lane;
    _lastIndex[lane] = index;
    if (changed && mounted) setState(() {});
  }

  /// 网格卡片：`_focusedLane = null` 表示 ↑↓ 交给外壳的方向遍历，
  /// 网格内部按行按列自由移动，不再被「泳道切换」拦走。
  void _rememberGrid(int index) {
    _lastGridIndex = index;
    _focusedLane = null;
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

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final up = key == LogicalKeyboardKey.arrowUp;
    final down = key == LogicalKeyboardKey.arrowDown;
    if (!up && !down) return KeyEventResult.ignored;
    final current = _focusedLane;
    if (current == null) return KeyEventResult.ignored;
    final index = _lanes.indexWhere((lane) => lane.id == current);
    if (index < 0) return KeyEventResult.ignored;

    // 最后一条泳道 ↓：落进「全部剧集」网格里上次停留的卡片。
    if (down && index == _lanes.length - 1) {
      if (widget.all.isEmpty) return KeyEventResult.ignored;
      final target = _node(
        _allLane,
        _lastGridIndex.clamp(0, widget.all.length - 1),
      );
      target.requestFocus();
      _ensureVisible(target);
      return KeyEventResult.handled;
    }

    final targetIndex = index + (down ? 1 : -1);
    if (targetIndex < 0 || targetIndex >= _lanes.length) {
      return KeyEventResult.ignored;
    }
    final target = _lanes[targetIndex];
    if (target.count <= 0) return KeyEventResult.ignored;
    final targetNode = _node(
      target.id,
      (_lastIndex[target.id] ?? 0).clamp(0, target.count - 1),
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
    final showGrid = widget.all.isNotEmpty;
    _lanes = <({String id, int count})>[
      if (showContinue)
        (id: _continueLane, count: widget.continueItems.length),
      if (showRecent) (id: _recentLane, count: widget.recent.length),
    ];

    if (_lanes.isEmpty && !showGrid) {
      return NasEmptyState(
        title: tr('video.home.empty'),
        message: tr('video.home.emptyHint'),
        icon: Icons.video_library_outlined,
      );
    }

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(top: m.px(6), bottom: m.px(28)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (showContinue) ...[
              TvCardRow(
                title: tr('video.home.continue'),
                children: [
                  for (var i = 0; i < widget.continueItems.length; i += 1)
                    _TvContinueCard(
                      entry: widget.continueItems[i],
                      focusNode: _node(_continueLane, i),
                      onFocused: () => _remember(_continueLane, i),
                      onTap: () =>
                          widget.onPlayContinue(widget.continueItems[i]),
                    ),
                ],
              ),
              SizedBox(height: m.px(22)),
            ],
            if (showRecent) ...[
              TvCardRow(
                title: tr('video.series.sort.updated'),
                children: [
                  for (var i = 0; i < widget.recent.length; i += 1)
                    _TvSeriesPosterCard(
                      card: widget.recent[i],
                      focusNode: _node(_recentLane, i),
                      onFocused: () => _remember(_recentLane, i),
                      onTap: () => widget.onOpenSeries(widget.recent[i]),
                    ),
                ],
              ),
              SizedBox(height: m.px(22)),
            ],
            if (showGrid) _buildGrid(m),
          ],
        ),
      ),
    );
  }

  /// 全部剧集：一行 6 列、不限行数。
  ///
  /// 用 `Wrap` 而不是 `GridView`：方向键要先能走到还没构建的卡片上，
  /// 列表的懒加载会让遥控器走不到第二屏。
  Widget _buildGrid(TvMetrics m) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TvSectionHeader(
          title: tr('tv.series.all'),
          trailing: Text(
            tr('tv.series.count', {'n': '${widget.all.length}'}),
            style: TextStyle(
              fontSize: m.px(14),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: m.px(8)),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gap = m.px(20);
              // 减 1px 余量：浮点误差会让第 6 张刚好溢出、掉到下一行。
              final width =
                  (constraints.maxWidth - gap * (_columns - 1)) / _columns - 1;
              return Wrap(
                spacing: gap,
                runSpacing: m.px(22),
                children: [
                  for (var i = 0; i < widget.all.length; i += 1)
                    _TvSeriesPosterCard(
                      card: widget.all[i],
                      width: width,
                      focusNode: _node(_allLane, i),
                      onFocused: () => _rememberGrid(i),
                      onTap: () => widget.onOpenSeries(widget.all[i]),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TvContinueCard extends StatelessWidget {
  const _TvContinueCard({
    required this.entry,
    required this.onTap,
    required this.onFocused,
    this.focusNode,
  });

  final TvContinueEntry entry;
  final VoidCallback onTap;
  final VoidCallback onFocused;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(340);
    final height = width * 9 / 16;
    // 剧名统一走展示名：服务端 series 列是英文发布名。
    final title = SeriesDisplayStore.nameOf(entry.seriesName) ?? entry.seriesName;
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            focusNode: focusNode,
            onTap: onTap,
            onFocused: onFocused,
            radius: m.px(14),
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  TvMediaCover(
                    urls: <String?>[
                      videoPosterUrl(
                        entry.item,
                        kind: 'fanart',
                        size: 640,
                      ),
                      episodeStillFallbackUrl(entry.item.id),
                    ],
                    fallbackText: title,
                    icon: Icons.play_circle_outline_rounded,
                    cacheWidth: (width * 2).round(),
                    borderRadius: m.px(14),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: EdgeInsets.fromLTRB(
                        m.px(10),
                        m.px(18),
                        m.px(10),
                        m.px(8),
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(m.px(14)),
                        ),
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            Colors.black.withValues(alpha: 0.78),
                          ],
                        ),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: m.px(15),
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          SizedBox(width: m.px(8)),
                          Text(
                            entry.code,
                            style: TextStyle(
                              fontSize: m.px(12),
                              fontWeight: FontWeight.w700,
                              color: scheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: m.px(10),
                    top: m.px(10),
                    child: Container(
                      width: m.px(34),
                      height: m.px(34),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.55),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: m.px(22),
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: m.px(8)),
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(
              value: entry.progress,
              minHeight: m.px(3),
              backgroundColor: scheme.onSurface.withValues(alpha: 0.12),
              valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
            ),
          ),
          SizedBox(height: m.px(5)),
          Text(
            entry.item.title,
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

class _TvSeriesPosterCard extends StatelessWidget {
  const _TvSeriesPosterCard({
    required this.card,
    required this.onTap,
    required this.onFocused,
    this.focusNode,
    this.width,
  });

  final TvSeriesCard card;
  final VoidCallback onTap;
  final VoidCallback onFocused;
  final FocusNode? focusNode;

  /// 网格按 6 列算出来的卡片宽度；泳道不传，用设计稿默认值。
  final double? width;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final w = width ?? m.px(190);
    final height = w * 3 / 2;
    // 本地 / 刮削海报多级兜底，最后用 TMDB 剧海报（公网 CDN，不需要鉴权）：
    // 剧集条目的 art 偶尔整批 404（换库 / 重扫后 id 变了），不能整排变成色块。
    final urls = <String?>[
      ...seriesCoverUrls(card, size: (w * 2).round()),
      SeriesDisplayStore.posterOf(card.name),
      // 最后一档：服务端抽帧（16:9 会被裁，但比整块色片强）
      episodeStillFallbackUrl(card.coverId ?? card.firstItem?.id),
    ];
    final title = SeriesDisplayStore.nameOf(card.name) ?? card.name;
    return SizedBox(
      width: w,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            focusNode: focusNode,
            onTap: onTap,
            onFocused: onFocused,
            radius: m.px(14),
            child: SizedBox(
              width: w,
              height: height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  TvMediaCover(
                    urls: urls,
                    fallbackText: title,
                    icon: Icons.video_library_outlined,
                    cacheWidth: (w * 2).round(),
                    borderRadius: m.px(14),
                  ),
                  if (card.unwatched > 0)
                    Positioned(
                      right: m.px(8),
                      top: m.px(8),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: m.px(8),
                          vertical: m.px(3),
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.66),
                          borderRadius: BorderRadius.circular(m.px(8)),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.24),
                          ),
                        ),
                        child: Text(
                          tr('tv.series.unwatched', {'n': '${card.unwatched}'}),
                          style: TextStyle(
                            fontSize: m.px(11),
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  if (card.allWatched)
                    Positioned(
                      right: m.px(8),
                      top: m.px(8),
                      child: Container(
                        width: m.px(28),
                        height: m.px(28),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_rounded,
                          size: m.px(18),
                          color: Colors.greenAccent,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: m.px(9)),
          Text(
            title,
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
            [
              tr('tv.series.seasonCount', {'n': '${card.seasons}'}),
              tr('video.series.episodeCount', {'n': '${card.episodes}'}),
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(12),
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
