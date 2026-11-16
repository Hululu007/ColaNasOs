import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../music/music_playback.dart';
import 'music/tv_music_detail.dart';
import 'music/tv_music_home.dart';
import 'music/tv_music_player.dart';
import 'tv_focus.dart';

/// TV 版音乐分区。
///
/// 首页 = 功能瓷片 + 泳道；点进歌单 / 合集 / 专辑 / 歌手是左右分栏详情；
/// 全屏播放页从迷你播放条或详情里的操作进入。分区内部维护一层返回栈：
/// 详情 → 首页 → 顶部 tab，返回键逐层消费。
class TvMusicSection extends StatefulWidget {
  const TvMusicSection({super.key, required this.back, this.firstFocusNode});

  final TvBackController back;

  /// 顶部 tab 下键进入内容时，外壳会 request 这个节点。
  final FocusNode? firstFocusNode;

  @override
  State<TvMusicSection> createState() => _TvMusicSectionState();
}

class _TvMusicSectionState extends State<TvMusicSection> {
  bool _loading = true;
  String? _error;

  List<MusicTrack> _favorites = const <MusicTrack>[];
  List<TvPlaylistEntry> _playlistEntries = const <TvPlaylistEntry>[];
  List<TvMusicAlbumEntry> _recentAlbums = const <TvMusicAlbumEntry>[];
  List<TvMusicAlbumEntry> _topAlbums = const <TvMusicAlbumEntry>[];
  List<TvMusicAlbumEntry> _newestAlbums = const <TvMusicAlbumEntry>[];
  List<MusicArtist> _artists = const <MusicArtist>[];
  Map<String, List<MusicTrack>> _artistSamples =
      const <String, List<MusicTrack>>{};

  TvMusicDetailSpec? _detail;
  bool _showAllArtists = false;

  final GlobalKey<TvMusicDetailPageState> _detailKey =
      GlobalKey<TvMusicDetailPageState>();
  final FocusNode _ownedFirstFocus = FocusNode(debugLabel: 'tv-music-first');

  FocusNode get _firstFocus => widget.firstFocusNode ?? _ownedFirstFocus;

  bool _onBackPressed() => _handleBack();

  bool _hasOverlay() => _detail != null || _showAllArtists;

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
    _ownedFirstFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final client = ApiSession.instance.client;
    Future<T?> safe<T>(Future<T> future) async {
      try {
        return await future;
      } catch (_) {
        return null;
      }
    }

    final results = await Future.wait<Object?>([
      safe(client.musicFavorites()),
      safe(client.musicHistory(limit: 80)),
      safe(client.musicPlaylistList()),
      safe(client.musicCollectionList()),
      safe(client.musicArtists(limit: 60)),
      safe(client.musicAutoPlaylist(kind: 'recent_added', limit: 120)),
      safe(client.musicAutoPlaylist(kind: 'most_played', limit: 120)),
    ]);
    if (!mounted) return;

    final favorites = results[0] as MusicListResponse?;
    final history = results[1] as MusicListResponse?;
    final playlists = results[2] as MusicPlaylistListResponse?;
    final collections = results[3] as MusicCollectionListResponse?;
    final artists = results[4] as MusicArtistListResponse?;
    final recentAdded = results[5] as MusicAutoPlaylistTracksResponse?;
    final mostPlayed = results[6] as MusicAutoPlaylistTracksResponse?;

    final playlistEntries = await _loadPlaylistEntries(
      client: client,
      playlists: playlists?.items ?? const <MusicPlaylist>[],
      collections: collections?.items ?? const <MusicCollection>[],
    );
    if (!mounted) return;

    final artistList = [...?artists?.items]
      ..sort((a, b) {
        final tracks = b.tracks.compareTo(a.tracks);
        if (tracks != 0) return tracks;
        return a.name.compareTo(b.name);
      });
    final artistSamples = _artistSamplesFrom([
      ...?history?.items,
      ...?mostPlayed?.items,
      ...?recentAdded?.items,
    ]);

    setState(() {
      _favorites = favorites?.items ?? const <MusicTrack>[];
      _playlistEntries = playlistEntries;
      _recentAlbums = _albumsFromTracks(
        history?.items ?? const <MusicTrack>[],
      );
      _topAlbums = _albumsFromTracks(
        mostPlayed?.items ?? const <MusicTrack>[],
      );
      _newestAlbums = _albumsFromTracks(
        recentAdded?.items ?? const <MusicTrack>[],
      );
      _artists = artistList;
      _artistSamples = artistSamples;
      _loading = false;
      _error = (favorites == null &&
              history == null &&
              playlists == null &&
              collections == null &&
              artists == null &&
              recentAdded == null &&
              mostPlayed == null)
          ? tr('common.error')
          : null;
    });
  }

  Future<List<TvPlaylistEntry>> _loadPlaylistEntries({
    required ApiClient client,
    required List<MusicPlaylist> playlists,
    required List<MusicCollection> collections,
  }) async {
    Future<List<String?>> coversOfPlaylist(MusicPlaylist playlist) async {
      if (playlist.coverTrackId == null && playlist.tracks <= 0) {
        return const <String?>[];
      }
      try {
        final res = await client.musicPlaylistItems(
          playlistId: playlist.id,
          limit: 4,
        );
        final ids = res.items.map((track) => track.id).toList();
        if (ids.isNotEmpty) return ids;
      } catch (_) {
        // 拿不到成员就退回代表封面。
      }
      return <String?>[playlist.coverTrackId];
    }

    Future<List<String?>> coversOfCollection(MusicCollection collection) async {
      if (collection.coverTrackId == null && collection.tracks <= 0) {
        return const <String?>[];
      }
      try {
        final res = await client.musicCollectionItems(
          id: collection.id,
          limit: 4,
        );
        final ids = res.items.map((track) => track.id).toList();
        if (ids.isNotEmpty) return ids;
      } catch (_) {
        // 拿不到成员就退回代表封面。
      }
      return <String?>[collection.coverTrackId];
    }

    // 只给前 24 张卡片补拼图封面，避免首页一进来打出上百个请求。
    const int withCovers = 24;
    final playlistCovers = await Future.wait<List<String?>>([
      for (var i = 0; i < playlists.length; i += 1)
        i < withCovers
            ? coversOfPlaylist(playlists[i])
            : Future<List<String?>>.value(<String?>[
                playlists[i].coverTrackId,
              ]),
    ]);
    final collectionCovers = await Future.wait<List<String?>>([
      for (var i = 0; i < collections.length; i += 1)
        i < withCovers
            ? coversOfCollection(collections[i])
            : Future<List<String?>>.value(<String?>[
                collections[i].coverTrackId,
              ]),
    ]);

    return <TvPlaylistEntry>[
      for (var i = 0; i < playlists.length; i += 1)
        TvPlaylistEntry(
          id: playlists[i].id,
          name: playlists[i].name,
          isCollection: false,
          tracks: playlists[i].tracks,
          coverTrackId: playlists[i].coverTrackId,
          coverTrackIds: playlistCovers[i],
        ),
      for (var i = 0; i < collections.length; i += 1)
        TvPlaylistEntry(
          id: collections[i].id,
          name: collections[i].name,
          isCollection: true,
          tracks: collections[i].tracks,
          coverTrackId: collections[i].coverTrackId,
          coverTrackIds: collectionCovers[i],
        ),
    ];
  }

  /// 曲目按专辑聚合：最近播放 / 常听 / 最新添加共用同一份逻辑。
  List<TvMusicAlbumEntry> _albumsFromTracks(
    List<MusicTrack> tracks, {
    int limit = 24,
  }) {
    final order = <String>[];
    final groups = <String, List<MusicTrack>>{};
    for (final track in tracks) {
      final album = (track.album ?? '').trim();
      if (album.isEmpty) continue;
      final key = '${(track.artist ?? '').trim()}\u0000$album';
      final list = groups.putIfAbsent(key, () {
        order.add(key);
        return <MusicTrack>[];
      });
      list.add(track);
    }

    final result = <TvMusicAlbumEntry>[];
    for (final key in order.take(limit)) {
      final list = groups[key]!;
      final first = list.first;
      final cover = list.firstWhere(
        (track) => track.hasCover,
        orElse: () => first,
      );
      result.add(
        TvMusicAlbumEntry(
          name: (first.album ?? '').trim(),
          artist: first.artist,
          year: first.year,
          tracks: list.length,
          durationMs: list.fold<int>(
            0,
            (sum, track) => sum + (track.durationMs ?? 0),
          ),
          coverTrackId: cover.id,
          sampleTracks: list,
        ),
      );
    }
    return result;
  }

  /// 歌手详情在列表接口为空时的兜底样本（按曲目 id 去重）。
  Map<String, List<MusicTrack>> _artistSamplesFrom(
    Iterable<MusicTrack> tracks,
  ) {
    final seen = <String>{};
    final result = <String, List<MusicTrack>>{};
    for (final track in tracks) {
      final artist = (track.artist ?? '').trim();
      if (artist.isEmpty || !seen.add(track.id)) continue;
      result.putIfAbsent(artist, () => <MusicTrack>[]).add(track);
    }
    return result;
  }

  bool _handleBack() {
    if (_detail != null) {
      if (_detailKey.currentState?.handleBack() ?? false) return true;
      setState(() => _detail = null);
      _restoreFirstFocus();
      return true;
    }
    if (_showAllArtists) {
      setState(() => _showAllArtists = false);
      _restoreFirstFocus();
      return true;
    }
    return false;
  }

  void _restoreFirstFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  void _openDetail(TvMusicDetailSpec spec) {
    setState(() => _detail = spec);
  }

  TvMusicDetailSpec _artistSpec(
    String name, {
    String? coverTrackId,
    int? tracks,
    int? durationMs,
    List<MusicTrack>? sampleTracks,
  }) {
    return TvMusicDetailSpec(
      kind: TvMusicDetailKind.artist,
      title: name,
      subtitle: tr('music.nav.artists'),
      coverTrackId: coverTrackId,
      tracks: ApiSession.instance.client
          .musicList(artist: name, limit: 200)
          .then<List<MusicTrack>>((res) => res.items),
      sampleTracks: sampleTracks ?? const <MusicTrack>[],
      trackCountHint: tracks,
      durationHint: durationMs,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _load);
    }

    final detail = _detail;
    if (detail != null) {
      return TvMusicDetailPage(
        key: _detailKey,
        spec: detail,
        onOpenArtist: (artist) {
          setState(() => _detail = _artistSpec(artist));
        },
      );
    }

    if (_showAllArtists) {
      return TvMusicArtistGridPage(
        artists: _artists,
        onOpenArtist: (artist) {
          setState(
            () => _detail = _artistSpec(
              artist.name,
              coverTrackId: artist.coverTrackId,
              tracks: artist.tracks,
              durationMs: artist.durationMs,
              sampleTracks: _artistSamples[artist.name],
            ),
          );
        },
      );
    }

    return TvMusicHome(
      favorites: _favorites,
      playlists: _playlistEntries,
      recentAlbums: _recentAlbums,
      topAlbums: _topAlbums,
      newestAlbums: _newestAlbums,
      artists: _artists,
      artistSamples: _artistSamples,
      firstFocusNode: _firstFocus,
      onOpenDetail: _openDetail,
      onOpenAllArtists: () => setState(() => _showAllArtists = true),
    );
  }
}

/// 跨分区常驻的底部迷你播放条。
///
/// 无曲目时也占同样高度显示占位，避免开始播放时内容区突然变矮；
/// 封面 + 曲名区域是焦点卡，确认键打开全屏播放页。
class TvNowPlayingBar extends StatelessWidget {
  const TvNowPlayingBar({super.key});

  @override
  Widget build(BuildContext context) {
    final service = MusicPlaybackService.instance;
    return AnimatedBuilder(
      animation: service,
      builder: (context, _) {
        final track = service.track;
        final m = TvMetricsScope.of(context);
        final scheme = Theme.of(context).colorScheme;
        final duration = service.duration.inMilliseconds;
        final ratio = duration <= 0
            ? 0.0
            : (service.position.inMilliseconds / duration).clamp(0.0, 1.0);

        return Padding(
          padding: EdgeInsets.fromLTRB(m.px(8), m.px(10), m.px(8), 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(m.px(16)),
            child: Material(
              color: context.nasStyle.panelColor,
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: m.px(14),
                  vertical: m.px(9),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TvFocusCard(
                        onTap: track == null
                            ? null
                            : () => TvMusicPlayerPage.open(context),
                        radius: m.px(12),
                        focusScale: 1.01,
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: m.px(2)),
                          child: Row(
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(m.px(10)),
                                child: SizedBox(
                                  width: m.px(52),
                                  height: m.px(52),
                                  child: NasCoverImage(
                                    url: track == null
                                        ? null
                                        : ApiSession.instance.coverUrl(
                                            'music',
                                            track.id,
                                          ),
                                    headers: ApiSession.instance.authHeaders,
                                    icon: Icons.music_note_outlined,
                                    cacheWidth: 160,
                                    borderRadius: 0,
                                  ),
                                ),
                              ),
                              SizedBox(width: m.px(14)),
                              Expanded(
                                child: track == null
                                    ? Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            tr('tv.music.notPlaying'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: m.px(16),
                                              fontWeight: FontWeight.w600,
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                          SizedBox(height: m.px(3)),
                                          Text(
                                            tr('tv.music.menuHint'),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: m.px(11),
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                        ],
                                      )
                                    : Column(
                                        mainAxisSize: MainAxisSize.min,
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Expanded(
                                                child: Text(
                                                  track.title,
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: m.px(17),
                                                    fontWeight: FontWeight.w600,
                                                    color: scheme.onSurface,
                                                  ),
                                                ),
                                              ),
                                              SizedBox(width: m.px(8)),
                                              Icon(
                                                Icons.open_in_full_rounded,
                                                size: m.px(16),
                                                color: scheme.primary,
                                              ),
                                            ],
                                          ),
                                          SizedBox(height: m.px(3)),
                                          Text(
                                            [
                                              track.artist,
                                              track.album,
                                            ]
                                                .where(
                                                  (v) => (v ?? '')
                                                      .trim()
                                                      .isNotEmpty,
                                                )
                                                .join(' · '),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: m.px(12),
                                              color: scheme.onSurfaceVariant,
                                            ),
                                          ),
                                          SizedBox(height: m.px(5)),
                                          ClipRRect(
                                            borderRadius: BorderRadius.circular(
                                              99,
                                            ),
                                            child: LinearProgressIndicator(
                                              value: ratio,
                                              minHeight: m.px(3),
                                              backgroundColor: scheme.onSurface
                                                  .withValues(alpha: 0.12),
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    scheme.primary,
                                                  ),
                                            ),
                                          ),
                                        ],
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (track != null) ...[
                      SizedBox(width: m.px(16)),
                      _TvRoundButton(
                        icon: Icons.skip_previous_rounded,
                        onTap: service.previous,
                      ),
                      SizedBox(width: m.px(10)),
                      _TvRoundButton(
                        icon: service.playing
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        filled: true,
                        onTap: service.toggle,
                      ),
                      SizedBox(width: m.px(10)),
                      _TvRoundButton(
                        icon: Icons.skip_next_rounded,
                        onTap: service.next,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TvRoundButton extends StatelessWidget {
  const _TvRoundButton({
    required this.icon,
    required this.onTap,
    this.filled = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final size = m.px(44);
    return TvFocusCard(
      onTap: onTap,
      radius: size / 2,
      focusScale: 1.12,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: filled
              ? scheme.primary
              : scheme.onSurface.withValues(alpha: 0.12),
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: m.px(23),
          color: filled ? scheme.onPrimary : scheme.onSurface,
        ),
      ),
    );
  }
}
