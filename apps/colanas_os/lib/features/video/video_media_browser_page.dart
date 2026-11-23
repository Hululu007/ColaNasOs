import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../core/settings_store.dart';
import '../../shell/app_widgets.dart';
import '../../shell/shell_back.dart';

import '../../core/session.dart';
import 'video_card.dart';
import 'video_media_viewer_page.dart' show openVideoPlayer;
import 'video_page.dart';
import 'video_series_widgets.dart' show episodeStillFallbackUrl;

/// 媒体浏览：库 → 来源 → 目录 三层。
///
/// 为什么不是「一个下拉框 + 直接铺库根」：
///   * 一个库可以挂多个来源（几个盘 / 几台 SMB），只认库根的话第二个来源永远进不去；
///   * 库里除了影片还有海报、`*.nfo`、字幕这些副产物，铺出来满屏垃圾。
///
/// 卡片与网格尺寸**照对应库的影视列表来**：
///   * 电影 / 电视剧 / 短剧 / 日本电影库 → `VideoPosterCard`（2:3 竖版封面、
///     刮削名、年份 / 分辨率 / 片长），网格算法与 `video_list_view` 一致；
///   * 图片库 / 混合库 → 4:3 缩略图格（与图片库列表一致），图片也显示。
///
/// 右上角「封面图 / 缩略图」切换：封面图 = 刮削海报（默认，用户要的是封面不是截图），
/// 缩略图 = 视频截图（横版 3:2，与列表的「横版剧照」格子同高）。
///
/// 电视剧库按「一部剧一张卡」聚合：逐集铺卡对剧库完全不可用（40 集 = 40 张同样的
/// 海报），点剧卡才展开这一部剧的集。
class VideoMediaBrowserPage extends StatefulWidget {
  const VideoMediaBrowserPage({super.key, this.initialLibraryId});

  /// 从某个库入口进来时直接停在该库的「来源」层
  final String? initialLibraryId;

  @override
  State<VideoMediaBrowserPage> createState() => _VideoMediaBrowserPageState();
}

class _VideoMediaBrowserPageState extends State<VideoMediaBrowserPage> {
  static const String _keyThumb = 'video.browse.thumb';

  bool _libLoading = true;
  bool _loading = false;
  String? _error;

  List<VideoLibraryItem> _libraries = const [];
  String? _libraryId;
  String? _sourceId;
  String _path = '';

  /// 当前目录的绝对根（本地相对 files 根 / SMB 为 UNC），缩略图要用
  String _rootPath = '';
  String _sourceName = '';
  List<VideoBrowseItem> _items = const [];

  /// 剧集库里点开的「一部剧」（按剧名聚合后的 key）；非空时只看这一部剧的集
  String? _seriesKey;

  /// false = 封面图（刮削海报），true = 缩略图（视频截图）
  bool _thumb = false;

  @override
  void initState() {
    super.initState();
    _thumb = SettingsStore.instance.getBool(_keyThumb) ?? false;
    _loadLibraries();
  }

  // ------------------------------------------------------------------ 数据

  Future<void> _loadLibraries() async {
    setState(() => _libLoading = true);
    try {
      final res = await ApiSession.instance.client.videoLibraryList();
      if (!mounted) return;
      final libs = res.items;
      final wanted = widget.initialLibraryId;
      final pick = (wanted != null && libs.any((l) => l.id == wanted)) ? wanted : null;
      setState(() {
        _libraries = libs;
        _libraryId = pick;
        _libLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _libLoading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _load() async {
    final libId = _libraryId;
    final sourceId = _sourceId;
    if (libId == null || sourceId == null) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.videoBrowse(
        libraryId: libId,
        sourceId: sourceId,
        path: _path.isEmpty ? null : _path,
      );
      if (!mounted) return;
      setState(() {
        _items = res.items;
        _rootPath = res.rootPath;
        _sourceName = res.sourceName ?? _sourceName;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  VideoLibraryItem? get _library {
    for (final lib in _libraries) {
      if (lib.id == _libraryId) return lib;
    }
    return null;
  }

  VideoSourceItem? get _source {
    final lib = _library;
    if (lib == null || _sourceId == null) return null;
    for (final s in lib.sources ?? const <VideoSourceItem>[]) {
      if (s.id == _sourceId) return s;
    }
    return null;
  }

  String get _libType => _library?.libType ?? 'movie';

  /// 图片库 / 混合库：图片也显示（与图片库列表同口径）；其余库只显示影片
  bool get _showsImages => _libType == 'image' || _libType == 'mixed';

  /// 剧集类库：按剧名聚合成一张卡
  bool get _isSeriesLib => _libType == 'tv' || _libType == 'short_tv';

  // ------------------------------------------------------------------ 导航

  void _openLibrary(VideoLibraryItem lib) {
    setState(() {
      _libraryId = lib.id;
      _sourceId = null;
      _path = '';
      _seriesKey = null;
      _items = const [];
      _error = null;
    });
  }

  void _openSource(VideoSourceItem src) {
    setState(() {
      _sourceId = src.id;
      _path = '';
      _seriesKey = null;
      _rootPath = src.path;
      _sourceName = '';
    });
    _load();
  }

  void _enter(VideoBrowseItem item) {
    setState(() {
      _path = item.path;
      _seriesKey = null;
    });
    _load();
  }

  void _openSeries(String key) => setState(() => _seriesKey = key);

  void _setThumb(bool thumb) {
    if (_thumb == thumb) return;
    setState(() => _thumb = thumb);
    SettingsStore.instance.setBool(_keyThumb, thumb);
  }

  /// 返回：集列表 → 目录 → 来源 → 库
  void _up() {
    if (_seriesKey != null) {
      setState(() => _seriesKey = null);
      return;
    }
    if (_path.isNotEmpty) {
      final parts = _path.split('/');
      parts.removeLast();
      setState(() => _path = parts.join('/'));
      _load();
      return;
    }
    if (_sourceId != null) {
      setState(() {
        _sourceId = null;
        _items = const [];
        _error = null;
      });
      return;
    }
    if (_libraryId != null) {
      setState(() {
        _libraryId = null;
        _error = null;
      });
    }
  }

  /// 0 = 库列表，1 = 来源列表，2 = 目录
  int get _level {
    if (_libraryId == null) return 0;
    if (_sourceId == null) return 1;
    return 2;
  }

  // ------------------------------------------------------------------ 动作

  /// 浏览条目里带的完整条目（已索引才有）
  VideoItem? _videoItemOf(VideoBrowseItem it) {
    final raw = it.item;
    if (raw is! Map) return null;
    try {
      return VideoItem.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }

  /// 文件夹里只有一条影片时，服务端会附带这条影片；有它就别再显示文件夹
  VideoItem? _singleVideoOf(VideoBrowseItem dir) {
    final raw = dir.singleVideo;
    if (raw is! Map) return null;
    try {
      return VideoItem.fromJson(Map<String, dynamic>.from(raw));
    } catch (_) {
      return null;
    }
  }

  void _openVideo(VideoBrowseItem it) {
    final item = _videoItemOf(it);
    if (item == null) {
      NasSnack.show(context, tr('video.browse.unindexed'));
      return;
    }
    openVideoDetail(context, item);
  }

  /// 直接播放：播放器入口与影视列表里点开一条影片走的是同一个
  /// （`openVideoPlayer` → `PlayerPage`，同样的转码 / 兼容 / 进度上报）。
  /// 带上当前目录里能播的影片当播放列表，播放器里才能上下切集。
  void _play(VideoItem item) {
    final playlist = <VideoItem>[];
    for (final e in _entries()) {
      if (e.video != null) {
        playlist.add(e.video!);
      } else if (e.item != null &&
          !e.item!.dir &&
          e.item!.mediaType == 'video') {
        final v = _videoItemOf(e.item!);
        if (v != null) playlist.add(v);
      }
    }
    openVideoPlayer(
      context,
      item,
      playlist: playlist.length > 1 ? playlist : null,
    );
  }

  void _openImage(VideoBrowseItem item) {
    final fullPath = _joinPath(_rootPath, item.path);
    final token = ApiSession.instance.token;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          appBar: AppBar(title: Text(item.name)),
          body: InteractiveViewer(
            maxScale: 6,
            child: Center(
              child: NasCoverImage(
                url:
                    '${ApiSession.instance.baseUrl}/api/v1/files/download?path=${Uri.encodeComponent(fullPath)}&inline=1',
                headers: token == null
                    ? const {}
                    : {'Authorization': 'Bearer $token'},
                cacheWidth: 2000,
                icon: Icons.broken_image_outlined,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 右键菜单：目录只给「打开 / 复制路径 / 删除」；影片和图片多一条语义化入口，
  /// 其余动作（刮削、改匹配）在详情页里做。
  List<NasMenuEntry> _browseMenuEntries(VideoBrowseItem item) {
    final full = _joinPath(_rootPath, item.path);
    return [
      NasMenuEntry(
        label: tr('common.open'),
        icon: item.dir ? Icons.folder_open_outlined : Icons.play_arrow_outlined,
        onSelected: item.dir
            ? () => _enter(item)
            : item.mediaType == 'video'
                ? () => _openVideo(item)
                : item.mediaType == 'image'
                    ? () => _openImage(item)
                    : null,
      ),
      NasMenuEntry(
        label: tr('video.action.copyPath'),
        icon: Icons.copy_all_outlined,
        onSelected: full.isEmpty ? null : () => _copyPath(full),
      ),
      const NasMenuEntry.divider(),
      NasMenuEntry(
        label: tr('common.delete'),
        icon: Icons.delete_outline,
        danger: true,
        onSelected: () => _confirmDelete(
          path: item.path,
          name: item.dir ? item.name : _stripExt(item.name),
          isFolder: item.dir,
        ),
      ),
    ];
  }

  String _joinPath(String root, String rel) {
    if (rel.isEmpty) return root.replaceAll(RegExp(r'^/+'), '');
    if (root.isEmpty) return rel;
    return '$root/$rel'.replaceAll(RegExp(r'/+'), '/').replaceAll(RegExp(r'^/+'), '');
  }

  Future<void> _copyPath(String path) async {
    final messenger = ScaffoldMessenger.of(context);
    await Clipboard.setData(ClipboardData(text: path));
    NasSnack.showOn(messenger, tr('common.copied'));
  }

  /// 删除一个文件 / 整个文件夹（进回收站，索引一起清）
  Future<void> _confirmDelete({
    required String path,
    required String name,
    required bool isFolder,
  }) async {
    final libId = _libraryId;
    if (libId == null || path.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('common.delete')),
        content: Text(
          isFolder
              ? tr('video.browse.deleteFolderBody', {'name': name})
              : tr('files.deleteConfirm', {'name': name}),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('common.cancel'))),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final res = await ApiSession.instance.client.videoBrowseDelete(
        body: VideoBrowseDeleteBody(
          libraryId: libId,
          sourceId: _sourceId,
          path: path,
        ),
      );
      if (!mounted) return;
      if (res.failed > 0) {
        NasSnack.show(
          context,
          tr('video.dup.deletePartial', {
            'done': '${res.removed}',
            'failed': '${res.failed}',
          }),
        );
      } else {
        NasSnack.show(context, tr('files.deletedToTrash'));
      }
      // 删掉的是当前目录里的东西 → 刷新列表；删的是当前所在的文件夹 → 退一级
      if (isFolder && _path == path) {
        _up();
      } else {
        await _load();
      }
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, tr('common.deleteFailed', {'error': '$e'}));
    }
  }

  // ------------------------------------------------------------------ 构建

  @override
  Widget build(BuildContext context) {
    return SubPageScope(
      active: _level > 0,
      onBack: _up,
      child: _buildPage(context),
    );
  }

  Widget _buildPage(BuildContext context) {
    if (_libLoading) return const NasLoading();
    if (_libraries.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.browse.noLibrary'),
            icon: Icons.video_library_outlined,
          ),
        ],
      );
    }
    return Column(
      children: [
        _toolbar(),
        Expanded(child: _body()),
      ],
    );
  }

  Widget _body() {
    switch (_level) {
      case 0:
        return _libraryGrid();
      case 1:
        return _sourceList();
      default:
        if (_error != null) {
          return NasErrorState(message: _error!, onRetry: _load);
        }
        if (_loading) return const NasLoading();
        return _folderBody();
    }
  }

  Widget _toolbar() {
    final lib = _library;
    final canUp = _level > 0;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceSm,
        NasTokens.spaceXs,
        NasTokens.spaceXs,
        NasTokens.spaceXs,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: tr('common.back'),
            onPressed: canUp ? _up : null,
            icon: const Icon(Icons.arrow_back),
          ),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: _crumbs(lib),
              ),
            ),
          ),
          // 封面图 / 缩略图：只在影片库有意义（图片库里「封面」就是图片本身）
          if (_level == 2 && !_showsImages) ...[
            _viewBtn(
              icon: Icons.crop_portrait,
              tooltip: tr('video.browse.cover'),
              active: !_thumb,
              onTap: () => _setThumb(false),
            ),
            _viewBtn(
              icon: Icons.crop_16_9,
              tooltip: tr('video.browse.thumb'),
              active: _thumb,
              onTap: () => _setThumb(true),
            ),
            const SizedBox(width: NasTokens.spaceXs),
          ],
          if (_level == 2) NasRefreshButton(onPressed: _load),
        ],
      ),
    );
  }

  /// 面包屑：每一段都能点，点哪段回到哪一层（库 → 来源 → 一级级目录）
  List<Widget> _crumbs(VideoLibraryItem? lib) {
    final crumbs = <({String label, VoidCallback onTap})>[];
    if (lib != null) {
      crumbs.add((label: lib.name, onTap: _goLibraries));
    }
    if (lib != null && _sourceId != null) {
      final label = _sourceName.isNotEmpty ? _sourceName : _sourceLabel(_source);
      if (label.isNotEmpty) crumbs.add((label: label, onTap: _goSourceRoot));
    }
    final segs = _path.split('/').where((s) => s.isNotEmpty).toList();
    for (var i = 0; i < segs.length; i += 1) {
      final prefix = segs.take(i + 1).join('/');
      crumbs.add((label: segs[i], onTap: () => _goPath(prefix)));
    }
    final key = _seriesKey;
    if (key != null) {
      crumbs.add((label: key, onTap: () => setState(() => _seriesKey = null)));
    }

    final style = TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary);
    final linkStyle = TextStyle(
      fontSize: NasTokens.fontCaption,
      color: Theme.of(context).colorScheme.primary,
    );
    if (crumbs.isEmpty) {
      return [
        Text('# ${tr('video.browse.title')}', style: style),
      ];
    }
    final out = <Widget>[
      Padding(
        padding: const EdgeInsets.only(right: 4),
        child: Text('#', style: style),
      ),
    ];
    for (var i = 0; i < crumbs.length; i += 1) {
      if (i > 0) out.add(Text(' / ', style: style));
      final last = i == crumbs.length - 1;
      final c = crumbs[i];
      out.add(
        InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: c.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
            child: Text(c.label, style: last ? style : linkStyle),
          ),
        ),
      );
    }
    return out;
  }

  /// 回到库列表
  void _goLibraries() {
    setState(() {
      _libraryId = null;
      _sourceId = null;
      _path = '';
      _seriesKey = null;
      _items = const [];
      _error = null;
    });
  }

  /// 回到当前来源根
  void _goSourceRoot() {
    if (_path.isEmpty && _seriesKey == null) return;
    setState(() {
      _path = '';
      _seriesKey = null;
    });
    _load();
  }

  /// 跳到某一级目录
  void _goPath(String path) {
    if (_path == path && _seriesKey == null) return;
    setState(() {
      _path = path;
      _seriesKey = null;
    });
    _load();
  }

  Widget _viewBtn({
    required IconData icon,
    required String tooltip,
    required bool active,
    required VoidCallback onTap,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      tooltip: tooltip,
      onPressed: onTap,
      iconSize: 19,
      visualDensity: VisualDensity.compact,
      style: active
          ? IconButton.styleFrom(backgroundColor: scheme.primary.withValues(alpha: 0.14))
          : null,
      icon: Icon(icon, color: active ? scheme.primary : null),
    );
  }

  String _sourceLabel(VideoSourceItem? src) {
    if (src == null) return '';
    if (src.connType == 'smb') {
      final base = [src.host ?? '', src.share ?? ''].where((s) => s.isNotEmpty).join('/');
      final sub = (src.subPath ?? '').replaceAll('\\', '/').replaceAll(RegExp(r'^\/+|\/+$'), '');
      return sub.isEmpty ? base : '$base/$sub';
    }
    final segs = src.path
        .replaceAll('\\', '/')
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (segs.isEmpty) return src.path;
    return segs.length <= 2 ? segs.join('/') : segs.sublist(segs.length - 2).join('/');
  }

  // ------------------------------------------------------------ 第 1 层：库

  String _typeLabel(String libType) {
    switch (libType) {
      case 'image':
        return tr('video.library.type.image');
      case 'mixed':
        return tr('video.library.type.mixed');
      case 'tv':
        return tr('video.library.type.tv');
      case 'short_tv':
        return tr('video.library.type.shortTv');
      case 'jp_movie':
        return tr('video.library.type.jp');
      default:
        return tr('video.library.type.movie');
    }
  }

  IconData _typeIcon(String libType) {
    switch (libType) {
      case 'image':
      case 'mixed':
        return Icons.photo_library_outlined;
      case 'tv':
      case 'short_tv':
        return Icons.live_tv_outlined;
      case 'jp_movie':
        return Icons.local_movies_outlined;
      default:
        return Icons.movie_outlined;
    }
  }

  Widget _libraryGrid() {
    return LayoutBuilder(
      builder: (context, c) {
        final columns = gridColumns(c.maxWidth);
        return GridView.builder(
          padding: const EdgeInsets.all(NasTokens.spaceSm),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: NasTokens.spaceSm,
            mainAxisSpacing: NasTokens.spaceSm,
            mainAxisExtent: 76,
          ),
          itemCount: _libraries.length,
          itemBuilder: (context, i) {
            final lib = _libraries[i];
            final sources = (lib.sources ?? const <VideoSourceItem>[]).length;
            return _entryCard(
              icon: _typeIcon(lib.libType),
              title: lib.name,
              subtitle: tr('video.library.meta', {
                'type': _typeLabel(lib.libType),
                'sources': '$sources',
                'count': '${lib.items}',
              }),
              onTap: () => _openLibrary(lib),
            );
          },
        );
      },
    );
  }

  // ------------------------------------------------------------ 第 2 层：来源

  Widget _sourceList() {
    final lib = _library;
    final sources = lib?.sources ?? const <VideoSourceItem>[];
    if (sources.isEmpty) {
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.browse.noSource'),
            icon: Icons.folder_off_outlined,
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final columns = gridColumns(c.maxWidth);
        return GridView.builder(
          padding: const EdgeInsets.all(NasTokens.spaceSm),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: NasTokens.spaceSm,
            mainAxisSpacing: NasTokens.spaceSm,
            mainAxisExtent: 76,
          ),
          itemCount: sources.length,
          itemBuilder: (context, i) {
            final src = sources[i];
            final offline = src.onlineState == 2;
            return _entryCard(
              icon: src.connType == 'smb' ? Icons.dns_outlined : Icons.folder_outlined,
              title: _sourceLabel(src),
              subtitle: offline
                  ? tr('video.source.offline')
                  : tr('video.libSummary', {
                      'path': src.path,
                      'count': '${src.items ?? 0}',
                    }),
              subtitleColor: offline ? Theme.of(context).colorScheme.error : null,
              onTap: () => _openSource(src),
            );
          },
        );
      },
    );
  }

  // ------------------------------------------------------------ 第 3 层：目录

  Widget _folderBody() {
    final entries = _entries();
    if (entries.isEmpty) {
      // 目录里只有 nfo / 字幕 / 图片这类文件时，同样按「没有媒体」处理，
      // 否则会留一整片空白让人以为没加载出来。
      return ListView(
        children: [
          NasEmptyState(
            title: tr('video.browse.empty'),
            icon: Icons.folder_open_outlined,
          ),
        ],
      );
    }
    return LayoutBuilder(
      builder: (context, c) => _showsImages
          ? _imageGrid(c.maxWidth, entries)
          : _posterGrid(c.maxWidth, entries),
    );
  }

  /// 影片库网格：参数与 `video_list_view#_grid` 逐项对齐（间距 / 文字区 /
  /// 基础宽度 / 列数夹取）；缩略图模式按「同样的格子高度、更宽的格子」算列数。
  Widget _posterGrid(double maxW, List<_BrowseEntry> entries) {
    final spacing = maxW < 480 ? 8.0 : 12.0;
    const textBlock = 42.0;
    final baseWidth = maxW < 480 ? 108.0 : 132.0;
    final posterTileHeight = baseWidth * 1.5 + textBlock;
    final targetWidth = _thumb ? (posterTileHeight - textBlock) * (3 / 2) : baseWidth;
    final columns = (maxW / targetWidth).floor().clamp(2, 9);
    final itemWidth =
        ((maxW - spacing * (columns - 1) - spacing) / columns).floorToDouble();
    final imageHeight = _thumb ? itemWidth / (3 / 2) : itemWidth * 1.5;
    final tileHeight = imageHeight + textBlock;
    return GridView.builder(
      padding: EdgeInsets.all(spacing),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        childAspectRatio: itemWidth / tileHeight,
      ),
      itemCount: entries.length,
      itemBuilder: (context, i) => _tile(entries[i], itemWidth, imageHeight),
    );
  }

  /// 图片库 / 混合库网格：与图片库列表同款（4:3 图区 + 标题），图片和视频都出。
  Widget _imageGrid(double maxW, List<_BrowseEntry> entries) {
    const spacing = 12.0;
    final target = maxW < 520 ? 120.0 : 176.0;
    final columns = (maxW / (target + spacing)).floor().clamp(2, 12);
    final itemWidth = (maxW - spacing * (columns - 1)) / columns;
    final imageHeight = itemWidth * 3 / 4;
    final tileHeight = imageHeight + 22;
    return GridView.builder(
      padding: const EdgeInsets.all(spacing),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        mainAxisSpacing: spacing,
        crossAxisSpacing: spacing,
        mainAxisExtent: tileHeight,
      ),
      itemCount: entries.length,
      itemBuilder: (context, i) => _tile(entries[i], itemWidth, imageHeight),
    );
  }

  /// 目录项 → 展示条目。过滤规则在这里，别散到各渲染分支里：
  ///   * 文件夹显示；但**只有一条影片的文件夹直接铺那条影片**（一点即播）；
  ///   * 影片显示；
  ///   * 图片只在图片库 / 混合库显示；
  ///   * 其它（`.nfo` / 字幕 / 海报 / 说明文件）一律不显示。
  List<_BrowseEntry> _entries() {
    final visible = _items.where((it) {
      if (it.dir) return true;
      if (it.mediaType == 'video') return true;
      if (it.mediaType == 'image') return _showsImages;
      return false;
    });

    // 已点进某部剧：只留这一部剧的集（文件夹层已经被服务端聚合掉了）
    final key = _seriesKey;
    final out = <_BrowseEntry>[];
    final videos = <VideoBrowseItem>[];

    for (final it in visible) {
      if (it.dir) {
        // 图片库 / 混合库里文件夹还装着图片，不折叠
        final single = _showsImages ? null : _singleVideoOf(it);
        if (single == null) {
          if (key == null) out.add(_BrowseEntry.item(it));
          continue;
        }
        if (key == null) {
          out.add(_BrowseEntry.video(single, it));
        } else {
          final name = single.path.split('/').last;
          if (_seriesKeyOf(name) == key) out.add(_BrowseEntry.video(single, it));
        }
        continue;
      }
      if (it.mediaType == 'video') {
        videos.add(it);
        continue;
      }
      if (key == null) out.add(_BrowseEntry.item(it));
    }

    if (key != null) {
      return [
        ...out,
        for (final it in videos)
          if (_seriesKeyOf(it.name) == key) _BrowseEntry.item(it),
      ];
    }

    if (!_isSeriesLib) {
      return [...out, for (final it in videos) _BrowseEntry.item(it)];
    }

    // 剧集库：视频按剧名聚合（一部剧一张卡），单集仍按影片卡显示
    final groups = <String, List<VideoBrowseItem>>{};
    for (final it in videos) {
      groups.putIfAbsent(_seriesKeyOf(it.name), () => []).add(it);
    }
    for (final entry in groups.entries) {
      out.add(
        entry.value.length == 1
            ? _BrowseEntry.item(entry.value.first)
            : _BrowseEntry.series(entry.key, entry.value),
      );
    }
    return out;
  }

  /// 去掉集数后缀当剧名（`某剧 S01E03.mkv` → `某剧`）。
  ///
  /// ⛔ 不认「光秃秃的数字」：这类写法会把《2012》砍成「20」。
  static final RegExp _episodeSuffix = RegExp(
    r'\s*(?:[-–—]\s*)?(?:第\s*\d+\s*[集话話]|EP?\s*\d+|S\d+\s*E\d+|[-–—]\s*\d{1,3})\s*$',
    caseSensitive: false,
  );

  static String _seriesKeyOf(String name) {
    final base = _stripExt(name).trim();
    final stripped = base.replaceFirst(_episodeSuffix, '').trim();
    return stripped.isEmpty ? base : stripped;
  }

  static String _stripExt(String name) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return name;
    final ext = name.substring(dot + 1).toLowerCase();
    const media = {
      'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'ts', 'm2ts',
      'rmvb', 'mpg', 'mpeg', 'iso',
    };
    return media.contains(ext) ? name.substring(0, dot) : name;
  }

  // ------------------------------------------------------------ 单张卡

  Widget _tile(_BrowseEntry entry, double width, double imageH) {
    if (entry.kind == _BrowseEntryKind.series) {
      return _seriesCard(entry, width, imageH);
    }
    if (entry.kind == _BrowseEntryKind.video) {
      // 文件夹里只有这一条影片：直接当影片卡显示，一点就播
      final item = entry.video!;
      return NasContextMenuRegion(
        entries: _singleVideoMenuEntries(entry),
        child: VideoPosterCard(
          item: item,
          width: width,
          showFanart: _thumb,
          onTap: () => _play(item),
        ),
      );
    }
    final it = entry.item!;
    if (it.dir) return _folderCard(it, width, imageH);
    if (_showsImages) return _imageCell(it, width, imageH);
    final item = _videoItemOf(it);
    if (item == null) return _missingCard(it, width, imageH);
    return NasContextMenuRegion(
      entries: _browseMenuEntries(it),
      child: VideoPosterCard(
        item: item,
        width: width,
        showFanart: _thumb,
        onTap: () => openVideoDetail(context, item),
      ),
    );
  }

  /// 单影片文件夹的右键菜单：播放 / 复制影片路径 / 打开所在文件夹 / 删除文件夹
  List<NasMenuEntry> _singleVideoMenuEntries(_BrowseEntry entry) {
    final item = entry.video!;
    final folder = entry.folder!;
    return [
      NasMenuEntry(
        label: tr('video.series.play'),
        icon: Icons.play_arrow_outlined,
        onSelected: () => _play(item),
      ),
      NasMenuEntry(
        label: tr('video.action.copyPath'),
        icon: Icons.copy_all_outlined,
        onSelected: () => _copyPath(item.path),
      ),
      NasMenuEntry(
        label: tr('video.browse.openFolder'),
        icon: Icons.folder_open_outlined,
        onSelected: () => _enter(folder),
      ),
      const NasMenuEntry.divider(),
      NasMenuEntry(
        label: tr('common.delete'),
        icon: Icons.delete_outline,
        danger: true,
        // 这张卡代表整个文件夹（一片一目录），删就删文件夹，别留个只剩 nfo 的空壳
        onSelected: () => _confirmDelete(
          path: folder.path,
          name: folder.name,
          isFolder: true,
        ),
      ),
    ];
  }

  /// 图片库 / 混合库的格子：固定 4:3 图区 + 一行名字（与图片库列表一致）
  Widget _imageCell(VideoBrowseItem it, double width, double imageH) {
    final base = ApiSession.instance.baseUrl;
    final token = ApiSession.instance.token;
    final headers =
        token == null ? const <String, String>{} : {'Authorization': 'Bearer $token'};
    final item = _videoItemOf(it);
    final url = item != null && item.mediaType == 'video'
        ? videoPosterUrl(item, size: (width * 2).round())
        : '$base/api/v1/files/thumb?path=${Uri.encodeComponent(_joinPath(_rootPath, it.path))}&size=${(width * 2).round()}';
    return NasContextMenuRegion(
      entries: _browseMenuEntries(it),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => it.mediaType == 'video' ? _openVideo(it) : _openImage(it),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: imageH,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: NasCoverImage(
                  url: url,
                  headers: headers,
                  fit: BoxFit.cover,
                  fallbackText: _stripExt(it.name),
                  icon: it.mediaType == 'video'
                      ? Icons.movie_outlined
                      : Icons.image_outlined,
                  cacheWidth: (width * 2).round(),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2),
              child: Text(
                _stripExt(it.name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: NasTokens.fontMicro),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 文件夹卡：与影片卡同宽同高的图区，里面放文件夹图标
  Widget _folderCard(VideoBrowseItem it, double width, double imageH) {
    return NasContextMenuRegion(
      entries: _browseMenuEntries(it),
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onTap: () => _enter(it),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: imageH,
              child: Container(
                decoration: BoxDecoration(
                  color: context.nasStyle.panelColor,
                  borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                  border: Border.all(color: context.nasStyle.panelBorderColor),
                ),
                child: const Center(child: Icon(Icons.folder_outlined, size: 40)),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              it.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: NasTokens.fontCaption,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 还没索引的影片：没有封面也没有详情，只给图标 + 文件名 + 大小
  Widget _missingCard(VideoBrowseItem it, double width, double imageH) {
    final size = it.size ?? 0;
    return NasContextMenuRegion(
      entries: _browseMenuEntries(it),
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onTap: () => _openVideo(it),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: imageH,
              child: Container(
                decoration: BoxDecoration(
                  color: context.nasStyle.panelColor,
                  borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                  border: Border.all(color: context.nasStyle.panelBorderColor),
                ),
                child: Center(
                  child: Icon(
                    Icons.movie_outlined,
                    size: 36,
                    color: context.nasTextSecondary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _stripExt(it.name),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: NasTokens.fontCaption,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              size > 0 ? formatBytes(size) : tr('video.browse.unindexed'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: NasTokens.fontMicro,
                color: context.nasTextSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 剧集卡：封面位 + 剧名 + 集数，右上角集数角标（与剧集列表同款配色）
  Widget _seriesCard(_BrowseEntry entry, double width, double imageH) {
    final items = entry.items!;
    VideoItem? cover;
    for (final it in items) {
      final v = _videoItemOf(it);
      if (v != null) {
        cover = v;
        break;
      }
    }
    final width2 = (width * 2).round();
    // 缩略图 = 库里现成的横版图（`-backdrop.jpg` / fanart），缺图退回竖版海报，
    // 绝不拿首帧截图凑
    final still = cover == null || !cover.hasArt ? null : episodeStillFallbackUrl(cover.id);
    final posterArt = cover == null || !cover.hasArt ? null : videoArtUrl(cover, size: width2);
    final url = cover == null
        ? null
        : (_thumb
              ? videoPosterUrl(cover, kind: 'fanart', size: width2)
              : videoPosterUrl(cover, size: width2));
    return InkWell(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      onTap: () => _openSeries(entry.seriesKey!),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: imageH,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(NasTokens.radiusSm),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (url == null)
                    ColoredBox(
                      color: context.nasStyle.panelColor,
                      child: const Center(
                        child: Icon(Icons.video_library_outlined, size: 36),
                      ),
                    )
                  else
                    NasCoverImage(
                      url: url,
                      fallbackUrl: _thumb ? posterArt : still,
                      headers: videoArtHeaders,
                      fallbackText: entry.seriesKey!,
                      icon: Icons.video_library_outlined,
                      cacheWidth: width2,
                    ),
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
                          gradient: LinearGradient(
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                            colors: [
                              Colors.black.withValues(alpha: 0.6),
                              Colors.transparent,
                            ],
                            stops: const [0, 0.4],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 右上角：总集数（半透明圆形角标，与剧集列表一致）
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      constraints: const BoxConstraints(minWidth: 26),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF2AA7B8).withValues(alpha: 0.92),
                        borderRadius: BorderRadius.circular(99),
                        border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
                      ),
                      child: Text(
                        '${items.length}',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            entry.seriesKey!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: NasTokens.fontCaption,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            tr('video.browse.episodeCount', {'n': '${items.length}'}),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: NasTokens.fontMicro,
              color: context.nasTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _entryCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    Color? subtitleColor,
  }) {
    return NasCard(
      padding: EdgeInsets.zero,
      child: InkWell(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(NasTokens.spaceSm),
          child: Row(
            children: [
              Icon(icon, color: context.nasTextSecondary),
              const SizedBox(width: NasTokens.spaceSm),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: subtitleColor ?? context.nasTextSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: context.nasTextSecondary),
            ],
          ),
        ),
      ),
    );
  }
}

enum _BrowseEntryKind { item, series, video }

/// 目录里的一个展示条目：文件夹 / 影片 / 图片，剧集库聚合出来的一部剧，
/// 或「只有一个影片的文件夹」折叠出来的那条影片
class _BrowseEntry {
  const _BrowseEntry.item(VideoBrowseItem this.item)
      : kind = _BrowseEntryKind.item,
        seriesKey = null,
        items = null,
        video = null,
        folder = null;

  const _BrowseEntry.series(String this.seriesKey, List<VideoBrowseItem> this.items)
      : kind = _BrowseEntryKind.series,
        item = null,
        video = null,
        folder = null;

  const _BrowseEntry.video(VideoItem this.video, VideoBrowseItem this.folder)
      : kind = _BrowseEntryKind.video,
        item = null,
        seriesKey = null,
        items = null;

  final _BrowseEntryKind kind;
  final VideoBrowseItem? item;
  final String? seriesKey;
  final List<VideoBrowseItem>? items;
  final VideoItem? video;

  /// 折叠前的那个文件夹条目（右键「打开所在文件夹」用）
  final VideoBrowseItem? folder;
}
