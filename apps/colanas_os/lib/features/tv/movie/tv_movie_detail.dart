import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../video/video_card.dart';
import '../../video/video_genre_labels.dart';
import '../../video/video_series_widgets.dart';
import '../tv_focus.dart';
import '../tv_media_cover.dart';
import 'tv_movie_models.dart';
import 'tv_movie_widgets.dart';

/// 电影详情（大屏）：上部 Hero（横版剧照 + 标题/年份/时长/评分/简介 +
/// 默认聚焦的播放按钮），下部信息与相关影片/同系列推荐。
class TvMovieDetailPage extends StatefulWidget {
  const TvMovieDetailPage({
    super.key,
    required this.movie,
    required this.all,
    required this.collections,
    required this.percent,
    required this.preparing,
    required this.onPlay,
    required this.onSelectMovie,
  });

  final VideoItem movie;
  final List<VideoItem> all;
  final List<TvMovieCollection> collections;
  final int percent;
  final bool preparing;
  final VoidCallback onPlay;
  final void Function(VideoItem movie) onSelectMovie;

  @override
  State<TvMovieDetailPage> createState() => _TvMovieDetailPageState();
}

class _TvMovieDetailPageState extends State<TvMovieDetailPage> {
  final FocusNode _playFocus = FocusNode(debugLabel: 'tv-movie-play');
  final Map<String, FocusNode> _relatedNodes = <String, FocusNode>{};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _playFocus.dispose();
    for (final node in _relatedNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _relatedNode(String id) => _relatedNodes.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'tv-movie-related-$id'),
  );

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final movie = widget.movie;
    final related = relatedMovies(
      movie: movie,
      all: widget.all,
      collections: widget.collections,
      limit: 12,
    );
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      child: DecoratedBox(
        // 沉浸式深色底：详情页整页压暗，白色标题 / 简介在任何面板底色上都可读。
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF12161E), Color(0xFF06080C)],
          ),
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.only(bottom: m.px(28)),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildHero(m, movie),
              SizedBox(height: m.px(20)),
              _buildInfo(m, movie),
              if (related.isNotEmpty) ...[
                SizedBox(height: m.px(18)),
                TvCardRow(
                  title: tr('tv.movie.related'),
                  children: [
                    for (final item in related)
                      TvMoviePosterCard(
                        item: item,
                        width: m.px(150),
                        focusNode: _relatedNode(item.id),
                        onFocused: () {},
                        onTap: () => widget.onSelectMovie(item),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHero(TvMetrics m, VideoItem movie) {
    final meta = <String>[
      if ((movie.year ?? 0) > 0) '${movie.year}',
      if ((movie.runtimeMin ?? 0) > 0)
        tr('video.detail.minutes', {'count': '${movie.runtimeMin}'}),
      if ((movie.score ?? 0) > 0) '★ ${movie.score!.toStringAsFixed(1)}',
      if (movie.height != null && movie.height! >= 2160) '4K',
    ].join(' · ');
    return SizedBox(
      height: m.px(430),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(m.px(20)),
        child: Stack(
          fit: StackFit.expand,
          children: [
            TvMediaCover(
              urls: <String?>[
                videoPosterUrl(movie, kind: 'fanart', size: 1600),
                videoPosterUrl(movie, size: 800),
                episodeStillFallbackUrl(movie.id),
              ],
              fallbackText: movie.title,
              icon: Icons.movie_outlined,
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
                    Colors.black.withValues(alpha: 0.88),
                    Colors.black.withValues(alpha: 0.58),
                    Colors.black.withValues(alpha: 0.08),
                  ],
                  stops: const [0, 0.52, 1],
                ),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(m.px(20)),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.15),
                    Colors.black.withValues(alpha: 0.8),
                  ],
                  stops: const [0, 0.55, 1],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                m.px(32),
                m.px(24),
                m.px(32),
                m.px(26),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  Text(
                    movie.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: m.px(42),
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
                      fontSize: m.px(17),
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.82),
                    ),
                  ),
                  SizedBox(height: m.px(8)),
                  Wrap(
                    spacing: m.px(8),
                    runSpacing: m.px(6),
                    children: [
                      for (final flag in videoFlagsOf(movie))
                        Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: m.px(8),
                            vertical: m.px(2),
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.16),
                            borderRadius: BorderRadius.circular(m.px(6)),
                          ),
                          child: Text(
                            flag,
                            style: TextStyle(
                              fontSize: m.px(12),
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                            ),
                          ),
                        ),
                    ],
                  ),
                  if ((movie.overview ?? '').trim().isNotEmpty) ...[
                    SizedBox(height: m.px(10)),
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: m.px(940)),
                      child: Text(
                        movie.overview!,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: m.px(15),
                          height: 1.45,
                          color: Colors.white.withValues(alpha: 0.76),
                        ),
                      ),
                    ),
                  ],
                  SizedBox(height: m.px(16)),
                  Row(
                    children: [
                      TvFocusCard(
                        focusNode: _playFocus,
                        onTap: widget.onPlay,
                        radius: m.px(30),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: m.px(26),
                            vertical: m.px(11),
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(m.px(30)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                widget.preparing
                                    ? Icons.hourglass_top_rounded
                                    : Icons.play_arrow_rounded,
                                size: m.px(26),
                                color: Colors.black,
                              ),
                              SizedBox(width: m.px(6)),
                              Text(
                                widget.percent > 0
                                    ? tr('video.collection.continuePlay')
                                    : tr('tv.movie.play'),
                                style: TextStyle(
                                  fontSize: m.px(18),
                                  fontWeight: FontWeight.w800,
                                  color: Colors.black,
                                ),
                              ),
                            ],
                          ),
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

  Widget _buildInfo(TvMetrics m, VideoItem movie) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <({String label, String value})>[
      if (movie.directors.isNotEmpty)
        (label: tr('video.detail.director'), value: movie.directors.join(' / ')),
      if (movie.actors.isNotEmpty)
        (
          label: tr('video.detail.actor'),
          value: movie.actors.take(8).join(' / '),
        ),
      if (movie.genres.isNotEmpty)
        (
          label: tr('video.detail.genre'),
          value: movie.genres.map(genreLabel).join(' / '),
        ),
      if (movie.regions.isNotEmpty)
        (label: tr('video.detail.region'), value: movie.regions.join(' / ')),
    ];
    if (rows.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: m.px(10)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            Padding(
              padding: EdgeInsets.only(bottom: m.px(8)),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: m.px(64),
                    child: Text(
                      row.label,
                      style: TextStyle(
                        fontSize: m.px(14),
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      row.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: m.px(14),
                        height: 1.4,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
