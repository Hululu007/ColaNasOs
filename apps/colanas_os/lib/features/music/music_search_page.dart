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

/// 音乐 · 统一搜索。
///
/// 布局（TV / 大屏，`TvScope` 打开时）：
///
/// ```
/// ┌──────────────────────────────────────────────┐
/// │ [ 搜索框：已输入的字母 ]                        │
/// ├───────────────────┬──────────────────────────┤
/// │  Q W E R T Y ...  │  歌曲（栏目标题）           │
/// │  A S D F G H ...  │  [卡][卡][卡][卡][卡]      │
/// │  Z X C V B N M    │  专辑                      │
/// │  [清空]  [退格]    │  [卡][卡]                  │
/// └───────────────────┴──────────────────────────┘
/// ```
///
/// 焦点只有两条路：键盘 ←→ 右侧栏目。遥控器「返回」在右侧先退回键盘，
/// 在键盘上才退出页面 —— 一次返回直接退出会让人误触丢掉输入。
///
/// 手机 / 桌面不显示屏上键盘（系统输入法更好用），栏目分组与焦点规则一致。
class MusicSearchPage extends StatefulWidget {
  const MusicSearchPage({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<MusicSearchPage> createState() => _MusicSearchPageState();
}

class _MusicSearchPageState extends State<MusicSearchPage> {
  static const String _recentKey = 'music.search.recent';
  static const int _recentMax = 8;

  /// TV 端每个栏目最多 5 张卡、不横向滚动（设计约束：到最右直接拦住右键，
  /// 否则焦点会跟着 ListView 滚出屏幕，遥控器体验极差）
  static const int _tvSectionMax = 5;
  static const int _wideSectionMax = 14;

  final TextEditingController _input = TextEditingController();
  final FocusNode _inputFocus = FocusNode(debugLabel: 'music-search-input');
  final ScrollController _scroll = ScrollController();
  late final MusicSearchDebouncer _debounce = MusicSearchDebouncer(_run);

  /// 屏上键盘：每行一套焦点节点
  final List<List<FocusNode>> _keys = <List<FocusNode>>[];
  final FocusNode _clearKey = FocusNode(debugLabel: 'key-clear');
  final FocusNode _backspaceKey = FocusNode(debugLabel: 'key-backspace');

  /// 右侧栏目：类型 → 每个卡片的焦点节点
  final Map<String, List<FocusNode>> _cards = <String, List<FocusNode>>{};

  /// 最近聚焦位置，结果变化后用它校准（栏目会被增删）
  String? _lastSection;
  int _lastIndex = 0;

  bool _loading = false;
  String? _error;
  String _query = '';

  List<MusicTrack> _tracks = const [];
  List<MusicAlbum> _albums = const [];
  List<MusicArtist> _artists = const [];
  List<MusicPlaylist> _playlists = const [];
  List<MusicCollection> _collections = const [];

  List<String> _recent = const [];
  List<String> _hot = const [];

  @override
  void initState() {
    super.initState();
    _input.addListener(_onChanged);
    _loadRecent();
    _loadHot();
    // TV：初始焦点落在键盘第一个键上，遥控器一进来就能按方向键；
    // 放帧后是因为键盘节点要到第一次 build 才建出来。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (TvScope.of(context)) _focusKeyboard();
    });
  }

  @override
  void dispose() {
    _input.removeListener(_onChanged);
    _input.dispose();
    _inputFocus.dispose();
    _scroll.dispose();
    _debounce.dispose();
    _clearKey.dispose();
    _backspaceKey.dispose();
    for (final row in _keys) {
      for (final node in row) {
        node.dispose();
      }
    }
    for (final list in _cards.values) {
      for (final node in list) {
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

  // ---------------------------------------------------------------- 最近 / 热门

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

  /// 热门搜索：本机最近播放过的艺人 / 专辑 / 曲名去重。
  /// 真「全站热门」要额外的统计接口，不值得为搜索页加一个 —— 常听的更贴近自己。
  Future<void> _loadHot() async {
    try {
      final res = await ApiSession.instance.client.musicHistory(limit: 40);
      if (!mounted) return;
      final seen = <String>{};
      for (final track in res.items) {
        for (final name in <String?>[track.artist, track.album, track.title]) {
          final value = (name ?? '').trim();
          if (value.isEmpty) continue;
          seen.add(value);
          if (seen.length >= 10) break;
        }
        if (seen.length >= 10) break;
      }
      setState(() => _hot = seen.toList());
    } catch (_) {
      // 拿不到就不显示「热门」栏目
    }
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

  // ---------------------------------------------------------------- 搜索

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
      _rebuildCards();
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final client = ApiSession.instance.client;
      // 歌曲 / 专辑 / 歌手走服务端 q；歌单与合集量小，取全量本地过滤（少两个接口）
      final results = await Future.wait<Object>([
        client.musicList(q: q, limit: 30),
        client.musicAlbums(q: q, limit: 20),
        client.musicArtists(q: q, limit: 20),
        client.musicPlaylistList(),
        client.musicCollectionList(),
      ]);
      if (!mounted) return;
      final lower = q.toLowerCase();
      setState(() {
        _tracks = (results[0] as MusicListResponse).items;
        _albums = (results[1] as MusicAlbumListResponse).items;
        _artists = (results[2] as MusicArtistListResponse).items;
        _playlists = (results[3] as MusicPlaylistListResponse).items
            .where((p) => p.name.toLowerCase().contains(lower))
            .toList();
        _collections = (results[4] as MusicCollectionListResponse).items
            .where((c) => c.name.toLowerCase().contains(lower))
            .toList();
        _loading = false;
      });
      _rebuildCards();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// 结果变了就重建卡片焦点节点，并**在帧后把焦点校准到仍然存在的卡片上**。
  ///
  /// 不校准的后果：用户正停在第 3 个栏目第 4 张卡，输入一个字母让结果变少，
  /// 旧节点被销毁 → 焦点掉回根节点，遥控器得从键盘重新按一遍。
  void _rebuildCards() {
    final previous = _lastSection;
    final previousIndex = _lastIndex;
    for (final list in _cards.values) {
      for (final node in list) {
        node.dispose();
      }
    }
    _cards.clear();

    void build(String key, int count) {
      if (count <= 0) return;
      _cards[key] = List<FocusNode>.generate(
        count,
        (_) => FocusNode(debugLabel: 'card-$key'),
      );
    }

    build('songs', _tracks.length);
    build('albums', _albums.length);
    build('artists', _artists.length);
    build('playlists', _playlists.length);
    build('collections', _collections.length);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final keys = _visibleKeys;
      if (keys.isEmpty) return;
      // 原来那个栏目还在就留在原地，否则回到第一个栏目的同一列
      final target = previous != null && keys.contains(previous) ? previous : keys.first;
      final nodes = _cards[target];
      if (nodes == null || nodes.isEmpty) return;
      final index = previousIndex.clamp(0, nodes.length - 1);
      _lastSection = target;
      _lastIndex = index;
      nodes[index].requestFocus();
    });
  }

  // ---------------------------------------------------------------- 焦点

  List<String> get _visibleKeys => [
    if (_tracks.isNotEmpty) 'songs',
    if (_albums.isNotEmpty) 'albums',
    if (_artists.isNotEmpty) 'artists',
    if (_playlists.isNotEmpty) 'playlists',
    if (_collections.isNotEmpty) 'collections',
  ];

  bool get _resultsFocused =>
      _cards.values.any((list) => list.any((node) => node.hasFocus));

  void _focusKeyboard() {
    if (_keys.isNotEmpty && _keys[0].isNotEmpty) {
      _keys[0][0].requestFocus();
      return;
    }
    _inputFocus.requestFocus();
  }

  /// 键盘最右列按 →：进右侧第一栏目第一个卡片
  void _focusFirstResult() {
    final keys = _visibleKeys;
    if (keys.isEmpty) return;
    final nodes = _cards[keys.first];
    if (nodes == null || nodes.isEmpty) return;
    _lastSection = keys.first;
    _lastIndex = 0;
    nodes.first.requestFocus();
  }

  /// 栏目内 ↑↓：跳到上/下一个栏目的**同一列**，不够就落最后一张
  void _moveSection(String sectionKey, int index, int delta) {
    final keys = _visibleKeys;
    final current = keys.indexOf(sectionKey);
    if (current < 0) return;
    final target = current + delta;
    if (target < 0 || target >= keys.length) return;
    final nodes = _cards[keys[target]];
    if (nodes == null || nodes.isEmpty) return;
    final next = index.clamp(0, nodes.length - 1);
    _lastSection = keys[target];
    _lastIndex = next;
    nodes[next].requestFocus();
  }

  KeyEventResult _handleCardKey(String sectionKey, int index, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    _lastSection = sectionKey;
    _lastIndex = index;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index > 0) {
        _cards[sectionKey]?[index - 1].requestFocus();
        _lastIndex = index - 1;
      } else {
        // 最左列 ← 拉回键盘（设计：只有这一条回路，不做环形）
        _focusKeyboard();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      final nodes = _cards[sectionKey];
      if (nodes == null) return KeyEventResult.handled;
      if (index >= nodes.length - 1) {
        // 到最右就拦住：不横向滚，也不跨栏目
        return KeyEventResult.handled;
      }
      nodes[index + 1].requestFocus();
      _lastIndex = index + 1;
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      _moveSection(sectionKey, index, -1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      _moveSection(sectionKey, index, 1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------- 布局

  @override
  Widget build(BuildContext context) {
    final tv = TvScope.of(context);
    final content = Column(
      children: [
        _searchBar(context, tv),
        Expanded(
          child: tv
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 左 ~35% 键盘 / 右 ~65% 结果（设计给的配比）
                    Expanded(flex: 35, child: _keyboardPanel(context)),
                    const VerticalDivider(width: 1),
                    Expanded(flex: 65, child: _resultsPanel(context, tv: true)),
                  ],
                )
              : _resultsPanel(context, tv: false),
        ),
      ],
    );

    return PopScope(
      // TV：返回键先收回焦点，再退页面。非 TV 没有键盘面板，直接退出
      canPop: !tv,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_resultsFocused) {
          _focusKeyboard();
          return;
        }
        Navigator.of(context).maybePop();
      },
      child: widget.embedded
          ? content
          : Scaffold(
              appBar: AppBar(title: Text(tr('music.search.title'))),
              body: content,
            ),
    );
  }

  Widget _searchBar(BuildContext context, bool tv) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        tv ? NasTokens.spaceMd : NasTokens.spaceSm,
        NasTokens.spaceMd,
        NasTokens.spaceXs,
      ),
      child: NasSearchField(
        controller: _input,
        hintText: tr('music.search.placeholder'),
        focusNode: _inputFocus,
        autofocus: !tv,
        onSubmitted: (v) => _remember(v),
        onClear: () => setState(() {}),
      ),
    );
  }

  // ---------------------------------------------------------------- 屏上键盘

  static const List<String> _rowChars = <String>['qwertyuiop', 'asdfghjkl', 'zxcvbnm'];

  Widget _keyboardPanel(BuildContext context) {
    while (_keys.length < _rowChars.length) {
      _keys.add(<FocusNode>[]);
    }
    for (var r = 0; r < _rowChars.length; r += 1) {
      while (_keys[r].length < _rowChars[r].length) {
        _keys[r].add(FocusNode(debugLabel: 'key-$r-${_keys[r].length}'));
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var r = 0; r < _rowChars.length; r += 1)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  for (var c = 0; c < _rowChars[r].length; c += 1)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: _KeyCap(
                          label: _rowChars[r][c],
                          focusNode: _keys[r][c],
                          big: true,
                          onTap: () => _append(_rowChars[r][c]),
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
                child: _KeyCap(
                  label: tr('music.search.recentClear'),
                  focusNode: _clearKey,
                  onTap: () {
                    _input.clear();
                    _onChanged();
                  },
                  onKey: (event) => _handleActionKey(event, left: true),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _KeyCap(
                  label: tr('music.search.backspace'),
                  focusNode: _backspaceKey,
                  onTap: _backspace,
                  onKey: (event) => _handleActionKey(event, left: false),
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
    final rows = _keys;

    if (key == LogicalKeyboardKey.arrowRight) {
      if (col >= rows[row].length - 1) {
        // 该行最右 → 跳出键盘进结果区
        _focusFirstResult();
      } else {
        rows[row][col + 1].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (col > 0) rows[row][col - 1].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (row == 0) {
        _inputFocus.requestFocus(); // 回搜索框，方便改整串
      } else {
        final target = rows[row - 1];
        target[col.clamp(0, target.length - 1)].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (row == rows.length - 1) {
        _clearKey.requestFocus();
      } else {
        final target = rows[row + 1];
        target[col.clamp(0, target.length - 1)].requestFocus();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleActionKey(KeyEvent event, {required bool left}) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) {
      final last = _keys.isEmpty ? null : _keys.last;
      if (last != null && last.isNotEmpty) last[0].requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (!left) _clearKey.requestFocus();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      if (left) {
        _backspaceKey.requestFocus();
      } else {
        _focusFirstResult();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  // ---------------------------------------------------------------- 结果区

  Widget _resultsPanel(BuildContext context, {required bool tv}) {
    if (_query.trim().isEmpty) return _defaultSections(context, tv: tv);
    if (_error != null) return NasErrorState(message: _error!, onRetry: _run);
    final sections = _resultSections(context, tv: tv);
    if (sections.isEmpty) {
      return Center(
        child: Text(
          _loading ? tr('music.search.searching') : tr('music.search.empty'),
          style: TextStyle(color: context.nasTextSecondary, fontSize: tv ? 22 : 16),
        ),
      );
    }
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.only(bottom: NasTokens.spaceXl),
      children: sections,
    );
  }

  /// 未输入时的默认栏目：热门搜索 + 历史记录（设计里的空状态）
  Widget _defaultSections(BuildContext context, {required bool tv}) {
    if (_hot.isEmpty && _recent.isEmpty) {
      return Center(
        child: Text(
          tr('music.search.hint'),
          style: TextStyle(color: context.nasTextSecondary, fontSize: tv ? 20 : 15),
        ),
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceXl),
      children: [
        if (_hot.isNotEmpty) _chipSection(context, tr('music.search.hot'), _hot, tv: tv),
        if (_recent.isNotEmpty)
          _chipSection(
            context,
            tr('music.search.recent'),
            _recent,
            tv: tv,
            trailing: TextButton(
              onPressed: _clearRecent,
              child: Text(tr('music.search.recentClear')),
            ),
          ),
      ],
    );
  }

  Widget _chipSection(
    BuildContext context,
    String title,
    List<String> keywords, {
    required bool tv,
    Widget? trailing,
  }) {
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
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: tv ? 24 : 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              ?trailing,
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
          child: Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final keyword in keywords)
                ActionChip(
                  label: Text(keyword, style: TextStyle(fontSize: tv ? 18 : 14)),
                  onPressed: () {
                    _input.text = keyword;
                    _input.selection = TextSelection.collapsed(offset: keyword.length);
                    _onChanged();
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// 结果栏目：歌曲 → 专辑 → 歌手 → 歌单 → 合集，空栏目不渲染
  List<Widget> _resultSections(BuildContext context, {required bool tv}) {
    final max = tv ? _tvSectionMax : _wideSectionMax;
    final sections = <Widget>[];

    void add(String key, String title, int count, Widget Function(int) card) {
      if (count <= 0) return;
      final shown = count > max ? max : count;
      sections.add(
        _Section(
          title: title,
          big: tv,
          count: shown,
          itemBuilder: card,
          focusNodes: _cards[key],
          onKey: _handleCardKey,
          sectionKey: key,
        ),
      );
    }

    add('songs', tr('music.search.sectionSongs'), _tracks.length, (i) {
      final track = _tracks[i];
      return _ResultCard(
        title: track.title,
        subtitle: track.artist ?? '',
        coverId: track.id,
        focusNode: _cards['songs']?[i],
        onTap: () {
          unawaited(_remember(_query));
          musicPlayTracks(context, _tracks, i);
        },
      );
    });
    add('albums', tr('music.search.sectionAlbums'), _albums.length, (i) {
      final album = _albums[i];
      return _ResultCard(
        title: album.name,
        subtitle: album.artist ?? '',
        coverId: album.coverTrackId,
        focusNode: _cards['albums']?[i],
        onTap: () => _openGroup(title: album.name, album: album.name),
      );
    });
    add('artists', tr('music.search.sectionArtists'), _artists.length, (i) {
      final artist = _artists[i];
      return _ResultCard(
        title: artist.name,
        subtitle: '${artist.albums} ${tr('music.search.sectionAlbums')}',
        coverId: artist.coverTrackId,
        circular: true,
        focusNode: _cards['artists']?[i],
        onTap: () => _openGroup(title: artist.name, artist: artist.name),
      );
    });
    add('playlists', tr('music.search.sectionPlaylists'), _playlists.length, (i) {
      final playlist = _playlists[i];
      return _ResultCard(
        title: playlist.name,
        subtitle: '${playlist.tracks}',
        coverId: playlist.coverTrackId,
        focusNode: _cards['playlists']?[i],
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MusicPlaylistDetailPage(playlist: playlist),
          ),
        ),
      );
    });
    add('collections', tr('music.search.sectionCollections'), _collections.length, (i) {
      final collection = _collections[i];
      return _ResultCard(
        title: collection.name,
        subtitle: '${collection.tracks}',
        coverId: collection.coverTrackId,
        focusNode: _cards['collections']?[i],
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => MusicCollectionDetailPage(collection: collection),
          ),
        ),
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
}

/// 一个栏目：大号粗体标题 + 一行卡片（TV 不横向滚动，最多 5 张）
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.count,
    required this.itemBuilder,
    required this.focusNodes,
    required this.onKey,
    required this.sectionKey,
    this.big = true,
  });

  final String title;
  final int count;
  final Widget Function(int index) itemBuilder;
  final List<FocusNode>? focusNodes;
  final KeyEventResult Function(String sectionKey, int index, KeyEvent event) onKey;
  final String sectionKey;
  final bool big;

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
            style: TextStyle(
              fontSize: big ? 24 : 18,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        SizedBox(
          height: big ? 200 : 180,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            // TV 侧关掉滚动：卡片数已限到 5 张，一次放得下
            physics: big ? const NeverScrollableScrollPhysics() : null,
            padding: const EdgeInsets.symmetric(horizontal: NasTokens.spaceMd),
            itemCount: count,
            separatorBuilder: (_, _) => SizedBox(width: big ? 14 : 12),
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
///
/// 聚焦时描边 + 浅色底 + 自动滚进可视区 —— 遥控器上「焦点在哪」必须一眼看得见。
class _ResultCard extends StatefulWidget {
  const _ResultCard({
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
  State<_ResultCard> createState() => _ResultCardState();
}

class _ResultCardState extends State<_ResultCard> {
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
    final focused = widget.focusNode?.hasFocus ?? false;
    if (!mounted || focused == _focused) return;
    setState(() => _focused = focused);
    if (focused) {
      // 跨栏目跳转后，新卡片可能还在屏幕外
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Scrollable.ensureVisible(
          context,
          duration: const Duration(milliseconds: 160),
          alignment: 0.5,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final size = widget.circular ? 92.0 : 128.0;
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        width: 140,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: _focused ? scheme.primary.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          border: Border.all(
            color: _focused ? scheme.primary : Colors.transparent,
            width: 2,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(
                widget.circular ? size / 2 : NasTokens.radiusSm,
              ),
              child: widget.coverId == null
                  ? Container(
                      width: size,
                      height: size,
                      color: context.nasStyle.panelColor,
                      child: Icon(Icons.music_note, color: context.nasTextSecondary),
                    )
                  : SizedBox(
                      width: size,
                      height: size,
                      child: NasCoverImage(
                        url: musicCoverUrl(widget.coverId!),
                        borderRadius: widget.circular ? size / 2 : NasTokens.radiusSm,
                        cacheWidth: 320,
                        fallbackText: widget.title,
                      ),
                    ),
            ),
            const SizedBox(height: 10),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
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
    );
  }
}

/// 屏上键盘的一个键：聚焦时放大 + 描边 + 投影（遥控器要能看见当前在哪）。
class _KeyCap extends StatefulWidget {
  const _KeyCap({
    required this.label,
    required this.onTap,
    required this.onKey,
    this.focusNode,
    this.big = false,
  });

  final String label;
  final VoidCallback onTap;
  final KeyEventResult Function(KeyEvent event) onKey;
  final FocusNode? focusNode;
  final bool big;

  @override
  State<_KeyCap> createState() => _KeyCapState();
}

class _KeyCapState extends State<_KeyCap> {
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
    return AnimatedScale(
      scale: _focused ? 1.06 : 1.0,
      duration: const Duration(milliseconds: 110),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          focusNode: widget.focusNode,
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 110),
            height: widget.big ? 56 : 44,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _focused
                  ? scheme.primary.withValues(alpha: 0.22)
                  : context.nasStyle.panelColor,
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
              border: Border.all(
                color: _focused ? scheme.primary : context.nasStyle.panelBorderColor,
                width: _focused ? 2 : 1,
              ),
              boxShadow: _focused
                  ? <BoxShadow>[
                      BoxShadow(
                        color: scheme.primary.withValues(alpha: 0.45),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ]
                  : null,
            ),
            child: Text(
              widget.label,
              style: TextStyle(
                fontSize: widget.big ? 24 : 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
