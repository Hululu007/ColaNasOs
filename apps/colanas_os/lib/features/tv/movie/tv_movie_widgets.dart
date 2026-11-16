import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../video/video_card.dart';
import '../../video/video_series_widgets.dart';
import '../tv_focus.dart';
import '../tv_media_cover.dart';
import 'tv_movie_models.dart';

/// 电影模块共用的三张卡：2:3 海报卡、合集卡、16:9 继续观看卡。
///
/// 抽出来的理由：首页泳道、A-Z 网格、合集页、详情页相关推荐都用海报卡，
/// 只有在同一份文件里才能保证角标 / 进度条 / 兜底封面口径一致。

/// 2:3 电影海报卡（标题 + 年份/时长/评分副标题）。
class TvMoviePosterCard extends StatelessWidget {
  const TvMoviePosterCard({
    super.key,
    required this.item,
    required this.onTap,
    required this.onFocused,
    this.focusNode,
    this.percent = 0,
    this.width,
  });

  final VideoItem item;
  final VoidCallback onTap;
  final VoidCallback onFocused;
  final FocusNode? focusNode;

  /// 已观看进度（0..100），0 不显示进度条。
  final int percent;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final w = width ?? m.px(170);
    final h = w * 3 / 2;
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
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  TvMediaCover(
                    urls: _movieArtUrls(item, size: (w * 2).round()),
                    fallbackText: item.title,
                    icon: Icons.movie_outlined,
                    cacheWidth: (w * 2).round(),
                    borderRadius: m.px(14),
                  ),
                  if ((item.score ?? 0) > 0)
                    Positioned(
                      right: m.px(8),
                      top: m.px(8),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: m.px(7),
                          vertical: m.px(2),
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.62),
                          borderRadius: BorderRadius.circular(m.px(7)),
                        ),
                        child: Text(
                          item.score!.toStringAsFixed(1),
                          style: TextStyle(
                            fontSize: m.px(11),
                            fontWeight: FontWeight.w800,
                            color: Colors.amberAccent,
                          ),
                        ),
                      ),
                    ),
                  if (item.watched)
                    Positioned(
                      left: m.px(8),
                      top: m.px(8),
                      child: Container(
                        width: m.px(24),
                        height: m.px(24),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.check_rounded,
                          size: m.px(15),
                          color: Colors.greenAccent,
                        ),
                      ),
                    ),
                  if (percent > 0)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: ClipRRect(
                        borderRadius: BorderRadius.vertical(
                          bottom: Radius.circular(m.px(14)),
                        ),
                        child: LinearProgressIndicator(
                          value: (percent / 100).clamp(0.0, 1.0),
                          minHeight: m.px(4),
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
          SizedBox(height: m.px(9)),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(15),
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
              fontSize: m.px(12),
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 系列电影合集卡：2x2 海报拼图 + 「N 部」角标，不出现空黑块。
class TvMovieCollectionCard extends StatelessWidget {
  const TvMovieCollectionCard({
    super.key,
    required this.collection,
    required this.onTap,
    required this.onFocused,
    this.focusNode,
    this.width,
  });

  final TvMovieCollection collection;
  final VoidCallback onTap;
  final VoidCallback onFocused;
  final FocusNode? focusNode;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final w = width ?? m.px(170);
    final h = w * 3 / 2;
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
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _TvMovieCollage(
                    collection: collection,
                    radius: m.px(14),
                    cacheWidth: (w).round(),
                  ),
                  Positioned(
                    right: m.px(8),
                    bottom: m.px(8),
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: m.px(7),
                        vertical: m.px(2),
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.66),
                        borderRadius: BorderRadius.circular(m.px(7)),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.22),
                        ),
                      ),
                      child: Text(
                        tr('tv.movie.count', {
                          'n': '${collection.movies.length}',
                        }),
                        style: TextStyle(
                          fontSize: m.px(11),
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: m.px(9)),
          Text(
            collection.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(15),
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          SizedBox(height: m.px(3)),
          Text(
            collection.movies.isNotEmpty
                ? [
                    if ((collection.movies.first.year ?? 0) > 0)
                      '${collection.movies.first.year}',
                    tr('tv.movie.count', {
                      'n': '${collection.movies.length}',
                    }),
                  ].join(' · ')
                : tr('tv.movie.count', {'n': '0'}),
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

class _TvMovieCollage extends StatelessWidget {
  const _TvMovieCollage({
    required this.collection,
    required this.radius,
    required this.cacheWidth,
  });

  final TvMovieCollection collection;
  final double radius;
  final int cacheWidth;

  @override
  Widget build(BuildContext context) {
    final movies = collection.movies.take(4).toList();
    final cells = <Widget>[
      for (var i = 0; i < 4; i += 1)
        if (i < movies.length)
          TvMediaCover(
            urls: _movieArtUrls(movies[i], size: cacheWidth),
            fallbackText: movies[i].title,
            icon: Icons.movie_outlined,
            cacheWidth: cacheWidth,
          )
        else
          TvMediaCover(
            urls: const <String?>[],
            fallbackText: movies.isEmpty ? collection.name : movies.first.title,
            icon: Icons.movie_filter_outlined,
            cacheWidth: cacheWidth,
          ),
    ];
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: cells[0]),
                SizedBox(width: 2, child: ColoredBox(color: Colors.black26)),
                Expanded(child: cells[1]),
              ],
            ),
          ),
          const SizedBox(height: 2),
          Expanded(
            child: Row(
              children: [
                Expanded(child: cells[2]),
                SizedBox(width: 2, child: ColoredBox(color: Colors.black26)),
                Expanded(child: cells[3]),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 继续观看卡：16:9 剧照 + 片名 + 进度条。
class TvMovieContinueCard extends StatelessWidget {
  const TvMovieContinueCard({
    super.key,
    required this.entry,
    required this.onTap,
    required this.onFocused,
    this.focusNode,
  });

  final TvMovieContinue entry;
  final VoidCallback onTap;
  final VoidCallback onFocused;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final w = m.px(340);
    final h = w * 9 / 16;
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
              height: h,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  TvMediaCover(
                    urls: <String?>[
                      videoPosterUrl(entry.item, kind: 'fanart', size: 640),
                      episodeStillFallbackUrl(entry.item.id),
                    ],
                    fallbackText: entry.item.title,
                    icon: Icons.play_circle_outline_rounded,
                    cacheWidth: (w * 2).round(),
                    borderRadius: m.px(14),
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
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Container(
                      padding: EdgeInsets.fromLTRB(
                        m.px(10),
                        m.px(16),
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
                              entry.item.title,
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
                            '${entry.percent}%',
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
            videoMetaLine(entry.item),
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

/// 电影封面地址：刮削海报 → 横版剧照 → 服务端抽帧。
List<String?> _movieArtUrls(VideoItem item, {required int size}) => <String?>[
  videoPosterUrl(item, size: size),
  videoPosterUrl(item, kind: 'fanart', size: size),
  episodeStillFallbackUrl(item.id),
];
