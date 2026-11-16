import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../../core/session.dart';
import '../../music/music_playback.dart';
import '../tv_focus.dart';
import 'tv_music_detail.dart';

/// 歌单 / 合集统一条目：TV 首页一张卡同时承载两种来源。
class TvPlaylistEntry {
  const TvPlaylistEntry({
    required this.id,
    required this.name,
    required this.isCollection,
    required this.tracks,
    required this.coverTrackId,
    required this.coverTrackIds,
  });

  final String id;
  final String name;

  /// `true` = 合集，`false` = 歌单。
  final bool isCollection;
  final int tracks;
  final String? coverTrackId;

  /// 拼图封面用的代表曲目（最多 4 个）。
  final List<String?> coverTrackIds;
}

/// TV 首页的专辑条目。首页的「最近播放 / 常听 / 最新添加」都由曲目在客户端聚合。
class TvMusicAlbumEntry {
  const TvMusicAlbumEntry({
    required this.name,
    required this.artist,
    required this.year,
    required this.tracks,
    required this.durationMs,
    required this.coverTrackId,
    this.sampleTracks = const <MusicTrack>[],
  });

  final String name;
  final String? artist;
  final int? year;
  final int tracks;
  final int durationMs;
  final String? coverTrackId;

  /// 聚合时的曲目样本，详情页在列表接口为空时兜底。
  final List<MusicTrack> sampleTracks;
}

/// TV 音乐首页：顶部功能瓷片 + 竖向排列的横向泳道。
///
/// 上/下键由本组件自己处理：切行时按「每条泳道最后停留的列」定位，
/// 这样从「最新专辑」第 8 张往下再回来，仍然停在原来那张上。
/// 首行 ↑ / 末行 ↓ 返回 [KeyEventResult.ignored]，交给外壳去顶部 tab / 迷你条。
class TvMusicHome extends StatefulWidget {
  const TvMusicHome({
    super.key,
    required this.favorites,
    required this.playlists,
    required this.recentAlbums,
    required this.topAlbums,
    required this.newestAlbums,
    required this.artists,
    this.artistSamples = const <String, List<MusicTrack>>{},
    required this.onOpenDetail,
    required this.onOpenAllArtists,
    this.firstFocusNode,
  });

  final List<MusicTrack> favorites;
  final List<TvPlaylistEntry> playlists;
  final List<TvMusicAlbumEntry> recentAlbums;
  final List<TvMusicAlbumEntry> topAlbums;
  final List<TvMusicAlbumEntry> newestAlbums;
  final List<MusicArtist> artists;
  final Map<String, List<MusicTrack>> artistSamples;
  final void Function(TvMusicDetailSpec spec) onOpenDetail;
  final VoidCallback onOpenAllArtists;
  final FocusNode? firstFocusNode;

  @override
  State<TvMusicHome> createState() => _TvMusicHomeState();
}

class _TvLaneInfo {
  const _TvLaneInfo(this.id, this.count);

  final String id;
  final int count;
}

class _TvMusicHomeState extends State<TvMusicHome> {
  static const String _tiles = 'tiles';
  static const String _playlistLane = 'playlists';
  static const String _recentLane = 'recent';
  static const String _topLane = 'top';
  static const String _newestLane = 'newest';
  static const String _artistLane = 'artists';

  final Map<String, FocusNode> _nodes = <String, FocusNode>{};
  final Map<String, int> _lastIndex = <String, int>{};
  final FocusNode _ownedFirstFocus = FocusNode(debugLabel: 'tv-music-first');

  List<_TvLaneInfo> _lanes = const <_TvLaneInfo>[];
  String? _focusedLane;
  String? _albumBackdrop;
  bool _shuffling = false;

  FocusNode get _firstFocus => widget.firstFocusNode ?? _ownedFirstFocus;

  @override
  void initState() {
    super.initState();
    // 外壳会把内容区首焦点 request 到这个节点；先登记，避免首次按下键时找不到。
    _nodes['$_tiles:0'] = _firstFocus;
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      if (identical(node, widget.firstFocusNode)) continue;
      if (identical(node, _ownedFirstFocus)) continue;
      node.dispose();
    }
    _ownedFirstFocus.dispose();
    super.dispose();
  }

  FocusNode _node(String lane, int index) {
    final key = '$lane:$index';
    if (lane == _tiles && index == 0) return _firstFocus;
    return _nodes.putIfAbsent(
      key,
      () => FocusNode(debugLabel: 'tv-music-$key'),
    );
  }

  void _remember(String lane, int index, {String? coverTrackId}) {
    final laneChanged = _focusedLane != lane;
    _focusedLane = lane;
    _lastIndex[lane] = index;
    if (lane == _newestLane && coverTrackId != null) {
      _albumBackdrop = coverTrackId;
    }
    if (laneChanged || lane == _newestLane) {
      if (mounted) setState(() {});
    }
  }

  static bool _isUp(KeyEvent event) =>
      event.logicalKey == LogicalKeyboardKey.arrowUp;

  static bool _isDown(KeyEvent event) =>
      event.logicalKey == LogicalKeyboardKey.arrowDown;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final up = _isUp(event);
    final down = _isDown(event);
    if (!up && !down) return KeyEventResult.ignored;

    final currentLane = _focusedLane;
    if (currentLane == null) return KeyEventResult.ignored;
    final laneIndex = _lanes.indexWhere((lane) => lane.id == currentLane);
    if (laneIndex < 0) return KeyEventResult.ignored;
    final targetIndex = laneIndex + (down ? 1 : -1);
    // 走到边界就交回外壳：↑ 回顶部 tab，↓ 去迷你播放条。
    if (targetIndex < 0 || targetIndex >= _lanes.length) {
      return KeyEventResult.ignored;
    }
    final target = _lanes[targetIndex];
    if (target.count <= 0) return KeyEventResult.ignored;
    final remember = _lastIndex[target.id] ?? 0;
    final index = remember.clamp(0, target.count - 1);
    final targetNode = _node(target.id, index);
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

  Future<void> _shuffleAll() async {
    if (_shuffling) return;
    setState(() => _shuffling = true);
    try {
      final res = await ApiSession.instance.client.musicList(limit: 200);
      var tracks = res.items;
      if (tracks.isEmpty) {
        // 账号目录权限较严时 /music/list 可能为空，退回自动歌单里的曲目。
        final auto = await ApiSession.instance.client.musicAutoPlaylist(
          kind: 'recent_added',
          limit: 200,
        );
        tracks = auto.items;
      }
      if (tracks.isEmpty) return;
      await MusicPlaybackService.instance.setShuffle(true);
      MusicPlaybackService.instance.playQueue(
        tracks,
        math.Random().nextInt(tracks.length),
      );
    } catch (_) {
      // 拉列表失败就保持原状，不打断当前播放。
    } finally {
      if (mounted) setState(() => _shuffling = false);
    }
  }

  void _focusPlaylistLane() {
    final node = _node(_playlistLane, 0);
    node.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final lanes = <_TvLaneInfo>[
      const _TvLaneInfo(_tiles, 4),
      if (widget.playlists.isNotEmpty)
        _TvLaneInfo(_playlistLane, widget.playlists.length),
      if (widget.recentAlbums.isNotEmpty)
        _TvLaneInfo(_recentLane, widget.recentAlbums.length),
      if (widget.topAlbums.isNotEmpty)
        _TvLaneInfo(_topLane, widget.topAlbums.length),
      if (widget.newestAlbums.isNotEmpty)
        _TvLaneInfo(_newestLane, widget.newestAlbums.length),
      if (widget.artists.isNotEmpty)
        _TvLaneInfo(_artistLane, widget.artists.length),
    ];
    _lanes = lanes;

    final rows = <Widget>[];
    rows.add(_tilesRow(m));

    if (widget.playlists.isNotEmpty) {
      rows.add(
        TvCardRow(
          title: tr('tv.music.playlists'),
          trailing: Text(
            tr('tv.music.tracks', {'n': '${widget.playlists.length}'}),
            style: TextStyle(
              fontSize: m.px(14),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          children: [
            for (var i = 0; i < widget.playlists.length; i += 1)
              _TvPlaylistCard(
                entry: widget.playlists[i],
                focusNode: _node(_playlistLane, i),
                onFocused: () => _remember(_playlistLane, i),
                onTap: () => _openPlaylist(widget.playlists[i]),
              ),
          ],
        ),
      );
    }

    if (widget.recentAlbums.isNotEmpty) {
      rows.add(
        _albumRow(
          m,
          laneId: _recentLane,
          title: tr('tv.music.recentAlbums'),
          albums: widget.recentAlbums,
        ),
      );
    }
    if (widget.topAlbums.isNotEmpty) {
      rows.add(
        _albumRow(
          m,
          laneId: _topLane,
          title: tr('tv.music.topAlbums'),
          albums: widget.topAlbums,
        ),
      );
    }
    if (widget.newestAlbums.isNotEmpty) {
      rows.add(
        _albumRow(
          m,
          laneId: _newestLane,
          title: tr('tv.music.newestAlbums'),
          albums: widget.newestAlbums,
        ),
      );
    }
    if (widget.artists.isNotEmpty) {
      rows.add(
        TvCardRow(
          title: tr('tv.music.artists'),
          children: [
            for (var i = 0; i < widget.artists.length; i += 1)
              _TvArtistCard(
                artist: widget.artists[i],
                focusNode: _node(_artistLane, i),
                onFocused: () => _remember(_artistLane, i),
                onTap: () => _openArtist(widget.artists[i]),
              ),
          ],
        ),
      );
    }

    if (rows.length <= 1) {
      return NasEmptyState(
        title: tr('music.nav.empty'),
        icon: Icons.music_note_outlined,
      );
    }

    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildBackdrop(m),
          Positioned.fill(
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
          ),
        ],
      ),
    );
  }

  Widget _tilesRow(TvMetrics m) {
    final tiles = <Widget>[
      _TvFeatureTile(
        title: tr('tv.music.favorites'),
        subtitle: tr('tv.music.tracks', {'n': '${widget.favorites.length}'}),
        icon: Icons.favorite_rounded,
        accent: const Color(0xFFE84393),
        focusNode: _node(_tiles, 0),
        onFocused: () => _remember(_tiles, 0),
        onTap: () => widget.onOpenDetail(
          TvMusicDetailSpec(
            kind: TvMusicDetailKind.favorites,
            title: tr('tv.music.favorites'),
            subtitle: tr('music.nav.songs'),
            coverTrackId: widget.favorites.isEmpty
                ? null
                : widget.favorites.first.id,
            tracks: Future<List<MusicTrack>>.value(widget.favorites),
            trackCountHint: widget.favorites.length,
          ),
        ),
      ),
      _TvFeatureTile(
        title: tr('tv.music.randomAll'),
        subtitle: _shuffling ? '…' : tr('music.play.shuffle'),
        icon: Icons.shuffle_rounded,
        accent: const Color(0xFF6C5CE7),
        focusNode: _node(_tiles, 1),
        onFocused: () => _remember(_tiles, 1),
        onTap: _shuffleAll,
      ),
      _TvFeatureTile(
        title: tr('tv.music.playlists'),
        subtitle: tr('tv.music.allPlaylists'),
        icon: Icons.queue_music_rounded,
        accent: const Color(0xFF00B894),
        focusNode: _node(_tiles, 2),
        onFocused: () => _remember(_tiles, 2),
        onTap: _focusPlaylistLane,
      ),
      _TvFeatureTile(
        title: tr('tv.music.allArtists'),
        subtitle: tr('tv.music.tracks', {'n': '${widget.artists.length}'}),
        icon: Icons.people_alt_rounded,
        accent: const Color(0xFF0984E3),
        focusNode: _node(_tiles, 3),
        onFocused: () => _remember(_tiles, 3),
        onTap: widget.onOpenAllArtists,
      ),
    ];

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.symmetric(horizontal: m.px(8), vertical: m.px(6)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < tiles.length; i += 1) ...[
            if (i > 0) SizedBox(width: m.px(20)),
            tiles[i],
          ],
        ],
      ),
    );
  }

  Widget _albumRow(
    TvMetrics m, {
    required String laneId,
    required String title,
    required List<TvMusicAlbumEntry> albums,
  }) {
    return TvCardRow(
      title: title,
      children: [
        for (var i = 0; i < albums.length; i += 1)
          _TvAlbumCard(
            album: albums[i],
            focusNode: _node(laneId, i),
            onFocused: () => _remember(
              laneId,
              i,
              coverTrackId: albums[i].coverTrackId,
            ),
            onTap: () => _openAlbum(albums[i]),
          ),
      ],
    );
  }

  void _openPlaylist(TvPlaylistEntry entry) {
    final client = ApiSession.instance.client;
    widget.onOpenDetail(
      TvMusicDetailSpec(
        kind: entry.isCollection
            ? TvMusicDetailKind.collection
            : TvMusicDetailKind.playlist,
        title: entry.name,
        subtitle: entry.isCollection
            ? tr('tv.music.collection')
            : tr('tv.music.playlist'),
        coverTrackId: entry.coverTrackId,
        tracks: entry.isCollection
            ? client
                  .musicCollectionItems(id: entry.id, limit: 200)
                  .then<List<MusicTrack>>((res) => res.items)
            : client
                  .musicPlaylistItems(playlistId: entry.id, limit: 200)
                  .then<List<MusicTrack>>((res) => res.items),
        trackCountHint: entry.tracks,
      ),
    );
  }

  void _openAlbum(TvMusicAlbumEntry album) {
    widget.onOpenDetail(
      TvMusicDetailSpec(
        kind: TvMusicDetailKind.album,
        title: album.name,
        subtitle: album.artist,
        year: album.year,
        coverTrackId: album.coverTrackId,
        tracks: ApiSession.instance.client
            .musicList(album: album.name, limit: 200)
            .then<List<MusicTrack>>((res) => res.items),
        sampleTracks: album.sampleTracks,
        trackCountHint: album.tracks,
        durationHint: album.durationMs,
      ),
    );
  }

  void _openArtist(MusicArtist artist) {
    widget.onOpenDetail(
      TvMusicDetailSpec(
        kind: TvMusicDetailKind.artist,
        title: artist.name,
        subtitle: tr('music.nav.artists'),
        coverTrackId: artist.coverTrackId,
        tracks: ApiSession.instance.client
            .musicList(artist: artist.name, limit: 200)
            .then<List<MusicTrack>>((res) => res.items),
        sampleTracks: widget.artistSamples[artist.name] ?? const <MusicTrack>[],
        trackCountHint: artist.tracks,
        durationHint: artist.durationMs,
      ),
    );
  }

  Widget _buildBackdrop(TvMetrics m) {
    final coverId = _albumBackdrop;
    final show = _focusedLane == _newestLane && coverId != null;
    return IgnorePointer(
      child: ClipRect(
        child: AnimatedOpacity(
          opacity: show ? 1 : 0,
          duration: const Duration(milliseconds: 320),
          curve: Curves.easeOut,
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 420),
                child: ImageFiltered(
                  key: ValueKey<String>(coverId ?? 'empty'),
                  imageFilter: ImageFilter.blur(sigmaX: 36, sigmaY: 36),
                  child: SizedBox.expand(
                    child: NasCoverImage(
                      url: coverId == null
                          ? null
                          : ApiSession.instance.coverUrl('music', coverId),
                      headers: ApiSession.instance.authHeaders,
                      icon: Icons.album_outlined,
                      fit: BoxFit.cover,
                      cacheWidth: 900,
                      borderRadius: 0,
                    ),
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
                      Colors.black.withValues(alpha: 0.65),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 全部歌手页：焦点默认落在第一位歌手，返回键由分区处理。
class TvMusicArtistGridPage extends StatefulWidget {
  const TvMusicArtistGridPage({
    super.key,
    required this.artists,
    required this.onOpenArtist,
  });

  final List<MusicArtist> artists;
  final void Function(MusicArtist artist) onOpenArtist;

  @override
  State<TvMusicArtistGridPage> createState() => _TvMusicArtistGridPageState();
}

class _TvMusicArtistGridPageState extends State<TvMusicArtistGridPage> {
  final FocusNode _firstFocus = FocusNode(debugLabel: 'tv-music-artist-first');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _firstFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TvSectionHeader(
          title: tr('tv.music.allArtists'),
          trailing: Text(
            tr('tv.music.tracks', {'n': '${widget.artists.length}'}),
            style: TextStyle(
              fontSize: m.px(14),
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: m.px(8),
              vertical: m.px(6),
            ),
            child: Wrap(
              spacing: m.px(20),
              runSpacing: m.px(24),
              children: [
                for (var i = 0; i < widget.artists.length; i += 1)
                  _TvArtistCard(
                    artist: widget.artists[i],
                    focusNode: i == 0 ? _firstFocus : null,
                    onTap: () => widget.onOpenArtist(widget.artists[i]),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _TvFeatureTile extends StatelessWidget {
  const _TvFeatureTile({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.accent,
    required this.onTap,
    required this.onFocused,
    this.focusNode,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final Color accent;
  final VoidCallback onTap;
  final VoidCallback onFocused;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(310);
    final height = m.px(116);
    return TvFocusCard(
      focusNode: focusNode,
      onTap: onTap,
      onFocused: onFocused,
      radius: m.px(18),
      focusScale: 1.04,
      child: Container(
        width: width,
        height: height,
        padding: EdgeInsets.symmetric(horizontal: m.px(18)),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(m.px(18)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              accent.withValues(alpha: 0.34),
              scheme.surface.withValues(alpha: 0.55),
            ],
          ),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Container(
              width: m.px(58),
              height: m.px(58),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.9),
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: m.px(30), color: Colors.white),
            ),
            SizedBox(width: m.px(16)),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: m.px(21),
                      fontWeight: FontWeight.w800,
                      color: scheme.onSurface,
                    ),
                  ),
                  SizedBox(height: m.px(5)),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: m.px(14),
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TvPlaylistCard extends StatelessWidget {
  const _TvPlaylistCard({
    required this.entry,
    required this.onTap,
    required this.onFocused,
    this.focusNode,
  });

  final TvPlaylistEntry entry;
  final VoidCallback onTap;
  final VoidCallback onFocused;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(196);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            focusNode: focusNode,
            onTap: onTap,
            onFocused: onFocused,
            radius: m.px(16),
            child: SizedBox(
              width: width,
              height: width,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _TvCollageCover(
                    seed: entry.name,
                    coverTrackIds: entry.coverTrackIds,
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
                        color: Colors.black.withValues(alpha: 0.55),
                        borderRadius: BorderRadius.circular(m.px(7)),
                      ),
                      child: Text(
                        entry.isCollection
                            ? tr('tv.music.collection')
                            : tr('tv.music.playlist'),
                        style: TextStyle(
                          fontSize: m.px(11),
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    right: m.px(8),
                    bottom: m.px(8),
                    child: Container(
                      width: m.px(38),
                      height: m.px(38),
                      decoration: BoxDecoration(
                        color: scheme.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.35),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: Icon(
                        Icons.play_arrow_rounded,
                        size: m.px(24),
                        color: scheme.onPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: m.px(9)),
          Text(
            entry.name,
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
            tr('tv.music.tracks', {'n': '${entry.tracks}'}),
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

class _TvAlbumCard extends StatelessWidget {
  const _TvAlbumCard({
    required this.album,
    required this.onTap,
    required this.onFocused,
    this.focusNode,
  });

  final TvMusicAlbumEntry album;
  final VoidCallback onTap;
  final VoidCallback onFocused;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(196);
    final meta = [
      if (album.artist != null && album.artist!.trim().isNotEmpty)
        album.artist!,
      if (album.year != null) tr('tv.music.year', {'year': '${album.year}'}),
    ].join(' · ');
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            focusNode: focusNode,
            onTap: onTap,
            onFocused: onFocused,
            radius: m.px(16),
            child: SizedBox(
              width: width,
              height: width,
              child: NasCoverImage(
                url: album.coverTrackId == null
                    ? null
                    : ApiSession.instance.coverUrl(
                        'music',
                        album.coverTrackId!,
                      ),
                headers: ApiSession.instance.authHeaders,
                icon: Icons.album_outlined,
                fallbackText: album.name,
                cacheWidth: (width * 2).round(),
                borderRadius: m.px(16),
              ),
            ),
          ),
          SizedBox(height: m.px(9)),
          Text(
            album.name,
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
            meta,
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

class _TvArtistCard extends StatelessWidget {
  const _TvArtistCard({
    required this.artist,
    required this.onTap,
    this.onFocused,
    this.focusNode,
  });

  final MusicArtist artist;
  final VoidCallback onTap;
  final VoidCallback? onFocused;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(168);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          TvFocusCard(
            focusNode: focusNode,
            onTap: onTap,
            onFocused: onFocused,
            radius: width / 2,
            focusScale: 1.08,
            child: SizedBox(
              width: width,
              height: width,
              child: ClipOval(
                child: NasCoverImage(
                  url: artist.coverTrackId == null
                      ? null
                      : ApiSession.instance.coverUrl(
                          'music',
                          artist.coverTrackId!,
                        ),
                  headers: ApiSession.instance.authHeaders,
                  icon: Icons.person_outline,
                  fallbackText: artist.name,
                  cacheWidth: (width * 2).round(),
                  borderRadius: 0,
                ),
              ),
            ),
          ),
          SizedBox(height: m.px(9)),
          Text(
            artist.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: m.px(16),
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
          SizedBox(height: m.px(2)),
          Text(
            tr('tv.music.tracks', {'n': '${artist.tracks}'}),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
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

/// 1:1 四宫格拼图封面。不足 4 张时用名称哈希生成的渐变色块补齐，
/// 避免出现整块黑底 + 数字占位。
class _TvCollageCover extends StatelessWidget {
  const _TvCollageCover({required this.seed, required this.coverTrackIds});

  final String seed;
  final List<String?> coverTrackIds;

  static const List<List<Color>> _gradients = <List<Color>>[
    <Color>[Color(0xFF6C5CE7), Color(0xFFA29BFE)],
    <Color>[Color(0xFF00B894), Color(0xFF55EFC4)],
    <Color>[Color(0xFF0984E3), Color(0xFF74B9FF)],
    <Color>[Color(0xFFE17055), Color(0xFFFAB1A0)],
    <Color>[Color(0xFFD63031), Color(0xFFFF7675)],
    <Color>[Color(0xFFE84393), Color(0xFFFD79A8)],
    <Color>[Color(0xFFFDCB6E), Color(0xFFF9CA24)],
  ];

  Widget _tile(int index) {
    final id = index < coverTrackIds.length ? coverTrackIds[index] : null;
    if (id != null) {
      return NasCoverImage(
        url: ApiSession.instance.coverUrl('music', id),
        headers: ApiSession.instance.authHeaders,
        icon: Icons.music_note_outlined,
        cacheWidth: 320,
        borderRadius: 0,
      );
    }
    final palette = _gradients[(seed.hashCode.abs() + index * 3) % _gradients.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: palette,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          size: 26,
          color: Colors.white.withValues(alpha: 0.55),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Column(
        children: [
          Expanded(
            child: Row(
              children: [
                Expanded(child: _tile(0)),
                Expanded(child: _tile(1)),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                Expanded(child: _tile(2)),
                Expanded(child: _tile(3)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
