import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../core/session.dart';
import '../../music/music_playback.dart';
import '../tv_focus.dart';

/// TV 全屏播放页：左侧黑胶封面，右侧大号滚动歌词，底部进度与控制栏。
///
/// 独立路由 + 自己的键位处理：外壳的 tab / 迷你条在这条路由下面，
/// 返回键只关播放页，不会把焦点带回后面那一层。
class TvMusicPlayerPage extends StatefulWidget {
  const TvMusicPlayerPage({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context, rootNavigator: true).push<void>(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 240),
        pageBuilder: (_, animation, _) => const TvMusicPlayerPage(),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  @override
  State<TvMusicPlayerPage> createState() => _TvMusicPlayerPageState();
}

class _TvMusicPlayerPageState extends State<TvMusicPlayerPage>
    with SingleTickerProviderStateMixin {
  final MusicPlaybackService _service = MusicPlaybackService.instance;
  final ScrollController _lyricsScroll = ScrollController();
  final FocusNode _playFocus = FocusNode(debugLabel: 'tv-player-play');

  late final AnimationController _vinyl = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  );

  String? _trackId;
  int _activeLine = -1;
  bool _playing = false;
  double _lineExtent = 58;

  @override
  void initState() {
    super.initState();
    _trackId = _service.track?.id;
    _activeLine = _service.activeLine;
    _playing = _service.playing;
    if (_playing) _vinyl.repeat();
    _service.addListener(_onService);
  }

  @override
  void dispose() {
    _service.removeListener(_onService);
    _vinyl.dispose();
    _lyricsScroll.dispose();
    _playFocus.dispose();
    super.dispose();
  }

  void _onService() {
    if (!mounted) return;
    var dirty = false;
    final trackId = _service.track?.id;
    if (trackId != _trackId) {
      _trackId = trackId;
      _activeLine = -1;
      dirty = true;
      if (_lyricsScroll.hasClients) _lyricsScroll.jumpTo(0);
    }
    if (_service.playing != _playing) {
      _playing = _service.playing;
      dirty = true;
      if (_playing) {
        _vinyl.repeat();
      } else {
        _vinyl.stop();
      }
    }
    final active = _service.activeLine;
    if (active != _activeLine) {
      _activeLine = active;
      dirty = true;
      _scrollToActive(active);
    }
    if (dirty) setState(() {});
  }

  void _scrollToActive(int active) {
    if (!_lyricsScroll.hasClients || active < 0) return;
    final viewport = _lyricsScroll.position.viewportDimension;
    final target = (active * _lineExtent - viewport / 2 + _lineExtent / 2)
        .clamp(0.0, _lyricsScroll.position.maxScrollExtent);
    _lyricsScroll.animateTo(
      target,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOut,
    );
  }

  static bool _isOk(KeyEvent event) {
    final key = event.logicalKey;
    return key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      if (event is KeyDownEvent) Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      final focus = FocusManager.instance.primaryFocus;
      if (focus != null && focus.context != null) {
        final direction = key == LogicalKeyboardKey.arrowLeft
            ? TraversalDirection.left
            : key == LogicalKeyboardKey.arrowRight
            ? TraversalDirection.right
            : key == LogicalKeyboardKey.arrowUp
            ? TraversalDirection.up
            : TraversalDirection.down;
        focus.focusInDirection(direction);
      }
      return KeyEventResult.handled;
    }
    if (_isOk(event)) {
      if (event is KeyDownEvent) {
        final focus = FocusManager.instance.primaryFocus;
        final focusContext = focus?.context;
        if (focusContext != null) {
          Actions.maybeInvoke(focusContext, const ActivateIntent());
        }
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyDownEvent && _service.hasTrack) _service.toggle();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackNext) {
      if (event is KeyDownEvent && _service.hasTrack) _service.next();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaTrackPrevious) {
      if (event is KeyDownEvent && _service.hasTrack) _service.previous();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final m = TvMetrics.of(width);
    final scheme = Theme.of(context).colorScheme;
    final track = _service.track;
    final bilingual = _service.bilingual;
    _lineExtent = bilingual ? m.px(88) : m.px(60);

    return TvMetricsScope(
      metrics: m,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: const Color(0xFF08090D),
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(-0.65, -0.45),
                radius: 1.25,
                colors: [
                  scheme.primary.withValues(alpha: 0.3),
                  const Color(0xFF08090D),
                ],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                  m.px(36),
                  m.px(24),
                  m.px(36),
                  m.px(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildHeader(m, track),
                    SizedBox(height: m.px(12)),
                    Expanded(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(flex: 4, child: _buildDiscPane(m, track)),
                          SizedBox(width: m.px(36)),
                          Expanded(flex: 6, child: _buildLyricsPane(m)),
                        ],
                      ),
                    ),
                    SizedBox(height: m.px(14)),
                    _buildProgress(m),
                    SizedBox(height: m.px(14)),
                    _buildControls(m),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(TvMetrics m, MusicTrack? track) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      children: [
        Icon(
          Icons.music_note_rounded,
          size: m.px(24),
          color: scheme.primary,
        ),
        SizedBox(width: m.px(10)),
        Text(
          tr('tv.music.nowPlaying'),
          style: TextStyle(
            fontSize: m.px(18),
            fontWeight: FontWeight.w800,
            letterSpacing: 0.5,
            color: scheme.onSurface,
          ),
        ),
        const Spacer(),
        Text(
          track?.album ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.px(14),
            color: Colors.white.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Widget _buildDiscPane(TvMetrics m, MusicTrack? track) {
    final scheme = Theme.of(context).colorScheme;
    final size = m.px(330);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: size * 1.1,
          height: size * 1.1,
          child: Stack(
            alignment: Alignment.center,
            children: [
              RotationTransition(
                turns: _vinyl,
                child: Container(
                  width: size * 1.1,
                  height: size * 1.1,
                  decoration: const BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: SweepGradient(
                      colors: [
                        Color(0xFF1A1A20),
                        Color(0xFF2E2E38),
                        Color(0xFF141418),
                        Color(0xFF2E2E38),
                        Color(0xFF1A1A20),
                      ],
                    ),
                  ),
                ),
              ),
              Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.12),
                    width: m.px(2),
                  ),
                ),
                child: ClipOval(
                  child: NasCoverImage(
                    url: track == null
                        ? null
                        : ApiSession.instance.coverUrl('music', track.id),
                    headers: ApiSession.instance.authHeaders,
                    icon: Icons.music_note_outlined,
                    fallbackText: track?.title,
                    cacheWidth: (size * 2).round(),
                    borderRadius: 0,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(height: m.px(24)),
        Text(
          track?.title ?? tr('tv.music.notPlaying'),
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.px(28),
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
        SizedBox(height: m.px(8)),
        Text(
          [track?.artist ?? '', track?.album ?? '']
              .where((v) => v.trim().isNotEmpty)
              .join(' · '),
          maxLines: 1,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: m.px(16),
            color: Colors.white.withValues(alpha: 0.62),
          ),
        ),
      ],
    );
  }

  Widget _buildLyricsPane(TvMetrics m) {
    final scheme = Theme.of(context).colorScheme;
    final lines = _service.lyrics?.lines ?? const <MusicLyricsLine>[];
    final synced = _service.lyrics?.synced ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(left: m.px(6), bottom: m.px(8)),
          child: Text(
            tr('music.lyrics.title'),
            style: TextStyle(
              fontSize: m.px(16),
              fontWeight: FontWeight.w700,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
        ),
        Expanded(
          child: _service.lyricsLoading
              ? const Center(child: CircularProgressIndicator())
              : lines.isEmpty
              ? Center(
                  child: Text(
                    tr('tv.music.noLyrics'),
                    style: TextStyle(
                      fontSize: m.px(18),
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                )
              : ListView.builder(
                  controller: _lyricsScroll,
                  itemExtent: _lineExtent,
                  itemCount: lines.length,
                  padding: EdgeInsets.symmetric(vertical: m.px(8)),
                  itemBuilder: (context, index) {
                    final line = lines[index];
                    final active = synced && index == _activeLine;
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            line.text.isEmpty ? '♪' : line.text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: m.px(active ? 28 : 23),
                              height: 1.2,
                              fontWeight: active
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: active
                                  ? scheme.primary
                                  : Colors.white.withValues(alpha: 0.62),
                            ),
                          ),
                          if ((line.translation ?? '').isNotEmpty)
                            Text(
                              line.translation!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: m.px(active ? 17 : 15),
                                height: 1.2,
                                color: active
                                    ? scheme.primary.withValues(alpha: 0.78)
                                    : Colors.white.withValues(alpha: 0.4),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildProgress(TvMetrics m) {
    final scheme = Theme.of(context).colorScheme;
    return AnimatedBuilder(
      animation: _service,
      builder: (context, _) {
        final duration = _service.duration.inMilliseconds;
        final ratio = duration <= 0
            ? 0.0
            : (_service.position.inMilliseconds / duration).clamp(0.0, 1.0);
        return Row(
          children: [
            SizedBox(
              width: m.px(64),
              child: Text(
                _fmt(_service.position),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: m.px(13),
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ),
            SizedBox(width: m.px(12)),
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: m.px(5),
                  backgroundColor: Colors.white.withValues(alpha: 0.14),
                  valueColor: AlwaysStoppedAnimation<Color>(scheme.primary),
                ),
              ),
            ),
            SizedBox(width: m.px(12)),
            SizedBox(
              width: m.px(64),
              child: Text(
                _fmt(_service.duration),
                style: TextStyle(
                  fontSize: m.px(13),
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildControls(TvMetrics m) {
    return AnimatedBuilder(
      animation: _service,
      builder: (context, _) {
        final repeatMode = _service.repeatMode;
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _TvPlayerButton(
              icon: Icons.shuffle_rounded,
              size: m.px(52),
              active: _service.shuffle,
              onTap: () => _service.setShuffle(!_service.shuffle),
            ),
            SizedBox(width: m.px(18)),
            _TvPlayerButton(
              icon: Icons.skip_previous_rounded,
              size: m.px(62),
              onTap: _service.hasTrack ? _service.previous : null,
            ),
            SizedBox(width: m.px(18)),
            _TvPlayerButton(
              icon: _service.playing
                  ? Icons.pause_rounded
                  : Icons.play_arrow_rounded,
              size: m.px(82),
              primary: true,
              focusNode: _playFocus,
              autofocus: true,
              onTap: _service.hasTrack ? _service.toggle : null,
            ),
            SizedBox(width: m.px(18)),
            _TvPlayerButton(
              icon: Icons.skip_next_rounded,
              size: m.px(62),
              onTap: _service.hasTrack ? _service.next : null,
            ),
            SizedBox(width: m.px(18)),
            _TvPlayerButton(
              icon: switch (repeatMode) {
                MusicRepeatMode.one => Icons.repeat_one_rounded,
                _ => Icons.repeat_rounded,
              },
              size: m.px(52),
              active: repeatMode != MusicRepeatMode.off,
              onTap: _service.cycleRepeatMode,
            ),
          ],
        );
      },
    );
  }

  static String _fmt(Duration value) {
    final total = value.inSeconds;
    final minutes = (total ~/ 60).toString().padLeft(2, '0');
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _TvPlayerButton extends StatelessWidget {
  const _TvPlayerButton({
    required this.icon,
    required this.size,
    required this.onTap,
    this.primary = false,
    this.active = false,
    this.focusNode,
    this.autofocus = false,
  });

  final IconData icon;
  final double size;
  final VoidCallback? onTap;
  final bool primary;
  final bool active;
  final FocusNode? focusNode;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return TvFocusCard(
      focusNode: focusNode,
      autofocus: autofocus,
      onTap: onTap,
      radius: size / 2,
      focusScale: 1.1,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: primary
              ? (enabled ? scheme.primary : scheme.primary.withValues(alpha: 0.4))
              : Colors.white.withValues(
                  alpha: active ? 0.22 : (enabled ? 0.1 : 0.04),
                ),
          border: Border.all(
            color: active
                ? scheme.primary.withValues(alpha: 0.7)
                : Colors.transparent,
            width: m.px(2),
          ),
        ),
        child: Icon(
          icon,
          size: size * 0.44,
          color: primary
              ? scheme.onPrimary
              : Colors.white.withValues(alpha: enabled ? 0.92 : 0.35),
        ),
      ),
    );
  }
}
