import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../tv_focus.dart';
import 'tv_movie_models.dart';
import 'tv_movie_widgets.dart';

/// 系列电影合集页：一张卡进来看同系列的每一部，再点进单片详情。
class TvMovieCollectionPage extends StatefulWidget {
  const TvMovieCollectionPage({
    super.key,
    required this.collection,
    required this.onOpenMovie,
    this.firstFocusNode,
  });

  final TvMovieCollection collection;
  final void Function(VideoItem item) onOpenMovie;
  final FocusNode? firstFocusNode;

  @override
  State<TvMovieCollectionPage> createState() => _TvMovieCollectionPageState();
}

class _TvMovieCollectionPageState extends State<TvMovieCollectionPage> {
  final Map<String, FocusNode> _nodes = <String, FocusNode>{};
  final FocusNode _ownedFirst = FocusNode(debugLabel: 'tv-movie-collection-first');

  FocusNode get _firstFocus => widget.firstFocusNode ?? _ownedFirst;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _firstFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    for (final entry in _nodes.entries) {
      if (identical(entry.value, widget.firstFocusNode)) continue;
      entry.value.dispose();
    }
    _ownedFirst.dispose();
    super.dispose();
  }

  FocusNode _node(VideoItem item, int index) {
    if (index == 0) return _firstFocus;
    return _nodes.putIfAbsent(
      item.id,
      () => FocusNode(debugLabel: 'tv-movie-collection-${item.id}'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final collection = widget.collection;
    return DecoratedBox(
      // 与电影详情一致的沉浸式深色底，避免白色标题落在浅色面板上看不见。
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
            TvSectionHeader(
              title: collection.name,
              trailing: Text(
                tr('tv.movie.count', {'n': '${collection.movies.length}'}),
                style: TextStyle(
                  fontSize: m.px(14),
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: m.px(8)),
              child: collection.movies.isEmpty
                  ? NasEmptyState(
                      title: tr('video.collection.emptyItems'),
                      message: tr('video.collection.emptyItemsHint'),
                      icon: Icons.movie_filter_outlined,
                    )
                  : Wrap(
                      spacing: m.px(20),
                      runSpacing: m.px(22),
                      children: [
                        for (var i = 0; i < collection.movies.length; i += 1)
                          TvMoviePosterCard(
                            item: collection.movies[i],
                            focusNode: _node(collection.movies[i], i),
                            onFocused: () {},
                            onTap: () => widget.onOpenMovie(
                              collection.movies[i],
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
