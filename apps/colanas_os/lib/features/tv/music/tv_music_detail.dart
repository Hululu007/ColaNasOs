import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../core/session.dart';
import '../../music/music_playback.dart';
import '../tv_focus.dart';
import 'tv_music_player.dart';

enum TvMusicDetailKind { favorites, playlist, collection, album, artist }

/// 打开详情页需要的全部信息。歌曲列表用 Future 传入，页面挂载后再拉，
/// 避免从首页点进专辑时卡住焦点动画。
class TvMusicDetailSpec {
  const TvMusicDetailSpec({
    required this.kind,
    required this.title,
    this.subtitle,
    this.year,
    this.coverTrackId,
    this.tracks,
    this.sampleTracks = const <MusicTrack>[],
    this.trackCountHint,
    this.durationHint,
  });

  final TvMusicDetailKind kind;
  final String title;
  final String? subtitle;
  final int? year;
  final String? coverTrackId;
  final Future<List<MusicTrack>>? tracks;

  /// 聚合接口已经拿到的曲目：列表接口因账号目录权限返回空时兜底，
  /// 避免详情页明明有封面/曲目数却显示「没有匹配的曲目」。
  final List<MusicTrack> sampleTracks;
  final int? trackCountHint;
  final int? durationHint;
}

enum _DrawerMode { none, actions, playlists }

/// 歌单 / 合集 / 专辑 / 歌手详情：左 35% 信息与操作，右 65% 曲目列表。
///
/// 曲目列表用 `SingleChildScrollView + Column` 全量构建（不用懒加载 ListView），
/// 保证遥控器方向键能走到还没出现在视口里的曲目。
class TvMusicDetailPage extends StatefulWidget {
  const TvMusicDetailPage({
    super.key,
    required this.spec,
    required this.onOpenArtist,
  });

  final TvMusicDetailSpec spec;

  /// 抽屉里的「查看歌手」把当前详情替换成该歌手详情。
  final void Function(String artist) onOpenArtist;

  @override
  State<TvMusicDetailPage> createState() => TvMusicDetailPageState();
}

class TvMusicDetailPageState extends State<TvMusicDetailPage> {
  final MusicPlaybackService _service = MusicPlaybackService.instance;
  final FocusNode _playAllFocus = FocusNode(debugLabel: 'tv-music-play-all');
  final FocusNode _shuffleFocus = FocusNode(debugLabel: 'tv-music-shuffle');
  final FocusNode _favoriteFocus = FocusNode(debugLabel: 'tv-music-favorite');
  final FocusNode _drawerAddFocus = FocusNode(debugLabel: 'tv-music-drawer-add');
  final FocusNode _drawerArtistFocus = FocusNode(
    debugLabel: 'tv-music-drawer-artist',
  );
  final FocusNode _drawerModeFocus = FocusNode(debugLabel: 'tv-music-drawer-mode');
  final FocusNode _drawerShuffleFocus = FocusNode(
    debugLabel: 'tv-music-drawer-shuffle',
  );
  final Map<int, FocusNode> _trackNodes = <int, FocusNode>{};
  final Map<int, FocusNode> _playlistNodes = <int, FocusNode>{};

  List<MusicTrack> _tracks = const <MusicTrack>[];
  Set<String> _favorites = <String>{};
  bool _loading = true;
  bool _favoriteBusy = false;
  String? _error;
  String? _playingId;
  int _focusedTrack = 0;

  _DrawerMode _drawer = _DrawerMode.none;
  List<MusicPlaylist> _playlists = const <MusicPlaylist>[];
  bool _loadingPlaylists = false;
  String? _toast;
  Timer? _toastTimer;

  FocusNode _trackNode(int index) => _trackNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'tv-music-track-$index'),
  );

  FocusNode _playlistNode(int index) => _playlistNodes.putIfAbsent(
    index,
    () => FocusNode(debugLabel: 'tv-music-playlist-$index'),
  );

  @override
  void initState() {
    super.initState();
    _playingId = _service.track?.id;
    _service.addListener(_onPlayback);
    _load();
    // 不能只靠 autofocus：从首页卡片进入详情时原焦点节点被卸载，
    // 根 FocusScope 可能把焦点交给顶部 tab，autofocus 不一定再生效。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _playAllFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(TvMusicDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.spec, widget.spec)) {
      _focusedTrack = 0;
      _drawer = _DrawerMode.none;
      _tracks = const <MusicTrack>[];
      _loading = true;
      _error = null;
      _load();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _playAllFocus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _service.removeListener(_onPlayback);
    _toastTimer?.cancel();
    _playAllFocus.dispose();
    _shuffleFocus.dispose();
    _favoriteFocus.dispose();
    _drawerAddFocus.dispose();
    _drawerArtistFocus.dispose();
    _drawerModeFocus.dispose();
    _drawerShuffleFocus.dispose();
    for (final node in _trackNodes.values) {
      node.dispose();
    }
    for (final node in _playlistNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _onPlayback() {
    final id = _service.track?.id;
    if (id != _playingId && mounted) {
      setState(() => _playingId = id);
    }
  }

  Future<void> _load() async {
    final spec = widget.spec;
    List<MusicTrack> tracks = const <MusicTrack>[];
    String? error;
    try {
      tracks = List<MusicTrack>.from(
        await (spec.tracks ?? Future<List<MusicTrack>>.value(const [])),
      );
      if (tracks.isEmpty) tracks = List<MusicTrack>.from(spec.sampleTracks);
      if (spec.kind == TvMusicDetailKind.album ||
          spec.kind == TvMusicDetailKind.artist) {
        tracks.sort((a, b) {
          final album = (a.album ?? '').compareTo(b.album ?? '');
          if (album != 0) return album;
          final no = (a.trackNo ?? 0).compareTo(b.trackNo ?? 0);
          if (no != 0) return no;
          return a.title.compareTo(b.title);
        });
      }
    } catch (e) {
      error = '$e';
    }

    var favorites = <String>{};
    try {
      final raw = await ApiSession.instance.client.musicFavoriteIds();
      favorites = ((raw['ids'] as List<dynamic>?) ?? const [])
          .cast<String>()
          .toSet();
    } catch (_) {
      // 收藏态拿不到不影响列表浏览。
    }

    if (!mounted || !identical(widget.spec, spec)) return;
    setState(() {
      _tracks = tracks;
      _favorites = favorites;
      _loading = false;
      _error = error;
    });
    // 曲目拉回来后按钮才从 disabled 变成可聚焦，必须在这里再请求一次焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _drawer == _DrawerMode.none) {
        _playAllFocus.requestFocus();
      }
    });
  }

  /// 分区返回键先问这里：抽屉先关抽屉，否则由分区关闭详情。
  bool handleBack() {
    if (_drawer == _DrawerMode.playlists) {
      setState(() => _drawer = _DrawerMode.actions);
      _focusDrawerFirst();
      return true;
    }
    if (_drawer == _DrawerMode.actions) {
      _closeDrawer();
      return true;
    }
    return false;
  }

  MusicTrack? get _currentTrack {
    if (_tracks.isEmpty) return null;
    return _tracks[_focusedTrack.clamp(0, _tracks.length - 1)];
  }

  String? get _artistName {
    final artist = _currentTrack?.artist?.trim();
    if (artist != null && artist.isNotEmpty) return artist;
    if (widget.spec.kind == TvMusicDetailKind.artist) return widget.spec.title;
    return null;
  }

  int get _totalDurationMs {
    if (_tracks.isEmpty) return widget.spec.durationHint ?? 0;
    return _tracks.fold<int>(0, (sum, t) => sum + (t.durationMs ?? 0));
  }

  void _playAll() {
    if (_tracks.isEmpty) return;
    MusicPlaybackService.instance.playQueue(_tracks, 0);
    _showToast(tr('music.play'));
  }

  Future<void> _shufflePlay() async {
    if (_tracks.isEmpty) return;
    await MusicPlaybackService.instance.setShuffle(true);
    final start = _tracks.length == 1
        ? 0
        : (DateTime.now().microsecondsSinceEpoch % _tracks.length);
    MusicPlaybackService.instance.playQueue(_tracks, start);
    _showToast(tr('tv.music.shuffle'));
  }

  Future<void> _toggleFavoriteAll() async {
    if (_tracks.isEmpty || _favoriteBusy) return;
    final allFavorite = _tracks.every((t) => _favorites.contains(t.id));
    final target = !allFavorite;
    setState(() => _favoriteBusy = true);
    final client = ApiSession.instance.client;
    for (final track in _tracks) {
      try {
        await client.musicFavorite(
          body: MusicFavoriteBody(id: track.id, favorite: target),
        );
      } catch (_) {
        // 单曲失败不阻断整批；最后按实际成功的数量提示。
      }
    }
    if (!mounted) return;
    setState(() {
      _favoriteBusy = false;
      if (target) {
        _favorites = {..._favorites, ..._tracks.map((t) => t.id)};
      } else {
        _favorites = _favorites.difference(_tracks.map((t) => t.id).toSet());
      }
    });
    _showToast(
      tr(
        target ? 'tv.music.favoriteAllDone' : 'tv.music.unfavoriteAllDone',
        {'n': '${_tracks.length}'},
      ),
    );
  }

  void _showToast(String message) {
    _toastTimer?.cancel();
    setState(() => _toast = message);
    _toastTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  // ---------------------------------------------------------------------------
  // 操作抽屉
  // ---------------------------------------------------------------------------

  void _openDrawer({int? trackIndex}) {
    if (trackIndex != null) {
      _focusedTrack = trackIndex.clamp(0, _tracks.length - 1);
    }
    setState(() => _drawer = _DrawerMode.actions);
    _focusDrawerFirst();
  }

  void _focusDrawerFirst() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_drawer == _DrawerMode.playlists) {
        _playlistNode(0).requestFocus();
      } else if (_drawer == _DrawerMode.actions) {
        _drawerAddFocus.requestFocus();
      }
    });
  }

  void _closeDrawer() {
    setState(() => _drawer = _DrawerMode.none);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _tracks.isEmpty ? _playAllFocus : _trackNode(_focusedTrack);
      node.requestFocus();
    });
  }

  Future<void> _openPlaylistPicker() async {
    setState(() => _drawer = _DrawerMode.playlists);
    _focusDrawerFirst();
    if (_playlists.isNotEmpty || _loadingPlaylists) return;
    setState(() => _loadingPlaylists = true);
    try {
      final res = await ApiSession.instance.client.musicPlaylistList();
      if (!mounted) return;
      setState(() => _playlists = res.items);
    } catch (_) {
      if (!mounted) return;
      setState(() => _playlists = const <MusicPlaylist>[]);
    } finally {
      if (mounted) setState(() => _loadingPlaylists = false);
    }
  }

  Future<void> _addToPlaylist(MusicPlaylist playlist) async {
    final track = _currentTrack;
    if (track == null) return;
    try {
      await ApiSession.instance.client.musicPlaylistAdd(
        body: MusicPlaylistMembersBody(
          playlistId: playlist.id,
          trackIds: <String>[track.id],
        ),
      );
      if (!mounted) return;
      _showToast(tr('tv.music.addedToPlaylist', {'name': playlist.name}));
      _closeDrawer();
    } catch (e) {
      if (!mounted) return;
      _showToast(tr('tv.music.addFailed', {'error': '$e'}));
    }
  }

  void _cycleRepeatMode() {
    MusicPlaybackService.instance.cycleRepeatMode();
    setState(() {});
  }

  Future<void> _toggleShuffle() async {
    await MusicPlaybackService.instance.setShuffle(
      !MusicPlaybackService.instance.shuffle,
    );
    if (mounted) setState(() {});
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final focus = FocusManager.instance.primaryFocus;
    if (key == LogicalKeyboardKey.arrowRight &&
        (focus == _playAllFocus ||
            focus == _shuffleFocus ||
            focus == _favoriteFocus)) {
      // 左栏按钮按右键直接进右侧曲目列表，避免几何遍历落到下面的迷你条。
      if (_tracks.isNotEmpty) {
        _trackNode(0).requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft &&
        _tracks.isNotEmpty &&
        focus != null &&
        _trackNodes.containsValue(focus)) {
      _playAllFocus.requestFocus();
      return KeyEventResult.handled;
    }
    if (_drawer != _DrawerMode.none) {
      // 抽屉在右侧，左键收起，避免焦点溜回下面的曲目列表。
      if (key == LogicalKeyboardKey.arrowLeft) {
        _closeDrawer();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.contextMenu ||
        key == LogicalKeyboardKey.f10 ||
        key == LogicalKeyboardKey.keyM) {
      _openDrawer(trackIndex: _tracks.isEmpty ? null : _focusedTrack);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final leftWidth = (constraints.maxWidth * 0.35).clamp(
                m.px(300),
                m.px(620),
              );
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: leftWidth, child: _buildLeftPane(m)),
                  SizedBox(width: m.px(22)),
                  Expanded(child: _buildTrackPane(m)),
                ],
              );
            },
          ),
          if (_drawer != _DrawerMode.none) _buildDrawer(m),
          if (_toast != null) _buildToast(m),
        ],
      ),
    );
  }

  Widget _buildLeftPane(TvMetrics m) {
    final scheme = Theme.of(context).colorScheme;
    final coverSize = m.px(250);
    final count = _tracks.isNotEmpty
        ? _tracks.length
        : (widget.spec.trackCountHint ?? 0);
    final duration = _totalDurationMs;
    final favoriteAll =
        _tracks.isNotEmpty && _tracks.every((t) => _favorites.contains(t.id));
    final meta = <String>[
      if (widget.spec.year != null)
        tr('tv.music.year', {'year': '${widget.spec.year}'}),
      if (count > 0) tr('tv.music.tracks', {'n': '$count'}),
      if (duration > 0) formatDurationMs(duration),
    ].join(' · ');

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Align(
            alignment: Alignment.centerLeft,
            child: SizedBox(
              width: coverSize,
              height: coverSize,
              child: NasCoverImage(
                url: widget.spec.coverTrackId == null
                    ? null
                    : ApiSession.instance.coverUrl(
                        'music',
                        widget.spec.coverTrackId!,
                      ),
                headers: ApiSession.instance.authHeaders,
                icon: Icons.album_outlined,
                fallbackText: widget.spec.title,
                cacheWidth: (coverSize * 2).round(),
                borderRadius: m.px(18),
              ),
            ),
          ),
          SizedBox(height: m.px(18)),
          Text(
            widget.spec.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(30),
              height: 1.15,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          if ((widget.spec.subtitle ?? '').trim().isNotEmpty) ...[
            SizedBox(height: m.px(6)),
            Text(
              widget.spec.subtitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.px(17),
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          if (meta.isNotEmpty) ...[
            SizedBox(height: m.px(6)),
            Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.px(14),
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          SizedBox(height: m.px(20)),
          _TvDetailButton(
            label: tr('tv.music.playAll'),
            icon: Icons.play_arrow_rounded,
            focusNode: _playAllFocus,
            autofocus: true,
            primary: true,
            onTap: _playAll,
          ),
          SizedBox(height: m.px(12)),
          Row(
            children: [
              Expanded(
                child: _TvDetailButton(
                  label: tr('tv.music.shuffle'),
                  icon: Icons.shuffle_rounded,
                  focusNode: _shuffleFocus,
                  onTap: _shufflePlay,
                ),
              ),
              SizedBox(width: m.px(12)),
              Expanded(
                child: _TvDetailButton(
                  label: favoriteAll
                      ? tr('tv.music.favorited')
                      : tr('tv.music.favorite'),
                  icon: favoriteAll
                      ? Icons.favorite_rounded
                      : Icons.favorite_border_rounded,
                  focusNode: _favoriteFocus,
                  busy: _favoriteBusy,
                  onTap: _toggleFavoriteAll,
                ),
              ),
            ],
          ),
          SizedBox(height: m.px(16)),
          Text(
            tr('tv.music.menuHint'),
            maxLines: 2,
            style: TextStyle(
              fontSize: m.px(12),
              height: 1.4,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTrackPane(TvMetrics m) {
    final scheme = Theme.of(context).colorScheme;
    final count = _tracks.isNotEmpty
        ? _tracks.length
        : (widget.spec.trackCountHint ?? 0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TvSectionHeader(
          title: tr('music.nav.songs'),
          trailing: Text(
            tr('tv.music.tracks', {'n': '$count'}),
            style: TextStyle(
              fontSize: m.px(14),
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? NasEmptyState(
                  title: tr('common.error'),
                  message: _error,
                  icon: Icons.error_outline,
                )
              : _tracks.isEmpty
              ? NasEmptyState(
                  title: tr('ui.music.013'),
                  icon: Icons.music_note_outlined,
                )
              : SingleChildScrollView(
                  padding: EdgeInsets.only(bottom: m.px(16)),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < _tracks.length; i += 1) ...[
                        if (i > 0) SizedBox(height: m.px(6)),
                        _TvDetailTrackRow(
                          index: i,
                          track: _tracks[i],
                          playing: _tracks[i].id == _playingId,
                          focusNode: _trackNode(i),
                          onFocused: () => _focusedTrack = i,
                          onTap: () {
                            _focusedTrack = i;
                            if (_tracks[i].id == _playingId) {
                              // 再点一次正在播放的曲目 = 进全屏播放页。
                              TvMusicPlayerPage.open(context);
                            } else {
                              MusicPlaybackService.instance.playQueue(_tracks, i);
                            }
                          },
                          onLongPress: () => _openDrawer(trackIndex: i),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildDrawer(TvMetrics m) {
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      width: m.px(420),
      child: Material(
        color: context.nasStyle.panelColor,
        elevation: 18,
        borderRadius: BorderRadius.circular(m.px(18)),
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            m.px(18),
            m.px(16),
            m.px(18),
            m.px(16),
          ),
          child: _drawer == _DrawerMode.playlists
              ? _buildPlaylistPicker(m)
              : _buildActions(m),
        ),
      ),
    );
  }

  Widget _buildActions(TvMetrics m) {
    final scheme = Theme.of(context).colorScheme;
    final artist = _artistName;
    final repeat = _service.repeatMode;
    final repeatLabel = switch (repeat) {
      MusicRepeatMode.off => tr('music.play.repeatOff'),
      MusicRepeatMode.all => tr('music.play.repeatAll'),
      MusicRepeatMode.one => tr('music.play.repeatOne'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                tr('music.queue.title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: m.px(20),
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                ),
              ),
            ),
            Text(
              _currentTrack == null ? '' : _currentTrack!.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.px(12),
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        SizedBox(height: m.px(16)),
        _TvDrawerItem(
          label: tr('tv.music.addToPlaylist'),
          icon: Icons.playlist_add_rounded,
          focusNode: _drawerAddFocus,
          onTap: _tracks.isEmpty ? null : _openPlaylistPicker,
        ),
        SizedBox(height: m.px(10)),
        _TvDrawerItem(
          label: tr('tv.music.viewArtist'),
          icon: Icons.person_outline_rounded,
          focusNode: _drawerArtistFocus,
          onTap: artist == null ? null : () => widget.onOpenArtist(artist),
        ),
        SizedBox(height: m.px(10)),
        _TvDrawerItem(
          label: '${tr('tv.music.playMode')} · $repeatLabel',
          icon: Icons.repeat_rounded,
          focusNode: _drawerModeFocus,
          onTap: _cycleRepeatMode,
        ),
        SizedBox(height: m.px(10)),
        _TvDrawerItem(
          label:
              '${tr('music.play.shuffle')} · ${_service.shuffle ? 'ON' : 'OFF'}',
          icon: Icons.shuffle_rounded,
          focusNode: _drawerShuffleFocus,
          active: _service.shuffle,
          onTap: _toggleShuffle,
        ),
        const Spacer(),
        Text(
          tr('tv.music.menuHint'),
          style: TextStyle(
            fontSize: m.px(12),
            height: 1.4,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _buildPlaylistPicker(TvMetrics m) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          tr('tv.music.addToPlaylist'),
          style: TextStyle(
            fontSize: m.px(20),
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
        SizedBox(height: m.px(12)),
        Expanded(
          child: _loadingPlaylists
              ? const Center(child: CircularProgressIndicator())
              : _playlists.isEmpty
              ? NasEmptyState(
                  title: tr('ui.music.006'),
                  icon: Icons.playlist_add,
                )
              : SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (var i = 0; i < _playlists.length; i += 1) ...[
                        if (i > 0) SizedBox(height: m.px(8)),
                        _TvDrawerItem(
                          label: _playlists[i].name,
                          subtitle: tr('tv.music.tracks', {
                            'n': '${_playlists[i].tracks}',
                          }),
                          icon: Icons.queue_music_rounded,
                          focusNode: _playlistNode(i),
                          onTap: () => _addToPlaylist(_playlists[i]),
                        ),
                      ],
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildToast(TvMetrics m) {
    return Positioned(
      left: 0,
      right: 0,
      bottom: m.px(16),
      child: IgnorePointer(
        child: Center(
          child: Material(
            color: Colors.black.withValues(alpha: 0.78),
            borderRadius: BorderRadius.circular(m.px(20)),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: m.px(20),
                vertical: m.px(10),
              ),
              child: Text(
                _toast!,
                style: TextStyle(
                  fontSize: m.px(14),
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TvDetailButton extends StatelessWidget {
  const _TvDetailButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.focusNode,
    this.autofocus = false,
    this.primary = false,
    this.busy = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool primary;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return TvFocusCard(
      focusNode: focusNode,
      autofocus: autofocus,
      onTap: onTap,
      radius: m.px(14),
      focusScale: 1.04,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: m.px(16),
          vertical: m.px(13),
        ),
        decoration: BoxDecoration(
          color: primary
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: enabled ? 0.1 : 0.05),
          borderRadius: BorderRadius.circular(m.px(14)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              busy ? Icons.hourglass_top_rounded : icon,
              size: m.px(22),
              color: primary ? scheme.onPrimary : scheme.onSurface,
            ),
            SizedBox(width: m.px(6)),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: m.px(16),
                  fontWeight: FontWeight.w700,
                  color: primary ? scheme.onPrimary : scheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvDrawerItem extends StatelessWidget {
  const _TvDrawerItem({
    required this.label,
    required this.icon,
    required this.onTap,
    this.subtitle,
    this.focusNode,
    this.active = false,
  });

  final String label;
  final String? subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final FocusNode? focusNode;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    return TvFocusCard(
      focusNode: focusNode,
      onTap: onTap,
      radius: m.px(12),
      focusScale: 1.02,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: m.px(14),
          vertical: m.px(12),
        ),
        decoration: BoxDecoration(
          color: scheme.onSurface.withValues(alpha: enabled ? 0.07 : 0.03),
          borderRadius: BorderRadius.circular(m.px(12)),
          border: Border.all(
            color: active
                ? scheme.primary.withValues(alpha: 0.6)
                : Colors.transparent,
          ),
        ),
        child: Row(
          children: [
            Icon(
              icon,
              size: m.px(22),
              color: enabled ? scheme.primary : scheme.onSurfaceVariant,
            ),
            SizedBox(width: m.px(12)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: m.px(16),
                      fontWeight: FontWeight.w600,
                      color: enabled
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                  if (subtitle != null) ...[
                    SizedBox(height: m.px(2)),
                    Text(
                      subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: m.px(12),
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvDetailTrackRow extends StatelessWidget {
  const _TvDetailTrackRow({
    required this.index,
    required this.track,
    required this.playing,
    required this.onFocused,
    required this.onTap,
    required this.onLongPress,
    this.focusNode,
  });

  final int index;
  final MusicTrack track;
  final bool playing;
  final VoidCallback onFocused;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final quality = _qualityLabel(track);
    return TvFocusCard(
      focusNode: focusNode,
      onTap: onTap,
      onLongPress: onLongPress,
      onFocused: onFocused,
      radius: m.px(12),
      focusScale: 1.012,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: m.px(14),
          vertical: m.px(11),
        ),
        decoration: BoxDecoration(
          color: playing
              ? scheme.primary.withValues(alpha: 0.16)
              : scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(m.px(12)),
        ),
        child: Row(
          children: [
            SizedBox(
              width: m.px(42),
              child: playing
                  ? Icon(
                      Icons.graphic_eq_rounded,
                      size: m.px(18),
                      color: scheme.primary,
                    )
                  : Text(
                      '${index + 1}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: m.px(14),
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    track.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: m.px(17),
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurface,
                    ),
                  ),
                  if ((track.artist ?? '').trim().isNotEmpty) ...[
                    SizedBox(height: m.px(2)),
                    Text(
                      track.artist!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: m.px(12),
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (quality.isNotEmpty) ...[
              SizedBox(width: m.px(10)),
              Container(
                padding: EdgeInsets.symmetric(
                  horizontal: m.px(7),
                  vertical: m.px(2),
                ),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(m.px(6)),
                  border: Border.all(
                    color: scheme.primary.withValues(alpha: 0.38),
                  ),
                ),
                child: Text(
                  quality,
                  style: TextStyle(
                    fontSize: m.px(10),
                    fontWeight: FontWeight.w700,
                    color: scheme.primary,
                  ),
                ),
              ),
            ],
            SizedBox(width: m.px(14)),
            Text(
              formatDurationMs(track.durationMs ?? 0),
              style: TextStyle(
                fontSize: m.px(13),
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _qualityLabel(MusicTrack track) {
  final codec = (track.codec ?? '').toUpperCase();
  final bitrate = track.bitrate ?? 0;
  if (codec.contains('DSD')) return 'DSD';
  if (codec.contains('FLAC') ||
      codec.contains('ALAC') ||
      codec.contains('APE') ||
      bitrate >= 900000) {
    return 'FLAC';
  }
  if (bitrate > 0) return '${(bitrate / 1000).round()}kbps';
  return codec;
}
