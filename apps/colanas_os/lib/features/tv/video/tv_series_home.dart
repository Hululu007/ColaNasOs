import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../core/session.dart';
import '../../video/video_card.dart';
import '../../video/video_series_widgets.dart';
import '../tv_focus.dart';
import '../tv_media_cover.dart';
import 'tv_series_models.dart';

/// 整部剧的封面地址：只认竖版海报，绝不用横版剧照 / 首帧充当封面。
///
/// - 服务端聚合的剧：优先 `posterId`（真有 `nfo_poster` 的那一集），再 `coverId`；
/// - 文件夹聚合的剧（健身课等无刮削信息）：用条目 id 直接请求 `art?kind=poster`，
///   服务端在 art 内部按 poster → thumb 兜底，并会现场按
///   `-poster/-post/-cover/-folder` 命名找图；
/// - 都拿不到就返回空，由 [TvMediaCover] 生成名称哈希渐变海报，
///   而不是把 16:9 的 fanart 铺进 2:3 的封面位（那就是「封面像截图」的原因）。
List<String?> seriesCoverUrls(TvSeriesCard card, {int size = 0}) {
  final urls = <String?>[
    if ((card.posterId ?? '').trim().isNotEmpty)
      seriesArtUrl(card.posterId, size: size),
    if ((card.coverId ?? '').trim().isNotEmpty)
      seriesArtUrl(card.coverId, size: size),
    if ((card.coverId ?? '').trim().isEmpty && card.firstItem != null)
      _itemPosterUrl(card.firstItem!.id, size: size),
  ];
  final seen = <String>{};
  return <String?>[
    for (final url in urls)
      if (url != null && url.trim().isNotEmpty && seen.add(url)) url,
  ];
}

/// 直接走 `art?kind=poster`，绕开 `videoPosterUrl` 的「无图就回首帧」分支。
String? _itemPosterUrl(String id, {int size = 0}) {
  final value = id.trim();
  if (value.isEmpty) return null;
  final base = ApiSession.instance.baseUrl;
  final sizeQ = size > 0 ? '&size=$size' : '';
  return '$base/api/v1/video/art?id=${Uri.encodeComponent(value)}&kind=poster$sizeQ';
}

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

  final Map<String, FocusNode> _nodes = <String, FocusNode>{};
  final Map<String, int> _lastIndex = <String, int>{};
  final FocusNode _ownedFirst = FocusNode(debugLabel: 'tv-series-first');

  List<({String id, int count})> _lanes = const [];
  String? _focusedLane;

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final context = targetNode.context;
      if (context == null || !mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
      );
    });
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final showContinue = widget.continueItems.isNotEmpty;
    final showRecent = _showRecent;
    final showAll = widget.all.isNotEmpty;
    _lanes = <({String id, int count})>[
      if (showContinue)
        (id: _continueLane, count: widget.continueItems.length),
      if (showRecent) (id: _recentLane, count: widget.recent.length),
      if (showAll) (id: _allLane, count: widget.all.length),
    ];

    if (_lanes.isEmpty) {
      return NasEmptyState(
        title: tr('video.home.empty'),
        message: tr('video.home.emptyHint'),
        icon: Icons.video_library_outlined,
      );
    }

    final rows = <Widget>[
      if (showContinue)
        TvCardRow(
          title: tr('video.home.continue'),
          children: [
            for (var i = 0; i < widget.continueItems.length; i += 1)
              _TvContinueCard(
                entry: widget.continueItems[i],
                focusNode: _node(_continueLane, i),
                onFocused: () => _remember(_continueLane, i),
                onTap: () => widget.onPlayContinue(widget.continueItems[i]),
              ),
          ],
        ),
      if (showRecent)
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
      if (showAll)
        TvCardRow(
          title: tr('tv.series.all'),
          trailing: Text(
            tr('tv.series.count', {'n': '${widget.all.length}'}),
            style: TextStyle(
              fontSize: m.px(14),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            for (var i = 0; i < widget.all.length; i += 1)
              _TvSeriesPosterCard(
                card: widget.all[i],
                focusNode: _node(_allLane, i),
                onFocused: () => _remember(_allLane, i),
                onTap: () => widget.onOpenSeries(widget.all[i]),
              ),
          ],
        ),
    ];

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(top: m.px(6), bottom: m.px(28)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < rows.length; i += 1) ...[
              if (i > 0) SizedBox(height: m.px(22)),
              rows[i],
            ],
          ],
        ),
      ),
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
                    fallbackText: entry.seriesName,
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
                              entry.seriesName,
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
  });

  final TvSeriesCard card;
  final VoidCallback onTap;
  final VoidCallback onFocused;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(190);
    final height = width * 3 / 2;
    final urls = seriesCoverUrls(card, size: 480);
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
                    urls: urls,
                    fallbackText: card.name,
                    icon: Icons.video_library_outlined,
                    cacheWidth: (width * 2).round(),
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
            card.name,
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
