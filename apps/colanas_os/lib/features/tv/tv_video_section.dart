import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../video/player_page.dart';
import '../video/video_card.dart';
import 'tv_focus.dart';

/// 浏览器 `<video>` 能直接吃的容器；其余（mkv/avi/ts…）必须靠服务端转码。
const _webContainers = {'mp4', 'm4v', 'mov', 'webm', 'ogv', 'ogg'};

/// 这条流在浏览器里是不是必须转码才能播。
bool _webNeedsTranscode(Map<String, dynamic>? compat) {
  if (compat == null) return false;
  if (compat['needTranscode'] == true) return true;
  final container = (compat['container'] as String? ?? '').toLowerCase();
  return container.isNotEmpty && !_webContainers.contains(container);
}

/// 影视详情 / 影视库列表共用的播放动作：取流地址后推入现有播放器。
///
/// Web 预览（TV 端网页版）额外做一次降级：需要转码的片源（HDR / HEVC / MKV）
/// 在浏览器里只能播服务端转出的 HLS，而开发实例会跳过后台转码（503），
/// 进去只会看到一个「切换失败」的错误页。这里直接给出明确提示，
/// 不把用户丢进播放器再报错。原生 TV / 客户端不受影响（kIsWeb 为 false）。
Future<void> playTvVideo(BuildContext context, VideoItem item) async {
  final res = await ApiSession.instance.client.videoStreamUrl(id: item.id);
  final url = '${ApiSession.instance.baseUrl}${res.url}';
  if (!context.mounted) return;
  if (kIsWeb && _webNeedsTranscode(res.compat)) {
    NasSnack.show(context, tr('tv.preview.transcodeUnsupported'));
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => PlayerPage(
        url: url,
        title: item.title,
        itemId: item.id,
        compat: res.compat,
        sourceHeight: item.height,
        sourceBytes: item.size,
        durationMs: item.durationMs,
      ),
    ),
  );
}

/// TV 版影视分区：大图推荐 + 横向分区的「继续观看 / 推荐 / 最近添加」。
///
/// 数据完全走既有服务端接口（`/video/home`），详情与播放复用影视模块的
/// 播放器（`PlayerPage`），只是把入口换成遥控器焦点卡片。
class TvVideoSection extends StatefulWidget {
  const TvVideoSection({super.key, required this.back, this.firstFocusNode});

  final TvBackController back;

  /// 顶部 tab 下键进入内容时，外壳会 request 这个节点。
  final FocusNode? firstFocusNode;

  @override
  State<TvVideoSection> createState() => _TvVideoSectionState();
}

class _TvVideoSectionState extends State<TvVideoSection> {
  bool _loading = true;
  String? _error;
  VideoHomeResponse? _home;
  VideoItem? _detail;
  bool _preparing = false;

  /// 首个卡片焦点：优先用外壳传入的节点，保证「tab ↓」能直接落到第一张卡片。
  final FocusNode _ownFirstCardFocus = FocusNode(debugLabel: 'tv-video-first');
  FocusNode get _firstFocus => widget.firstFocusNode ?? _ownFirstCardFocus;

  bool _onBackPressed() => _handleBack();

  bool _hasOverlay() => _detail != null;

  @override
  void initState() {
    super.initState();
    widget.back.handler = _onBackPressed;
    widget.back.overlay = _hasOverlay;
    _load();
  }

  @override
  void dispose() {
    if (widget.back.handler == _onBackPressed) {
      widget.back.handler = null;
      widget.back.overlay = null;
    }
    _ownFirstCardFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final home = await ApiSession.instance.client.videoHome(
        recommendLimit: 20,
        recentPlayLimit: 20,
        recentAddLimit: 20,
      );
      if (!mounted) return;
      setState(() {
        _home = home;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  bool _handleBack() {
    if (_detail == null) return false;
    setState(() => _detail = null);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
    return true;
  }

  void _openDetail(VideoItem item) => setState(() => _detail = item);

  Future<void> _play(VideoItem item) async {
    if (_preparing) return;
    setState(() => _preparing = true);
    try {
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

  @override
  Widget build(BuildContext context) => _buildBody(context);

  Widget _buildBody(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _load);
    }
    final item = _detail;
    if (item != null) {
      return TvVideoDetailView(
        item: item,
        preparing: _preparing,
        onPlay: () => _play(item),
        onBack: _handleBack,
      );
    }
    final home = _home;
    if (home == null) {
      return NasEmptyState(
        title: tr('video.home.empty'),
        message: tr('video.home.emptyHint'),
        icon: Icons.movie_outlined,
      );
    }

    final hero =
        home.recommend.isNotEmpty
            ? home.recommend.first
            : home.recentPlay.isNotEmpty
            ? home.recentPlay.first
            : home.recentAdd
                .expand((row) => row.items)
                .cast<VideoItem?>()
                .firstWhere((item) => item != null, orElse: () => null);

    // 首个卡片持有固定的焦点节点：详情关闭、返回列表时把焦点放回这里。
    var needsFirstFocus = hero == null;
    FocusNode? takeFirstFocus() {
      if (!needsFirstFocus) return null;
      needsFirstFocus = false;
      return _firstFocus;
    }

    final rows = <Widget>[];
    if (home.recentPlay.isNotEmpty) {
      rows.add(
        TvCardRow(
          title: tr('video.home.continue'),
          children: [
            for (final item in home.recentPlay)
              _TvPosterCard(
                item: item,
                progress: _progressOf(home, item),
                focusNode: takeFirstFocus(),
                onTap: () => _openDetail(item),
              ),
          ],
        ),
      );
    }
    if (home.recommend.isNotEmpty) {
      rows.add(
        TvCardRow(
          title: tr('video.home.recommend'),
          children: [
            for (final item in home.recommend)
              _TvPosterCard(
                item: item,
                focusNode: takeFirstFocus(),
                onTap: () => _openDetail(item),
              ),
          ],
        ),
      );
    }
    for (final row in home.recentAdd.take(4)) {
      if (row.items.isEmpty) continue;
      rows.add(
        TvCardRow(
          title: '${tr('video.home.recentAdd')} · ${row.libraryName}',
          children: [
            for (final item in row.items)
              _TvPosterCard(
                item: item,
                focusNode: takeFirstFocus(),
                onTap: () => _openDetail(item),
              ),
          ],
        ),
      );
    }

    if (rows.isEmpty) {
      return NasEmptyState(
        title: tr('video.home.empty'),
        message: tr('video.home.emptyHint'),
        icon: Icons.movie_outlined,
      );
    }

    final m = TvMetricsScope.of(context);
    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: m.px(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (hero != null)
            _TvHero(
              item: hero,
              focusNode: takeFirstFocus(),
              onTap: () => _openDetail(hero),
              onPlay: () => _play(hero),
            ),
          SizedBox(height: m.px(24)),
          ...rows,
        ],
      ),
    );
  }

  double? _progressOf(VideoHomeResponse home, VideoItem item) {
    for (final p in home.progress) {
      if (p.itemId != item.id) continue;
      final value = p.percent / 100;
      if (value <= 0 || value >= 1) return null;
      return value;
    }
    return null;
  }
}

/// 顶部大图推荐位：横版剧照 + 标题 / 简介 + 播放按钮。
class _TvHero extends StatelessWidget {
  const _TvHero({
    required this.item,
    required this.onTap,
    required this.onPlay,
    this.focusNode,
  });

  final VideoItem item;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final height = m.px(360);
    final isImage = item.mediaType == 'image';
    return TvFocusCard(
      focusNode: focusNode,
      onTap: onTap,
      radius: m.px(22),
      focusScale: 1.01,
      child: SizedBox(
        height: height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(m.px(22)),
          child: LayoutBuilder(
            builder: (context, box) => Stack(
              fit: StackFit.expand,
              children: [
                NasCoverImage(
                  url: videoPosterUrl(item, kind: 'fanart', size: 1600),
                  fit: BoxFit.cover,
                  headers: videoArtHeaders,
                  fallbackText: item.title,
                  cacheWidth: 1600,
                  borderRadius: 0,
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.centerLeft,
                      end: Alignment.centerRight,
                      colors: [
                        Color(0xE6000000),
                        Color(0x66000000),
                        Color(0x00000000),
                      ],
                      stops: [0, 0.55, 1],
                    ),
                  ),
                ),
                Positioned(
                  left: m.px(40),
                  right: box.maxWidth * 0.42,
                  bottom: m.px(34),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: m.px(42),
                          height: 1.12,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                      SizedBox(height: m.px(10)),
                      Text(
                        videoMetaLine(item),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: m.px(18),
                          color: Colors.white.withValues(alpha: 0.78),
                        ),
                      ),
                      if ((item.overview ?? '').isNotEmpty) ...[
                        SizedBox(height: m.px(10)),
                        Text(
                          item.overview!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: m.px(16),
                            height: 1.4,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                      if (!isImage) ...[
                        SizedBox(height: m.px(18)),
                        TvFocusCard(
                          onTap: onPlay,
                          radius: m.px(30),
                          child: Container(
                            padding: EdgeInsets.symmetric(
                              horizontal: m.px(26),
                              vertical: m.px(12),
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(m.px(30)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.play_arrow_rounded,
                                  size: m.px(28),
                                  color: Colors.black,
                                ),
                                SizedBox(width: m.px(6)),
                                Text(
                                  tr('video.series.play'),
                                  style: TextStyle(
                                    fontSize: m.px(18),
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TvPosterCard extends StatelessWidget {
  const _TvPosterCard({
    required this.item,
    required this.onTap,
    this.progress,
    this.focusNode,
  });

  final VideoItem item;
  final VoidCallback onTap;
  final double? progress;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(190);
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
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.6),
                              Colors.transparent,
                            ],
                            stops: const [0, 0.35],
                          ),
                        ),
                      ),
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
                    if (progress != null)
                      Positioned(
                        left: m.px(8),
                        right: m.px(8),
                        bottom: m.px(8),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: m.px(5),
                            backgroundColor: Colors.black.withValues(alpha: 0.4),
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

class TvVideoDetailView extends StatelessWidget {
  const TvVideoDetailView({
    super.key,
    required this.item,
    required this.preparing,
    required this.onPlay,
    required this.onBack,
  });

  final VideoItem item;
  final bool preparing;
  final VoidCallback onPlay;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final isImage = item.mediaType == 'image';
    return ClipRRect(
      borderRadius: BorderRadius.circular(m.px(22)),
      child: Stack(
        fit: StackFit.expand,
        children: [
          NasCoverImage(
            url: videoPosterUrl(item, kind: 'fanart', size: 1600),
            fit: BoxFit.cover,
            headers: videoArtHeaders,
            fallbackText: item.title,
            cacheWidth: 1600,
            borderRadius: 0,
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [Color(0xF2000000), Color(0xB3000000), Color(0x33000000)],
                stops: [0, 0.5, 1],
              ),
            ),
          ),
          SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              m.px(44),
              m.px(36),
              m.px(44),
              m.px(36),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: m.px(46),
                    height: 1.1,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
                SizedBox(height: m.px(12)),
                Text(
                  videoMetaLine(item),
                  style: TextStyle(
                    fontSize: m.px(19),
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
                SizedBox(height: m.px(20)),
                Wrap(
                  spacing: m.px(10),
                  runSpacing: m.px(10),
                  children: [
                    for (final flag in videoFlagsOf(item))
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: m.px(10),
                          vertical: m.px(4),
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(m.px(6)),
                        ),
                        child: Text(
                          flag,
                          style: TextStyle(
                            fontSize: m.px(14),
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                      ),
                  ],
                ),
                if ((item.overview ?? '').isNotEmpty) ...[
                  SizedBox(height: m.px(20)),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: m.px(980)),
                    child: Text(
                      item.overview!,
                      style: TextStyle(
                        fontSize: m.px(17),
                        height: 1.5,
                        color: Colors.white.withValues(alpha: 0.78),
                      ),
                    ),
                  ),
                ],
                SizedBox(height: m.px(30)),
                Row(
                  children: [
                    if (!isImage)
                      TvFocusCard(
                        autofocus: true,
                        onTap: preparing ? null : onPlay,
                        radius: m.px(30),
                        child: Container(
                          padding: EdgeInsets.symmetric(
                            horizontal: m.px(28),
                            vertical: m.px(13),
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(m.px(30)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                preparing
                                    ? Icons.hourglass_top_rounded
                                    : Icons.play_arrow_rounded,
                                size: m.px(28),
                                color: Colors.black,
                              ),
                              SizedBox(width: m.px(6)),
                              Text(
                                tr('video.series.play'),
                                style: TextStyle(
                                  fontSize: m.px(18),
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (!isImage) SizedBox(width: m.px(16)),
                    TvFocusCard(
                      onTap: onBack,
                      radius: m.px(30),
                      child: Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: m.px(26),
                          vertical: m.px(13),
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.16),
                          borderRadius: BorderRadius.circular(m.px(30)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.arrow_back,
                              size: m.px(22),
                              color: Colors.white,
                            ),
                            SizedBox(width: m.px(6)),
                            Text(
                              tr('common.back'),
                              style: TextStyle(
                                fontSize: m.px(17),
                                fontWeight: FontWeight.w600,
                                color: Colors.white,
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
    );
  }
}
