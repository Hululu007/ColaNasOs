import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/session.dart';
import '../../shell/mobile_frame.dart';
import 'music_track_view.dart';

/// 音乐 · 文件夹。
///
/// 第一层是「音乐来源」（一个来源一个入口，有几个显示几个）；
/// 点进去按目录逐层浏览：**只列子目录和音乐文件**，歌词 / 封面之类的
/// 附属文件不会出现在这里（目录树由曲目表反推，本来就没有它们）。
///
/// 括号里的数字是「该目录下（含子目录）一共有多少首」，用来判断值不值得点进去。
class MusicFolderPage extends StatefulWidget {
  const MusicFolderPage({super.key});

  @override
  State<MusicFolderPage> createState() => _MusicFolderPageState();
}

class _MusicFolderPageState extends State<MusicFolderPage> {
  bool _loading = true;
  String? _error;
  List<MusicLibraryItem> _libraries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.musicLibraryList();
      if (!mounted) return;
      setState(() {
        _libraries = res.items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  tr('music.nav.sources'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              IconButton(
                tooltip: tr('common.refresh'),
                icon: const Icon(Icons.refresh),
                onPressed: _load,
              ),
            ],
          ),
        ),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_libraries.isEmpty) {
      return NasEmptyState(
        title: tr('music.folder.noSource'),
        message: tr('music.folder.noSourceHint'),
        icon: Icons.folder_open,
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: NasTokens.spaceXs),
      itemCount: _libraries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final lib = _libraries[i];
        return ListTile(
          leading: Icon(Icons.folder_special_outlined,
              color: Theme.of(context).colorScheme.primary),
          title: Text(lib.name, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${lib.path} · ${tr('music.folder.tracks', {'count': '${lib.items}'})}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => MusicFolderBrowsePage(
                libraryId: lib.id,
                libraryName: lib.name,
                dir: '',
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 某一层目录：子目录列表 + 当前目录的音乐文件。
///
/// 多选状态下可以勾一批歌直接「加入播放列表」（服务端歌单）；
/// 非多选时点一行就是播放当前目录的这一批，和列表页的手感一致。
class MusicFolderBrowsePage extends StatefulWidget {
  const MusicFolderBrowsePage({
    super.key,
    required this.libraryId,
    required this.libraryName,
    required this.dir,
  });

  final String libraryId;
  final String libraryName;
  final String dir;

  @override
  State<MusicFolderBrowsePage> createState() => _MusicFolderBrowsePageState();
}

class _MusicFolderBrowsePageState extends State<MusicFolderBrowsePage> {
  bool _loading = true;
  String? _error;
  List<MusicFolderEntry> _dirs = const [];
  List<MusicTrack> _files = const [];

  bool _selecting = false;
  final Set<String> _selected = <String>{};

  String get _title {
    if (widget.dir.isEmpty) return widget.libraryName;
    final seg = widget.dir.split('/').where((s) => s.isNotEmpty).toList();
    return seg.isEmpty ? widget.libraryName : seg.last;
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.musicFolders(
        libraryId: widget.libraryId,
        dir: widget.dir,
      );
      if (!mounted) return;
      setState(() {
        _dirs = res.items;
        _files = res.files;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _toggleSelectMode() {
    setState(() {
      _selecting = !_selecting;
      if (!_selecting) _selected.clear();
    });
  }

  void _toggleOne(MusicTrack track) {
    setState(() {
      if (!_selected.remove(track.id)) _selected.add(track.id);
    });
  }

  void _selectAll() {
    setState(() {
      if (_selected.length == _files.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(_files.map((t) => t.id));
      }
    });
  }

  Future<void> _addToPlaylist() async {
    if (_selected.isEmpty) return;
    final messenger = ScaffoldMessenger.of(context);
    final playlists = await ApiSession.instance.client.musicPlaylistList();
    if (!mounted) return;
    if (playlists.items.isEmpty) {
      NasSnack.showOn(messenger, tr('ui.music.006'));
      return;
    }
    final target = await showDialog<MusicPlaylist>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: Text(tr('music.folder.addToPlaylist')),
        children: [
          for (final p in playlists.items)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, p),
              child: Text(p.name),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    try {
      await ApiSession.instance.client.musicPlaylistAdd(
        body: MusicPlaylistMembersBody(
          playlistId: target.id,
          trackIds: _selected.toList(),
        ),
      );
      NasSnack.showOn(messenger, tr('music.addedTo', {'name': target.name}));
      if (mounted) {
        setState(() {
          _selecting = false;
          _selected.clear();
        });
      }
    } catch (e) {
      NasSnack.showOn(messenger, tr('music.joinFailed', {'error': '$e'}));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: nasPageAppBar(
        context,
        title: _title,
        actions: [
          if (_selecting) ...[
            if (_files.isNotEmpty)
              IconButton(
                tooltip: tr('common.selectAll'),
                icon: const Icon(Icons.select_all),
                onPressed: _selectAll,
              ),
            IconButton(
              tooltip: tr('music.folder.addToPlaylist'),
              icon: const Icon(Icons.playlist_add),
              onPressed: _selected.isEmpty ? null : _addToPlaylist,
            ),
            IconButton(
              tooltip: tr('common.close'),
              icon: const Icon(Icons.check),
              onPressed: _toggleSelectMode,
            ),
          ] else if (_files.isNotEmpty)
            IconButton(
              tooltip: tr('music.folder.select'),
              icon: const Icon(Icons.checklist),
              onPressed: _toggleSelectMode,
            ),
        ],
      ),
      body: _body(),
      bottomNavigationBar: _selecting && _selected.isNotEmpty
          ? SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NasTokens.spaceMd,
                  vertical: NasTokens.spaceSm,
                ),
                child: FilledButton.icon(
                  onPressed: _addToPlaylist,
                  icon: const Icon(Icons.playlist_add, size: 18),
                  label: Text(tr(
                    'music.folder.selected',
                    {'count': '${_selected.length}'},
                  )),
                ),
              ),
            )
          : null,
    );
  }

  Widget _body() {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    if (_dirs.isEmpty && _files.isEmpty) {
      return NasEmptyState(
        title: tr('music.folder.empty'),
        icon: Icons.folder_open,
      );
    }
    return ListView(
      padding: const EdgeInsets.only(bottom: NasTokens.spaceXl),
      children: [
        for (final d in _dirs)
          ListTile(
            leading: Icon(Icons.folder,
                color: Theme.of(context).colorScheme.primary),
            title: Text(d.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(tr('music.folder.tracks', {'count': '${d.tracks}'})),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => MusicFolderBrowsePage(
                  libraryId: widget.libraryId,
                  libraryName: widget.libraryName,
                  dir: d.path,
                ),
              ),
            ),
          ),
        if (_files.isNotEmpty) const Divider(height: 1),
        for (var i = 0; i < _files.length; i++)
          MusicTrackRow(
            track: _files[i],
            leading: _selecting
                ? Checkbox(
                    value: _selected.contains(_files[i].id),
                    onChanged: (_) => _toggleOne(_files[i]),
                  )
                : null,
            onPlay: () {
              if (_selecting) {
                _toggleOne(_files[i]);
              } else {
                musicPlayTracks(context, _files, i);
              }
            },
          ),
      ],
    );
  }
}
