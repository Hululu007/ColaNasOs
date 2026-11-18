import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../video/video_card.dart';
import 'tv_focus.dart';
import 'tv_media_cover.dart';
import 'tv_video_section.dart' show playTvVideo;

/// TV 端「我的合集」分区：所有合集一张卡，点进去看合集里的影片。
///
/// 和 PC 端 `VideoCollectionsPage` 同一份数据（`/video/collections`），
/// 只是换成遥控器焦点 + 一行 6 列的大屏网格。
class TvCollectionsSection extends StatefulWidget {
  const TvCollectionsSection({
    super.key,
    required this.back,
    this.firstFocusNode,
  });

  final TvBackController back;
  final FocusNode? firstFocusNode;

  @override
  State<TvCollectionsSection> createState() => _TvCollectionsSectionState();
}

class _TvCollectionsSectionState extends State<TvCollectionsSection> {
  List<VideoCollection> _collections = const <VideoCollection>[];
  bool _loading = true;
  String? _error;

  VideoCollection? _opened;
  List<VideoItem> _items = const <VideoItem>[];
  bool _itemsLoading = false;

  final FocusNode _ownedFirst = FocusNode(debugLabel: 'tv-collections-first');
  FocusNode get _firstFocus => widget.firstFocusNode ?? _ownedFirst;

  @override
  void initState() {
    super.initState();
    widget.back.handler = _onBack;
    widget.back.overlay = () => _opened != null;
    _load();
  }

  @override
  void dispose() {
    if (widget.back.handler == _onBack) {
      widget.back.handler = null;
      widget.back.overlay = null;
    }
    _ownedFirst.dispose();
    super.dispose();
  }

  bool _onBack() {
    if (_opened != null) {
      setState(() {
        _opened = null;
        _items = const <VideoItem>[];
      });
      _restoreFocus();
      return true;
    }
    return false;
  }

  void _restoreFocus() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  Future<void> _load() async {
    try {
      final res = await ApiSession.instance.client.videoCollectionList();
      if (!mounted) return;
      setState(() {
        _collections = res.items;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _open(VideoCollection collection) async {
    setState(() {
      _opened = collection;
      _items = const <VideoItem>[];
      _itemsLoading = true;
    });
    try {
      final res = await ApiSession.instance.client.videoCollectionItems(
        id: collection.id,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _itemsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _itemsLoading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _play(VideoItem item) async {
    try {
      await playTvVideo(context, item);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(tr('video.playUrlFailed', {'error': '$e'}))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _load);
    }
    final opened = _opened;
    if (opened != null) return _buildItems(m, opened);
    if (_collections.isEmpty) {
      return NasEmptyState(
        title: tr('video.collection.title'),
        message: tr('video.home.emptyHint'),
        icon: Icons.collections_bookmark_outlined,
      );
    }
    final scheme = Theme.of(context).colorScheme;
    return _grid(
      m,
      header: TvSectionHeader(
        title: tr('video.collection.title'),
        trailing: Text(
          '${_collections.length}',
          style: TextStyle(fontSize: m.px(14), color: scheme.onSurfaceVariant),
        ),
      ),
      cells: (w) => <Widget>[
        for (var i = 0; i < _collections.length; i += 1)
          _TvCollectionCard(
            collection: _collections[i],
            focusNode: i == 0 ? _firstFocus : null,
            onTap: () => _open(_collections[i]),
          ),
      ],
    );
  }

  Widget _buildItems(TvMetrics m, VideoCollection collection) {
    final scheme = Theme.of(context).colorScheme;
    if (_itemsLoading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return NasEmptyState(
        title: collection.name,
        message: tr('video.home.emptyHint'),
        icon: Icons.movie_outlined,
      );
    }
    return _grid(
      m,
      header: TvSectionHeader(
        title: collection.name,
        trailing: Text(
          '${_items.length}',
          style: TextStyle(fontSize: m.px(14), color: scheme.onSurfaceVariant),
        ),
      ),
      cells: (w) => <Widget>[
        for (var i = 0; i < _items.length; i += 1)
          _TvCollectionItemCard(
            item: _items[i],
            width: w,
            focusNode: i == 0 ? _firstFocus : null,
            onTap: () => setState(() => _openItem(_items[i])),
          ),
      ],
    );
  }

  void _openItem(VideoItem item) {
    // 合集里的影片直接播：TV 上多一层详情页只会多按一次返回。
    unawaited(_play(item));
  }

  /// 一行 6 列、不限行的滚动网格。
  Widget _grid(
    TvMetrics m, {
    required Widget header,
    required List<Widget> Function(double width) cells,
  }) {
    return SingleChildScrollView(
      padding: EdgeInsets.only(top: m.px(4), bottom: m.px(24)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          header,
          Padding(
            padding: EdgeInsets.symmetric(horizontal: m.px(8)),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final gap = m.px(18);
                final width = (constraints.maxWidth - gap * 5) / 6 - 1;
                return Wrap(
                  spacing: gap,
                  runSpacing: m.px(20),
                  children: <Widget>[
                    for (final cell in cells(width))
                      SizedBox(width: width, child: cell),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TvCollectionCard extends StatelessWidget {
  const _TvCollectionCard({
    required this.collection,
    required this.onTap,
    this.focusNode,
  });

  final VideoCollection collection;
  final VoidCallback onTap;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    final cover = (collection.coverItemId ?? '').trim();
    final url = cover.isEmpty
        ? null
        : '${ApiSession.instance.baseUrl}/api/v1/video/art'
              '?id=${Uri.encodeComponent(cover)}&kind=poster&size=480';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvFocusCard(
          focusNode: focusNode,
          onTap: onTap,
          radius: m.px(14),
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: TvMediaCover(
              urls: <String?>[url],
              fallbackText: collection.name,
              icon: Icons.collections_bookmark_outlined,
              cacheWidth: 480,
              borderRadius: m.px(14),
            ),
          ),
        ),
        SizedBox(height: m.px(9)),
        Text(
          collection.name,
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
          tr('tv.movie.count', {'n': '${collection.items}'}),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: m.px(12), color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _TvCollectionItemCard extends StatelessWidget {
  const _TvCollectionItemCard({
    required this.item,
    required this.onTap,
    required this.width,
    this.focusNode,
  });

  final VideoItem item;
  final VoidCallback onTap;
  final double width;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TvFocusCard(
          focusNode: focusNode,
          onTap: onTap,
          radius: m.px(14),
          child: AspectRatio(
            aspectRatio: 2 / 3,
            child: TvMediaCover(
              urls: <String?>[
                videoPosterUrl(item, size: (width * 2).round()),
                videoPosterUrl(item, kind: 'fanart', size: (width * 2).round()),
              ],
              fallbackText: item.title,
              icon: Icons.movie_outlined,
              cacheWidth: (width * 2).round(),
              borderRadius: m.px(14),
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
      ],
    );
  }
}
