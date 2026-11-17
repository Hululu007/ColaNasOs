import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../core/session.dart';
import '../../video/series_display.dart';
import '../../video/video_card.dart';
import '../../video/video_series_widgets.dart';
import '../tv_focus.dart';
import '../tv_media_cover.dart';
import 'tv_series_models.dart';

/// 剧集详情：上部 Hero（横版背景 + 标题/年份/集数/简介 + 继续播放），
/// 中部季切换胶囊（焦点移动即刷新），下部 16:9 单集卡片流。
class TvSeriesDetailPage extends StatefulWidget {
  const TvSeriesDetailPage({
    super.key,
    required this.card,
    required this.libraryId,
    required this.roots,
    required this.progressById,
    required this.onPlay,
  });

  final TvSeriesCard card;
  final String libraryId;
  final List<String> roots;
  final Map<String, VideoProgressItem> progressById;
  final void Function(VideoItem item) onPlay;

  @override
  State<TvSeriesDetailPage> createState() => _TvSeriesDetailPageState();
}

class _TvSeriesDetailPageState extends State<TvSeriesDetailPage> {
  final FocusNode _continueFocus = FocusNode(
    debugLabel: 'tv-series-continue',
  );
  final Map<int, FocusNode> _episodeNodes = <int, FocusNode>{};
  final Map<int, FocusNode> _seasonNodes = <int, FocusNode>{};

  bool _loading = true;
  String? _error;
  List<TvEpisodeRef> _episodes = const <TvEpisodeRef>[];
  int _season = 1;
  TvEpisodeRef? _resume;

  @override
  void initState() {
    super.initState();
    // 从搜索页直接进来时中文剧名可能还在路上：到位后重绘一次标题。
    unawaited(
      SeriesDisplayStore.ensure().then((_) {
        if (mounted) setState(() {});
      }),
    );
    _load();
  }

  @override
  void dispose() {
    _continueFocus.dispose();
    for (final node in _episodeNodes.values) {
      node.dispose();
    }
    for (final node in _seasonNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _episodeNode(int index) => _episodeNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'tv-series-episode-$index'),
  );

  FocusNode _seasonNode(int season) => _seasonNodes.putIfAbsent(
    season,
    () => FocusNode(debugLabel: 'tv-series-season-$season'),
  );

  Future<void> _load() async {
    final card = widget.card;
    List<VideoItem> items = card.preloadedItems;
    try {
      if (items.isEmpty) {
        final res = await ApiSession.instance.client.videoSeriesItems(
          name: card.name,
          libraryId: widget.libraryId,
          limit: 200,
        );
        items = res.items;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
      return;
    }
    if (!mounted) return;
    final episodes = buildEpisodes(
      card: card,
      items: items,
      roots: widget.roots,
      progressById: widget.progressById,
    );
    final seasons = <int>{for (final ref in episodes) ref.season}.toList()..sort();
    TvEpisodeRef? resume;
    for (final ref in episodes) {
      if (ref.percent > 0 && ref.percent < 95) {
        final current = widget.progressById[ref.item.id]?.updatedAt ?? 0;
        final best = resume == null
            ? -1
            : (widget.progressById[resume.item.id]?.updatedAt ?? 0);
        if (current > best) resume = ref;
      }
    }
    resume ??= episodes.isEmpty ? null : episodes.first;
    setState(() {
      _episodes = episodes;
      _season = resume?.season ?? (seasons.isEmpty ? 1 : seasons.first);
      _resume = resume;
      _loading = false;
      _error = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _continueFocus.requestFocus();
    });
  }

  List<int> get _seasons {
    final values = <int>{for (final ref in _episodes) ref.season}.toList()..sort();
    return values;
  }

  List<TvEpisodeRef> get _seasonEpisodes =>
      _episodes.where((ref) => ref.season == _season).toList();

  VideoItem? get _heroItem =>
      widget.card.firstItem ?? (_episodes.isEmpty ? null : _episodes.first.item);

  int? get _year =>
      widget.card.year ??
      (_episodes.isEmpty ? null : _episodes.first.item.year);

  String? get _overview {
    final cardOverview = widget.card.overview;
    if ((cardOverview ?? '').trim().isNotEmpty) return cardOverview;
    for (final ref in _episodes) {
      final value = ref.item.overview;
      if ((value ?? '').trim().isNotEmpty) return value;
    }
    return null;
  }

  void _playEpisode(TvEpisodeRef ref) {
    widget.onPlay(ref.item);
  }

  void _playResume() {
    final ref = _resume ?? (_episodes.isEmpty ? null : _episodes.first);
    if (ref == null) return;
    _playEpisode(ref);
  }

  void _selectSeason(int season) {
    if (season == _season) return;
    setState(() => _season = season);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      final focus = FocusManager.instance.primaryFocus;
      if (focus != null &&
          _seasonNodes.values.contains(focus) &&
          _seasonEpisodes.isNotEmpty) {
        _episodeNode(0).requestFocus();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return NasEmptyState(
        title: tr('common.error'),
        message: _error,
        icon: Icons.error_outline,
      );
    }
    final seasons = _seasons;
    final seasonEpisodes = _seasonEpisodes;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: SingleChildScrollView(
        padding: EdgeInsets.only(bottom: m.px(28)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHero(m),
            if (seasons.length > 1) ...[
              SizedBox(height: m.px(18)),
              _buildSeasons(m, seasons),
            ],
            SizedBox(height: m.px(16)),
            TvSectionHeader(
              title: tr('video.series.episodeList'),
              trailing: Text(
                tr('video.series.episodeCount', {
                  'n': '${seasonEpisodes.length}',
                }),
                style: TextStyle(
                  fontSize: m.px(14),
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            SizedBox(height: m.px(6)),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: m.px(8)),
              child: seasonEpisodes.isEmpty
                  ? NasEmptyState(
                      title: tr('video.detail.notScraped'),
                      icon: Icons.video_library_outlined,
                    )
                  : Wrap(
                      spacing: m.px(20),
                      runSpacing: m.px(22),
                      children: [
                        for (var i = 0; i < seasonEpisodes.length; i += 1)
                          _TvEpisodeCard(
                            episode: seasonEpisodes[i],
                            focusNode: _episodeNode(i),
                            onTap: () => _playEpisode(seasonEpisodes[i]),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHero(TvMetrics m) {
    final item = _heroItem;
    final card = widget.card;
    // 剧名统一走展示名：`series` 列是英文发布名，中文名来自 TMDB / 路径提示。
    final title = SeriesDisplayStore.nameOf(card.name) ?? card.name;
    final heroHeight = m.px(360);
    final urls = <String?>[
      if (item != null)
        videoPosterUrl(item, kind: 'fanart', size: 1600)
      else
        seriesArtUrl(card.posterId, kind: 'fanart', size: 1600),
      if (item != null)
        videoPosterUrl(item, size: 800)
      else
        seriesArtUrl(card.posterId, size: 800),
      if (item != null)
        episodeStillFallbackUrl(item.id)
      else
        episodeStillFallbackUrl(card.coverId),
    ];
    final meta = <String>[
      if (_year != null) '${_year!}',
      if (_episodes.isNotEmpty)
        tr('video.series.episodeCount', {'n': '${_episodes.length}'}),
      if (card.seasons > 1)
        tr('tv.series.seasonCount', {'n': '${card.seasons}'}),
    ].join(' · ');
    final resume = _resume;
    final resumeLabel = resume == null
        ? tr('tv.series.playFirst')
        : resume.percent > 0
        ? tr('tv.series.resumeFrom', {'code': resume.code})
        : tr('tv.series.playFirst');
    return SizedBox(
      height: heroHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(m.px(20)),
        child: Stack(
          fit: StackFit.expand,
          children: [
          TvMediaCover(
            urls: urls,
            fallbackText: title,
            icon: Icons.live_tv_rounded,
            cacheWidth: 1600,
            borderRadius: m.px(20),
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(m.px(20)),
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  Colors.black.withValues(alpha: 0.82),
                  Colors.black.withValues(alpha: 0.55),
                  Colors.black.withValues(alpha: 0.12),
                ],
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              m.px(28),
              m.px(24),
              m.px(28),
              m.px(22),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: m.px(38),
                    height: 1.1,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: m.px(8)),
                Text(
                  meta,
                  style: TextStyle(
                    fontSize: m.px(16),
                    color: Colors.white.withValues(alpha: 0.72),
                  ),
                ),
                SizedBox(height: m.px(12)),
                if ((_overview ?? '').trim().isNotEmpty)
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: m.px(760)),
                    child: Text(
                      _overview!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: m.px(14),
                        height: 1.45,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                const Spacer(),
                Row(
                  children: [
                    _TvHeroButton(
                      label: resumeLabel,
                      icon: Icons.play_arrow_rounded,
                      focusNode: _continueFocus,
                      onTap: _playResume,
                    ),
                    SizedBox(width: m.px(14)),
                    if (resume != null)
                      Text(
                        '${resume.code} · ${resume.item.title}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: m.px(13),
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
        ),
      ),
    );
  }

  Widget _buildSeasons(TvMetrics m, List<int> seasons) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: m.px(42),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: m.px(8)),
        child: Row(
          children: [
            for (var i = 0; i < seasons.length; i += 1) ...[
              if (i > 0) SizedBox(width: m.px(10)),
              TvFocusCard(
                focusNode: _seasonNode(seasons[i]),
                onTap: () => _selectSeason(seasons[i]),
                onFocused: () => _selectSeason(seasons[i]),
                radius: m.px(21),
                focusScale: 1.05,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: m.px(18),
                    vertical: m.px(9),
                  ),
                  decoration: BoxDecoration(
                    color: _season == seasons[i]
                        ? scheme.primary
                        : scheme.onSurface.withValues(alpha: 0.09),
                    borderRadius: BorderRadius.circular(m.px(21)),
                  ),
                  child: Text(
                    tr('video.series.season', {'n': '${seasons[i]}'}),
                    style: TextStyle(
                      fontSize: m.px(15),
                      fontWeight: FontWeight.w700,
                      color: _season == seasons[i]
                          ? scheme.onPrimary
                          : scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TvHeroButton extends StatelessWidget {
  const _TvHeroButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.focusNode,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return TvFocusCard(
      focusNode: focusNode,
      onTap: onTap,
      radius: m.px(14),
      focusScale: 1.05,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: m.px(22),
          vertical: m.px(13),
        ),
        decoration: BoxDecoration(
          color: scheme.primary,
          borderRadius: BorderRadius.circular(m.px(14)),
        ),
        child: Row(
          children: [
            Icon(icon, size: m.px(22), color: scheme.onPrimary),
            SizedBox(width: m.px(6)),
            Text(
              label,
              style: TextStyle(
                fontSize: m.px(16),
                fontWeight: FontWeight.w800,
                color: scheme.onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvEpisodeCard extends StatelessWidget {
  const _TvEpisodeCard({
    required this.episode,
    required this.onTap,
    this.focusNode,
  });

  final TvEpisodeRef episode;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(300);
    final height = width * 9 / 16;
    final item = episode.item;
    final meta = <String>[
      formatDurationMs(item.durationMs ?? 0),
      if (episode.resolution.isNotEmpty) episode.resolution,
    ].where((value) => value.isNotEmpty).join(' · ');
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            focusNode: focusNode,
            onTap: onTap,
            radius: m.px(12),
            child: SizedBox(
              width: width,
              height: height,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  TvMediaCover(
                    urls: <String?>[
                      videoPosterUrl(item, kind: 'fanart', size: 640),
                      episodeStillFallbackUrl(item.id),
                    ],
                    fallbackText: tr(
                      'video.series.episode',
                      {'n': '${episode.episode}'},
                    ),
                    icon: Icons.play_circle_outline_rounded,
                    cacheWidth: (width * 2).round(),
                    borderRadius: m.px(12),
                  ),
                  Positioned(
                    left: m.px(8),
                    top: m.px(8),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: m.px(7),
                        vertical: m.px(2),
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.62),
                        borderRadius: BorderRadius.circular(m.px(6)),
                      ),
                      child: Text(
                        'E${episode.episode.toString().padLeft(2, '0')}',
                        style: TextStyle(
                          fontSize: m.px(11),
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  if (episode.watched)
                    Positioned(
                      right: m.px(8),
                      top: m.px(8),
                      child: Container(
                        width: m.px(26),
                        height: m.px(26),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.64),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_rounded,
                          size: m.px(17),
                          color: Colors.greenAccent,
                        ),
                      ),
                    ),
                  if (episode.percent > 0 && episode.percent < 95)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ClipRRect(
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(m.px(12)),
                        ),
                        child: LinearProgressIndicator(
                          value: episode.progress,
                          minHeight: m.px(3),
                          backgroundColor: Colors.black.withValues(alpha: 0.45),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            scheme.primary,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(height: m.px(8)),
          Text(
            '${tr('video.series.episode', {'n': '${episode.episode}'})} · ${item.title}',
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
            meta,
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
