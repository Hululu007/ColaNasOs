import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../music/music_playback.dart';
import '../video/video_card.dart';
import '../video/video_series_widgets.dart' show seriesArtUrl;
import 'tv_focus.dart';
import 'tv_keyboard.dart';
import 'tv_media_cover.dart';
import 'tv_video_section.dart';
import 'video/tv_series_detail.dart';
import 'video/tv_series_models.dart';

/// TV 搜索分区：跨影视库与音乐库按关键词搜索，结果分组展示。
///
/// - 输入走 TV 屏幕键盘（[TvKeyboardField]），不依赖系统 IME；
/// - 影视：`/video/list` 命中的条目里有 `series` 的按剧名聚合成剧卡，
///   再补上 `/video/series` 的服务端聚合结果；
/// - 音乐：歌曲 / 专辑 / 歌手三组，点条目直接开播（复用常驻播放服务）。
class TvSearchSection extends StatefulWidget {
  const TvSearchSection({super.key, required this.back, this.firstFocusNode});

  final TvBackController back;
  final FocusNode? firstFocusNode;

  @override
  State<TvSearchSection> createState() => _TvSearchSectionState();
}

class _TvSearchSectionState extends State<TvSearchSection> {
  final TextEditingController _query = TextEditingController();
  final FocusNode _actionFocus = FocusNode(debugLabel: 'tv-search-action');
  final FocusNode _ownedFirstFocus = FocusNode(debugLabel: 'tv-search-first');

  FocusNode get _fieldFocus => widget.firstFocusNode ?? _ownedFirstFocus;

  bool _loading = false;
  String? _error;
  String _submitted = '';

  List<TvSeriesCard> _series = const <TvSeriesCard>[];
  List<VideoItem> _videos = const <VideoItem>[];
  List<MusicTrack> _tracks = const <MusicTrack>[];
  List<MusicAlbum> _albums = const <MusicAlbum>[];
  List<MusicArtist> _artists = const <MusicArtist>[];

  VideoItem? _videoDetail;
  TvSeriesCard? _seriesDetail;
  String _seriesLibraryId = '';
  bool _preparing = false;

  bool _onBackPressed() => _handleBack();

  bool _hasOverlay() => _videoDetail != null || _seriesDetail != null;

  @override
  void initState() {
    super.initState();
    widget.back.handler = _onBackPressed;
    widget.back.overlay = _hasOverlay;
  }

  @override
  void dispose() {
    if (widget.back.handler == _onBackPressed) {
      widget.back.handler = null;
      widget.back.overlay = null;
    }
    _query.dispose();
    _actionFocus.dispose();
    _ownedFirstFocus.dispose();
    super.dispose();
  }

  bool _handleBack() {
    if (_videoDetail != null) {
      setState(() => _videoDetail = null);
      _restoreFocus();
      return true;
    }
    if (_seriesDetail != null) {
      setState(() => _seriesDetail = null);
      _restoreFocus();
      return true;
    }
    return false;
  }

  void _restoreFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldFocus.requestFocus();
    });
  }

  Future<T?> _safe<T>(Future<T> future) async {
    try {
      return await future;
    } catch (_) {
      return null;
    }
  }

  Future<void> _search() async {
    if (_loading) return;
    final q = _query.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _submitted = q;
      _videoDetail = null;
      _seriesDetail = null;
    });
    final client = ApiSession.instance.client;
    final results = await Future.wait<Object?>([
      _safe(client.videoList(q: q, limit: 100)),
      _safe(client.videoSeriesList(q: q, limit: 20)),
      _safe(client.musicList(q: q, limit: 40)),
      _safe(client.musicAlbums(q: q, limit: 20)),
      _safe(client.musicArtists(q: q, limit: 20)),
    ]);
    if (!mounted) return;

    final videoRes = results[0] as VideoListResponse?;
    final seriesRes = results[1] as VideoSeriesListResponse?;
    final trackRes = results[2] as MusicListResponse?;
    final albumRes = results[3] as MusicAlbumListResponse?;
    final artistRes = results[4] as MusicArtistListResponse?;

    final videos = <VideoItem>[];
    final bySeries = <String, List<VideoItem>>{};
    for (final item in videoRes?.items ?? const <VideoItem>[]) {
      final name = (item.series ?? '').trim();
      if (name.isEmpty) {
        videos.add(item);
      } else {
        bySeries.putIfAbsent(name, () => <VideoItem>[]).add(item);
      }
    }
    final series = <TvSeriesCard>[
      for (final entry in bySeries.entries)
        _seriesCardFrom(name: entry.key, items: entry.value),
    ];
    for (final item
        in seriesRes?.items ?? const <VideoSeriesItem>[]) {
      if (series.any((card) => card.name == item.name)) continue;
      series.add(
        TvSeriesCard(
          name: item.name,
          seasons: item.seasons,
          episodes: item.episodes,
          watchedEpisodes: item.watchedEpisodes ?? 0,
          coverId: item.coverId,
          posterId: item.posterId,
        ),
      );
    }

    setState(() {
      _videos = videos;
      _series = series;
      _tracks = trackRes?.items ?? const <MusicTrack>[];
      _albums = albumRes?.items ?? const <MusicAlbum>[];
      _artists = artistRes?.items ?? const <MusicArtist>[];
      _loading = false;
      _error = (videoRes == null &&
              seriesRes == null &&
              trackRes == null &&
              albumRes == null &&
              artistRes == null)
          ? tr('common.error')
          : null;
    });
  }

  /// 把同一部剧的条目聚成剧卡（首页卡片与详情页共用同一结构）。
  TvSeriesCard _seriesCardFrom({
    required String name,
    required List<VideoItem> items,
  }) {
    final sorted = [...items]..sort((a, b) {
      final season = (a.season ?? 1).compareTo(b.season ?? 1);
      if (season != 0) return season;
      return (a.episode ?? 0).compareTo(b.episode ?? 0);
    });
    final cover = sorted.firstWhere(
      (item) => item.hasArt,
      orElse: () => sorted.first,
    );
    final seasons = <int>{for (final item in sorted) item.season ?? 1};
    return TvSeriesCard(
      name: name,
      seasons: seasons.isEmpty ? 1 : seasons.length,
      episodes: sorted.length,
      watchedEpisodes: sorted.where((item) => item.watched).length,
      coverId: cover.id,
      firstItem: cover,
      year: cover.year,
      overview: sorted
          .map((item) => item.overview)
          .firstWhere(
            (value) => (value ?? '').trim().isNotEmpty,
            orElse: () => null,
          ),
      preloadedItems: sorted,
    );
  }

  Future<void> _openSeries(TvSeriesCard card) async {
    if (card.preloadedItems.isNotEmpty) {
      setState(() {
        _seriesDetail = card;
        _seriesLibraryId = card.preloadedItems.first.libraryId;
      });
      return;
    }
    setState(() => _loading = true);
    try {
      final res = await ApiSession.instance.client.videoSeriesItems(
        name: card.name,
        limit: 200,
      );
      if (!mounted) return;
      if (res.items.isEmpty) {
        setState(() => _loading = false);
        NasSnack.show(context, tr('tv.search.noResult', {'q': card.name}));
        return;
      }
      final first = res.items.first;
      setState(() {
        _loading = false;
        _seriesLibraryId = first.libraryId;
        _seriesDetail = TvSeriesCard(
          name: card.name,
          seasons: card.seasons,
          episodes: card.episodes,
          watchedEpisodes: card.watchedEpisodes,
          coverId: card.coverId,
          posterId: card.posterId,
          firstItem: first,
          preloadedItems: res.items,
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = tr('tv.search.failed', {'error': '$e'});
      });
    }
  }

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

  void _playTracks(List<MusicTrack> tracks, int index) {
    if (tracks.isEmpty) return;
    MusicPlaybackService.instance.playQueue(tracks, index);
  }

  Future<void> _playAlbum(MusicAlbum album) async {
    try {
      final res = await ApiSession.instance.client.musicList(
        album: album.name,
        limit: 200,
      );
      if (!mounted) return;
      if (res.items.isEmpty) {
        NasSnack.show(context, tr('tv.search.noResult', {'q': album.name}));
        return;
      }
      _playTracks(res.items, 0);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('tv.search.failed', {'error': '$e'}));
    }
  }

  Future<void> _playArtist(MusicArtist artist) async {
    try {
      final res = await ApiSession.instance.client.musicList(
        artist: artist.name,
        limit: 200,
      );
      if (!mounted) return;
      if (res.items.isEmpty) {
        NasSnack.show(context, tr('tv.search.noResult', {'q': artist.name}));
        return;
      }
      _playTracks(res.items, 0);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('tv.search.failed', {'error': '$e'}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final video = _videoDetail;
    if (video != null) {
      return TvVideoDetailView(
        item: video,
        preparing: _preparing,
        onPlay: () => _play(video),
        onBack: _handleBack,
      );
    }
    final series = _seriesDetail;
    if (series != null) {
      return TvSeriesDetailPage(
        key: ValueKey<String>('search-series-${series.name}'),
        card: series,
        libraryId: _seriesLibraryId,
        roots: const <String>[],
        progressById: const <String, VideoProgressItem>{},
        onPlay: _play,
      );
    }

    final m = TvMetricsScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TvKeyboardField(
                controller: _query,
                focusNode: _fieldFocus,
                labelText: tr('tv.tab.search'),
                hintText: tr('tv.search.hint'),
                prefixIcon: const Icon(Icons.search_rounded, size: 18),
                nextFocusNodes: <FocusNode>[_actionFocus],
                onSubmitted: (_) => _search(),
              ),
            ),
            SizedBox(width: m.px(14)),
            TvFocusCard(
              focusNode: _actionFocus,
              onTap: _loading ? null : _search,
              radius: m.px(12),
              focusScale: 1.02,
              child: Container(
                height: m.px(58),
                padding: EdgeInsets.symmetric(horizontal: m.px(28)),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.primary.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(m.px(12)),
                ),
                alignment: Alignment.center,
                child: _loading
                    ? SizedBox(
                        height: m.px(20),
                        width: m.px(20),
                        child: const CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(
                        tr('tv.search.action'),
                        style: TextStyle(
                          fontSize: m.px(17),
                          fontWeight: FontWeight.w700,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
              ),
            ),
          ],
        ),
        SizedBox(height: m.px(18)),
        Expanded(child: _buildResults(m)),
      ],
    );
  }

  Widget _buildResults(TvMetrics m) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _search);
    }
    if (_submitted.isEmpty) {
      return Center(
        child: Text(
          tr('tv.search.empty'),
          style: TextStyle(
            fontSize: m.px(18),
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final empty = _series.isEmpty &&
        _videos.isEmpty &&
        _tracks.isEmpty &&
        _albums.isEmpty &&
        _artists.isEmpty;
    if (empty) {
      return Center(
        child: Text(
          tr('tv.search.noResult', {'q': _submitted}),
          style: TextStyle(
            fontSize: m.px(18),
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final rows = <Widget>[];
    if (_series.isNotEmpty) {
      rows.add(
        TvCardRow(
          title: tr('tv.search.group.series'),
          children: <Widget>[
            for (final card in _series)
              _SeriesResultCard(card: card, onTap: () => _openSeries(card)),
          ],
        ),
      );
    }
    if (_videos.isNotEmpty) {
      rows.add(
        TvCardRow(
          title: tr('tv.search.group.video'),
          children: <Widget>[
            for (final item in _videos)
              _VideoResultCard(
                item: item,
                onTap: () => setState(() => _videoDetail = item),
              ),
          ],
        ),
      );
    }
    if (_tracks.isNotEmpty) {
      final tracks = _tracks;
      rows.add(
        TvCardRow(
          title: tr('tv.search.group.track'),
          children: <Widget>[
            for (var i = 0; i < tracks.length; i += 1)
              _TrackResultCard(
                track: tracks[i],
                onTap: () => _playTracks(tracks, i),
              ),
          ],
        ),
      );
    }
    if (_albums.isNotEmpty) {
      rows.add(
        TvCardRow(
          title: tr('tv.search.group.album'),
          children: <Widget>[
            for (final album in _albums)
              _AlbumResultCard(
                album: album,
                onTap: () => _playAlbum(album),
              ),
          ],
        ),
      );
    }
    if (_artists.isNotEmpty) {
      rows.add(
        TvCardRow(
          title: tr('tv.search.group.artist'),
          children: <Widget>[
            for (final artist in _artists)
              _ArtistResultCard(
                artist: artist,
                onTap: () => _playArtist(artist),
              ),
          ],
        ),
      );
    }

    return SingleChildScrollView(
      padding: EdgeInsets.only(bottom: m.px(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i += 1) ...[
            if (i > 0) SizedBox(height: m.px(18)),
            rows[i],
          ],
        ],
      ),
    );
  }
}

class _VideoResultCard extends StatelessWidget {
  const _VideoResultCard({required this.item, required this.onTap});

  final VideoItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(170);
    final isImage = item.mediaType == 'image';
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            onTap: onTap,
            radius: m.px(14),
            child: SizedBox(
              width: width,
              height: width * (isImage ? 3 / 4 : 3 / 2),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(m.px(14)),
                child: NasCoverImage(
                  url: videoPosterUrl(item, size: (width * 2).round()),
                  fit: BoxFit.cover,
                  headers: videoArtHeaders,
                  fallbackText: item.title,
                  cacheWidth: (width * 2).round(),
                  borderRadius: 0,
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

class _SeriesResultCard extends StatelessWidget {
  const _SeriesResultCard({required this.card, required this.onTap});

  final TvSeriesCard card;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final width = m.px(170);
    return SizedBox(
      width: width,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            onTap: onTap,
            radius: m.px(14),
            child: SizedBox(
              width: width,
              height: width * 3 / 2,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(m.px(14)),
                child: TvMediaCover(
                  urls: <String?>[
                    seriesArtUrl(card.posterId, size: (width * 2).round()),
                    seriesArtUrl(card.coverId, size: (width * 2).round()),
                  ],
                  fallbackText: card.name,
                  cacheWidth: (width * 2).round(),
                ),
              ),
            ),
          ),
          SizedBox(height: m.px(10)),
          Text(
            card.name,
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
            tr('tv.series.seasonCount', {'n': '${card.seasons}'}),
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

class _TrackResultCard extends StatelessWidget {
  const _TrackResultCard({required this.track, required this.onTap});

  final MusicTrack track;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final size = m.px(170);
    return SizedBox(
      width: size,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            onTap: onTap,
            radius: m.px(14),
            child: SizedBox(
              width: size,
              height: size,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(m.px(14)),
                child: NasCoverImage(
                  url: ApiSession.instance.coverUrl('music', track.id),
                  headers: ApiSession.instance.authHeaders,
                  icon: Icons.music_note_outlined,
                  fallbackText: track.title,
                  cacheWidth: (size * 2).round(),
                  borderRadius: 0,
                ),
              ),
            ),
          ),
          SizedBox(height: m.px(10)),
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
          SizedBox(height: m.px(3)),
          Text(
            (track.artist ?? '').trim().isEmpty
                ? tr('tv.music.unknownArtist')
                : track.artist!,
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

class _AlbumResultCard extends StatelessWidget {
  const _AlbumResultCard({required this.album, required this.onTap});

  final MusicAlbum album;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final size = m.px(170);
    return SizedBox(
      width: size,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            onTap: onTap,
            radius: m.px(14),
            child: SizedBox(
              width: size,
              height: size,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(m.px(14)),
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
                  cacheWidth: (size * 2).round(),
                  borderRadius: 0,
                ),
              ),
            ),
          ),
          SizedBox(height: m.px(10)),
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
            (album.artist ?? '').trim().isEmpty
                ? tr('tv.music.tracks', {'n': '${album.tracks}'})
                : '${album.artist} · ${tr('tv.music.tracks', {'n': '${album.tracks}'})}',
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

class _ArtistResultCard extends StatelessWidget {
  const _ArtistResultCard({required this.artist, required this.onTap});

  final MusicArtist artist;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final size = m.px(170);
    return SizedBox(
      width: size,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TvFocusCard(
            onTap: onTap,
            radius: size / 2,
            child: SizedBox(
              width: size,
              height: size,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(size / 2),
                child: NasCoverImage(
                  url: artist.coverTrackId == null
                      ? null
                      : ApiSession.instance.coverUrl(
                          'music',
                          artist.coverTrackId!,
                        ),
                  headers: ApiSession.instance.authHeaders,
                  icon: Icons.person_outline_rounded,
                  fallbackText: artist.name,
                  cacheWidth: (size * 2).round(),
                  borderRadius: 0,
                ),
              ),
            ),
          ),
          SizedBox(height: m.px(10)),
          Text(
            artist.name,
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
            tr('tv.music.tracks', {'n': '${artist.tracks}'}),
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
