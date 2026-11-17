import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../core/settings_store.dart';
import 'music_library_pages.dart';
import 'music_playlists_page.dart';
import 'music_track_view.dart';

/// 音乐 · 统一搜索：一个输入框，结果按类型分栏目铺开（歌曲 / 专辑 / 歌手 / 歌单 / 合集）。
///
/// 为什么集中到一个页面：以前每个列表页各有一个搜索框，只能在本页的数据里过滤 ——
/// 想找「某位歌手的某张专辑」得先知道该去专辑页还是歌曲页。现在一处输入、一处看全。
///
/// 数据来源：歌曲 / 专辑 / 歌手走服务端 `q` 参数（已经过了索引），歌单与合集数量小，
/// 直接取全量在本地过滤 —— 少两个接口，也不会出现「歌单搜不到」的割裂感。
///
/// TV 端额外给一块屏上字母键盘（`TvScope` 打开时）：遥控器没有输入法，
/// 不给自己一个键盘就完全没法搜。手机 / 桌面用系统输入法，不显示这块。
class MusicSearchPage extends StatefulWidget {
  const MusicSearchPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<MusicSearchPage> createState() => _MusicSearchPageState();
}

class _MusicSearchPageState extends State<MusicSearchPage> {
  static const String _recentKey = 'music.search.recent';
  static const int _recentMax = 8;

  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();
  late final MusicSearchDebouncer _debounce = MusicSearchDebouncer(_run);

  bool _loading = false;
  String? _error;
  String _query = '';

  List<MusicTrack> _tracks = const [];
  List<MusicAlbum> _albums = const [];
  List<MusicArtist> _artists = const [];
  List<MusicPlaylist> _playlists = const [];
  List<MusicCollection> _collections = const [];

  List<String> _recent = const [];

  /// 栏目的焦点节点：类型 → 每个卡片的 node（只在 TV 模式下建）
  final Map<String, List<FocusNode>> _nodes = <String, List<FocusNode>>{};
  final List<List<FocusNode>> _keyboardNodes = <List<FocusNode>>[];

  bool get _tv => TvScope.of(context);

  @override
  void initState() {
    super.initState();
    _input.addListener(_onChanged);
    _loadRecent();
  }

  @override
  void dispose() {
    _input.removeListener(_onChanged);
    _input.dispose();
    _scroll.dispose();
    _debounce.dispose();
    _inputFocus.dispose();
    for (final list in _nodes.values) {
      for (final node in list) {
        node.dispose();
      }
    }
    for (final row in _keyboardNodes) {
      for (final node in row) {
        node.dispose();
      }
    }
    super.dispose();
  }

  void _onChanged() {
    final next = _input.text.trim();
    if (next == _query) return;
    _query = next;
    _debounce.run();
  }

  Future<void> _loadRecent() async {
    final raw = SettingsStore.instance.getString(_recentKey) ?? '';
    if (!mounted) return;
    setState(() {
      _recent = raw
          .split('\u0000')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();
    });
  }

  Future<void> _remember(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final next = <String>[q, ..._recent.where((e) => e != q)].take(_recentMax).toList();
    setState(() => _recent = next);
    await SettingsStore.instance.setString(_recentKey, next.join('\u0000'));
  }

  Future<void> _clearRecent() async {
    setState(() => _recent = const []);
    await SettingsStore.instance.setString(_recentKey, null);
  }

  Future<void> _run() async {
    final q = _query.trim();
    if (q.isEmpty) {
      setState(() {
        _tracks = const [];
        _albums = const [];
        _artists = const [];
        _playlists = const [];
        _collections = const [];
        _loading = false;
        _error = null;
      });
      _rebuildNodes();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ApiSession.instance.client;
      // 三类走服务端，两类本地过滤：四路并发，谁先回来都不影响整体
      final results = await Future.wait<Object>([
        client.musicList(q: q, limit: 30),
        client.musicAlbums(q: q, limit: 18),
        client.musicArtists(q: q, limit: 18),
        client.musicPlaylistList(),
        client.musicCollectionList(),
      ]);
      if (!mounted) return;
      final lower = q.toLowerCase();
      final playlists = (results[3] as MusicPlaylistListResponse).items
          .where((p) => p.name.toLowerCase().contains(lower))
          .take(18)
          .toList();
      final collections = (results[4] as MusicCollectionListResponse).items
          .where((c) => c.name.toLowerCase().contains(lower))
          .take(18)
          .toList();
      setState(() {
        _tracks = (results[0] as MusicListResponse).items;
        _albums = (results[1] as MusicAlbumListResponse).items;
        _artists = (results[2] as MusicArtistListResponse).items;
        _playlists = playlists;
        _collections = collections;
        _loading = false;
      });
      _rebuildNodes();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 结果变了就重建焦点节点：旧的 node 挂在已经不存在的卡片上，留着只会跳空。
  void _rebuildNodes() {
    for (final list in _nodes.values) {
      for (final node in list) {
        node.dispose();
      }
    }
    _nodes.clear();
    if (!_tv) return;
    void build(String key, int count) {
      if (count <= 0) return;
      _nodes[key] = List<FocusNode>.generate(count, (_) => FocusNode(debugLabel: key));
    }

    build('songs', _tracks.length);
    build('albums', _albums.length);
    build('artists', _artists.length);
    build('playlists', _playlists.length);
    build('collections', _collections.length);
  }

  // ---------------------------------------------------------------- 栏目

  /// 栏目（类型 key + 标题 + 卡片行），顺序固定：歌曲 → 专辑 → 歌手 → 歌单 → 合集
  List<Widget> _sections() {
    final sections = <Widget>[];
    void add(String key, String title, int count, Widget Function(int) card) {
      if (count <= 0) return; // 空栏目直接不渲染，避免只有标题的空白块
      sections.add(
        _Section(
          title: title,
          count: count,
          itemBuilder: card,
          focusNodes: _nodes[key],
          onKey: _handleCardKey,
          sectionKey: key,
        ),
      );
    }

    add('songs', tr('music.search.sectionSongs'), _tracks.length, (i) {
      final track = _tracks[i];
      return _Card(
        title: track.title,
        subtitle: track.artist ?? '',
        coverId: track.id,
        onTap: () {
          unawaited(_remember(_query));
          musicPlayTracks(context, _tracks, i);
        },
        focusNode: _nodes['songs']?[i],
      );
    });
    add('albums', tr('music.search.sectionAlbums'), _albums.length, (i) {
      final album = _albums[i];
      return _Card(
        title: album.name,
        subtitle: album.artist ?? '',
        coverId: album.coverTrackId,
        onTap: () => _openGroup(title: album.name, album: album.name),
        focusNode: _nodes['albums']?[i],
      );
    });
    add('artists', tr('music.search.sectionArtists'), _artists.length, (i) {
      final artist = _artists[i];
      return _Card(
        title: artist.name,
        subtitle: '${artist.albums} ${tr('music.search.sectionAlbums')}',
        coverId: artist.coverTrackId,
        circular: true,
        onTap: () => _openGroup(title: artist.name, artist: artist.name),
        focusNode: _nodes['artists']?[i],
      );
    });
    add('playlists', tr('music.search.sectionPlaylists'), _playlists.length, (i) {
      final playlist = _playlists[i];
      return _Card(
        title: playlist.name,
        subtitle: '${playlist.tracks}',
        coverId: playlist.coverTrackId,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MusicPlaylistDetailPage(playlist: playlist),
          ),
        ),
        focusNode: _nodes['playlists']?[i],
      );
    });
    add('collections', tr('music.search.sectionCollections'), _collections.length, (i) {
      final collection = _collections[i];
      return _Card(
        title: collection.name,
        subtitle: '${collection.tracks}',
        coverId: collection.coverTrackId,
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MusicCollectionDetailPage(collection: collection),
          ),
        ),
        focusNode: _nodes['collections']?[i],
      );
    });
    return sections;
  }

  void _openGroup({required String title, String? album, String? artist}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => MusicGroupTracksPage(title: title, album: album, artist: artist),
      ),
    );
  }

  // ---------------------------------------------------------------- 焦点

  /// 栏目里按 ↑↓：跳到上/下一个栏目的**同一列**（不够就落最后一张）
  void _moveSection(String key, int delta) {
    final order = _visibleKeys;
    final index = order.indexOf(key);
    if (index < 0) return;
    final target = index + delta;
    if (target < 0 || target >= order.length) return;
    final nodes = _nodes[order[target]];
    if (nodes == null || nodes.isEmpty) return;
    final currentCol = _colOf(key);
    nodes[currentCol.clamp(0, nodes.length - 1)].requestFocus();
  }

  int _colOf(String key) => _focusedCol[key] ?? 0;
  final Map<String, int> _focusedCol = <String, int>{};

  List<String> get _visibleKeys => [
    if (_tracks.isNotEmpty) 'songs',
    if (_albums.isNotEmpty) 'albums',
    if (_artists.isNotEmpty) 'artists',
    if (_playlists.isNotEmpty) 'playlists',
    if (_collections.isNotEmpty) 'collections',
  ];

  void _focusKeyboard() {
    if (!_tv) return;
    final row = _keyboardNodes.isEmpty ? null : _keyboardNodes[0];
    if (row == null || row.isEmpty) {
      _inputFocus.requestFocus();
      return;
    }
    row[row.length - 1].requestFocus();
  }

  /// 键盘最右列按 →：焦点进右侧第一栏目第一张
  void _toResults() {
    final keys = _visibleKeys;
    if (keys.isEmpty) return;
    final nodes = _nodes[keys.first];
    if (nodes == null || nodes.isEmpty) return;
    nodes.first.requestFocus();
  }

  KeyEventResult _handleCardKey(String sectionKey, int index, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    _focusedCol[sectionKey] = index;
    final isFirst = index == 0;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft && isFirst) {
      _focusKeyboard();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _moveSection(sectionKey, -1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _moveSection(sectionKey, 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    final tv = TvScope.of(context);
    final results = _resultsArea();
    final body = tv
        ? Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 320, child: _keyboard(context)),
              const VerticalDivider(width: 1),
              Expanded(child: results),
            ],
          )
        : results;

    final page = Column(
      children: [
        _searchBar(context),
        Expanded(child: body),
      ],
    );
    if (widget.embedded) return page;
    return Scaffold(
      appBar: AppBar(title: Text(tr('music.search.title'))),
      body: page,
    );
  }

  Widget _searchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceMd,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          Expanded(
            child: NasSearchField(
              controller: _input,
              hintText: tr('music.search.placeholder'),
              focusNode: _inputFocus,
              autofocus: !_tv,
              onSubmitted: (v) => unawaited(_remember(v)),
              onClear: () => setState(() {}),
            ),
          ),
        ],
      ),
    );
  }

  Widget _resultsArea() {
    if (_query.trim().isEmpty) return _recentArea();
    if (_error != null) {
      return NasErrorState(message: _error!, onRetry: _run);
    }
    final sections = _sections();
    if (sections.isEmpty) {
      if (_loading) {
        return Center(
          child: Text(
            tr('music.search.searching'),
            style: TextStyle(color: context.nasTextSecondary),
          ),
        );
      }
      return Center(
        child: Text(
          tr('music.search.empty'),
          style: TextStyle(color: context.nasTextSecondary),
        ),
      );
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: NasTokens.spaceXl),
      children: sections,
    );
  }

  Widget _recentArea() {
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      children: [
        if (_recent.isNotEmpty) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('music.search.recent'),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              TextButton(
                onPressed: _clearRecent,
                child: Text(tr('music.search.recentClear')),
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final keyword in _recent)
                ActionChip(
                  label: Text(keyword),
                  onPressed: () {
                    _input.text = keyword;
                    _input.selection = TextSelection.collapsed(offset: keyword.length);
                  },
                ),
            ],
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: NasTokens.spaceLg),
            child: Text(
              tr('music.search.hint'),
              style: TextStyle(color: context.nasTextSecondary),
            ),
          ),
      ],
    );
  }

  // ---------------------------------------------------------------- TV 键盘

  static const List<String> _rows = <String>['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];

  Widget _keyboard(BuildContext context) {
    while (_keyboardNodes.length < _rows.length) {
      _keyboardNodes.add(<FocusNode>[]);
    }
    for (var r = 0; r < _rows.length; r += 1) {
      final row = _rows[r];
      final nodes = _keyboardNodes[r];
      while (nodes.length < row.length) {
        nodes.add(FocusNode(debugLabel: 'key-$r-${nodes.length}'));
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var r = 0; r < _rows.length; r += 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  for (var c = 0; c < _rows[r].length; c += 1)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 3),
                        child: _Key(
                          label: _rows[r][c],
                          focusNode: _keyboardNodes[r][c],
                          onTap: () => _append(_rows[r][c]),
                          onKey: (event) => _handleKey(event, r, c),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    _input.clear();
                    _onChanged();
                  },
                  child: Text(tr('music.search.recentClear')),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton(
                  onPressed: _backspace,
                  child: Text(tr('music.search.backspace')),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _append(String char) {
    final text = _input.text + char;
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
  }

  void _backspace() {
    final text = _input.text;
    if (text.isEmpty) return;
    final next = text.substring(0, text.length - 1);
    _input.text = next;
    _input.selection = TextSelection.collapsed(offset: next.length);
  }

  KeyEventResult _handleKey(KeyEvent event, int row, int col) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final rows = _keyboardNodes;
    if (key == LogicalKeyboardKey.arrowRight) {
      if (col == rows[row].length - 1) {
        _toResults();
        return KeyEventResult.handled;
      }
      rows[row][col + 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (col == 0) return KeyEventResult.handled;
      rows[row][col - 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (row == 0) {
        _inputFocus.requestFocus();
        return KeyEventResult.handled;
      }
      final target = rows[row - 1];
      target[col.clamp(0, target.length - 1)].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (row == rows.length - 1) return KeyEventResult.handled;
      final target = rows[row + 1];
      target[col.clamp(0, target.length - 1)].requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }
}

/// 一个栏目：标题由外层渲染，这里只负责横向卡片行。
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.count,
    required this.itemBuilder,
    required this.focusNodes,
    required this.onKey,
    required this.sectionKey,
  });

  final String title;
  final int count;
  final Widget Function(int index) itemBuilder;
  final List<FocusNode>? focusNodes;
  final KeyEventResult Function(String sectionKey, int index, KeyEvent event) onKey;
  final String sectionKey;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceMd,
            NasTokens.spaceMd,
            NasTokens.spaceXs,
          ),
          child: Text(
            title,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
        ),
        SizedBox(
          height: 196,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: count,
            separatorBuilder: (_, _) => const SizedBox(width: 12),
            itemBuilder: (context, i) {
              final card = itemBuilder(i);
              final node =
                  focusNodes != null && i < focusNodes!.length ? focusNodes![i] : null;
              if (node == null) return card;
              return Focus(
                focusNode: node,
                onKeyEvent: (n, event) => onKey(sectionKey, i, event),
                child: card,
              );
            },
          ),
        ),
      ],
    );
  }
}

/// 结果卡片：封面（或圆形头像）+ 标题 + 副标题。
class _Card extends StatefulWidget {
  const _Card({
    required this.title,
    required this.subtitle,
    required this.coverId,
    required this.onTap,
    this.circular = false,
    this.focusNode,
  });

  final String title;
  final String subtitle;
  final String? coverId;
  final VoidCallback onTap;
  final bool circular;
  final FocusNode? focusNode;

  @override
  State<_Card> createState() => _CardState();
}

class _CardState extends State<_Card> {
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() => _focused = widget.focusNode?.hasFocus ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = _focused || _hovered;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          width: 132,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(NasTokens.radiusSm),
            border: Border.all(
              color: active ? scheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(widget.circular ? 48 : NasTokens.radiusSm),
                child: widget.coverId == null
                    ? Container(
                        width: 124,
                        height: widget.circular ? 96 : 124,
                        color: context.nasStyle.panelColor,
                        child: Icon(Icons.music_note, color: context.nasTextSecondary),
                      )
                    : SizedBox(
                        width: widget.circular ? 96 : 124,
                        height: widget.circular ? 96 : 124,
                        child: NasCoverImage(
                          url: musicCoverUrl(widget.coverId!),
                          borderRadius: widget.circular ? 48 : NasTokens.radiusSm,
                          cacheWidth: 300,
                          fallbackText: widget.title,
                        ),
                      ),
              ),
              const SizedBox(height: 6),
              Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: NasTokens.fontBody, fontWeight: FontWeight.w600),
              ),
              if (widget.subtitle.isNotEmpty)
                Text(
                  widget.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: NasTokens.fontCaption,
                    color: context.nasTextSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 屏上键盘的一个键：Tap 输入；焦点态描边（遥控器看得见当前在哪）。
class _Key extends StatefulWidget {
  const _Key({
    required this.label,
    required this.onTap,
    required this.onKey,
    this.focusNode,
  });

  final String label;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent event) onKey;
  final FocusNode? focusNode;

  @override
  State<_Key> createState() => _KeyState();
}

class _KeyState extends State<_Key> {
  bool _focused = false;

  @override
  void initState() {
    super.initState();
    widget.focusNode?.addListener(_onFocus);
  }

  @override
  void dispose() {
    widget.focusNode?.removeListener(_onFocus);
    super.dispose();
  }

  void _onFocus() {
    if (mounted) setState(() => _focused = widget.focusNode?.hasFocus ?? false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      focusNode: widget.focusNode,
      onTap: widget.onTap,
      focusColor: scheme.primary.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      child: Container(
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _focused
              ? scheme.primary.withValues(alpha: 0.18)
              : context.nasStyle.panelColor,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          border: Border.all(
            color: _focused ? scheme.primary : context.nasStyle.panelBorderColor,
          ),
        ),
        child: Text(
          widget.label,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
