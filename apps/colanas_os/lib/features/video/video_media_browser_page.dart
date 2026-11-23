import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';
import '../../shell/app_widgets.dart';
import '../../shell/shell_back.dart';

import '../../core/session.dart';
import 'video_page.dart';

/// 媒体浏览：库 → 来源 → 目录 三层。
///
/// 为什么不是「一个下拉框 + 直接铺库根」：
///   * 一个库可以挂多个来源（几个盘 / 几台 SMB），只认库根的话第二个来源永远进不去；
///   * 库里除了影片还有海报、`*.nfo`、字幕这些副产物，铺出来满屏垃圾。
///
/// 所以这一页从「库」开始逐层下钻：库（卡片）→ 该库的来源（卡片）→ 目录（文件夹 +
/// 影片）。视频类库（电影 / 电视剧 / 短剧 / 日本电影）只显示影片和文件夹，
/// 图片与其它文件一律不显示；图片库 / 混合库按影视列表的口径，图片与视频都显示。
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

  @override
  void initState() {
    super.initState();
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
      // 从库入口进来：直接看这个库的来源列表，不自动进来源
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

  /// 图片库 / 混合库：图片也显示；其余库只显示影片
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

  Future<void> _openVideo(VideoBrowseItem item) async {
    if (item.id == null) {
      NasSnack.show(context, tr('video.browse.unindexed'));
      return;
    }
    try {
      final detail = await ApiSession.instance.client.videoItem(id: item.id!);
      if (!mounted) return;
      openVideoDetail(context, detail);
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
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

  /// 右键菜单：目录只给「打开 / 复制路径」；影片和图片多一条语义化入口，
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
    final trail = <String>[
      if (lib != null) lib.name,
      if (lib != null && _sourceId != null)
        _sourceName.isNotEmpty ? _sourceName : _sourceLabel(_source),
      if (_path.isNotEmpty) _path,
      ?_seriesKey,
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        NasTokens.spaceMd,
        NasTokens.spaceSm,
        NasTokens.spaceSm,
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
              child: Text(
                trail.isEmpty
                    ? '# ${tr('video.browse.title')}'
                    : '# ${trail.join(' / ')}',
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          ),
          if (_level == 2 && !_showsImages)
            Padding(
              padding: const EdgeInsets.only(right: NasTokens.spaceXs),
              child: Text(
                tr('video.browse.videosOnly'),
                style: TextStyle(
                  fontSize: NasTokens.fontMicro,
                  color: context.nasTextSecondary,
                ),
              ),
            ),
          if (_level == 2) NasRefreshButton(onPressed: _load),
        ],
      ),
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
      builder: (context, c) {
        final columns = gridColumns(c.maxWidth);
        return GridView.builder(
          padding: const EdgeInsets.all(NasTokens.spaceSm),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: NasTokens.spaceSm,
            mainAxisSpacing: NasTokens.spaceSm,
            childAspectRatio: 0.82,
          ),
          itemCount: entries.length,
          itemBuilder: (context, i) => _entry(entries[i]),
        );
      },
    );
  }

  /// 目录项 → 展示条目。过滤规则在这里，别散到各渲染分支里：
  ///   * 文件夹永远显示；
  ///   * 影片永远显示；
  ///   * 图片只在图片库 / 混合库显示；
  ///   * 其它（`.nfo` / 字幕 / 海报 / 说明文件）一律不显示。
  List<_BrowseEntry> _entries() {
    final items = _items.where((it) {
      if (it.dir) return true;
      if (it.mediaType == 'video') return true;
      if (it.mediaType == 'image') return _showsImages;
      return false;
    }).toList();

    // 已点进某部剧：只看这一部的集
    final key = _seriesKey;
    if (key != null) {
      return [
        for (final it in items)
          if (!it.dir && it.mediaType == 'video' && _seriesKeyOf(it.name) == key)
            _BrowseEntry.item(it),
      ];
    }

    if (!_isSeriesLib) {
      return [for (final it in items) _BrowseEntry.item(it)];
    }

    // 剧集库：文件夹照常，视频按剧名聚合（一部剧一张卡），单集仍按影片卡显示
    final groups = <String, List<VideoBrowseItem>>{};
    final out = <_BrowseEntry>[];
    for (final it in items) {
      if (it.dir) {
        out.add(_BrowseEntry.item(it));
        continue;
      }
      if (it.mediaType != 'video') continue;
      groups.putIfAbsent(_seriesKeyOf(it.name), () => []).add(it);
    }
    for (final entry in groups.entries) {
      if (entry.value.length == 1) {
        out.add(_BrowseEntry.item(entry.value.first));
      } else {
        out.add(_BrowseEntry.series(entry.key, entry.value));
      }
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
      'mp4', 'mkv', 'avi', 'mov', 'wmv', 'flv', 'webm', 'ts', 'm2ts', 'rmvb', 'mpg', 'mpeg', 'iso',
    };
    return media.contains(ext) ? name.substring(0, dot) : name;
  }

  Widget _entry(_BrowseEntry entry) {
    switch (entry.kind) {
      case _BrowseEntryKind.item:
        final item = entry.item!;
        return NasContextMenuRegion(
          entries: _browseMenuEntries(item),
          child: InkWell(
            onTap: item.dir
                ? () => _enter(item)
                : item.mediaType == 'video'
                    ? () => _openVideo(item)
                    : item.mediaType == 'image'
                        ? () => _openImage(item)
                        : null,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _thumb(item)),
                const SizedBox(height: NasTokens.spaceXs),
                Text(
                  _stripExt(item.name),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: NasTokens.fontCaption),
                ),
              ],
            ),
          ),
        );
      default:
        final items = entry.items!;
        return InkWell(
          onTap: () => _openSeries(entry.seriesKey!),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _seriesThumb(items)),
              const SizedBox(height: NasTokens.spaceXs),
              Text(
                entry.seriesKey!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: NasTokens.fontCaption),
              ),
              Text(
                tr('video.browse.episodeCount', {'n': '${items.length}'}),
                style: TextStyle(
                  fontSize: NasTokens.fontMicro,
                  color: context.nasTextSecondary,
                ),
              ),
            ],
          ),
        );
    }
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

  Widget _thumb(VideoBrowseItem item) {
    if (item.dir) {
      return Container(
        decoration: BoxDecoration(
          color: context.nasStyle.panelColor,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          border: Border.all(color: context.nasStyle.panelBorderColor),
        ),
        child: const Center(child: Icon(Icons.folder_outlined, size: 40)),
      );
    }
    final base = ApiSession.instance.baseUrl;
    final token = ApiSession.instance.token;
    final headers =
        token == null ? const <String, String>{} : {'Authorization': 'Bearer $token'};
    if (item.mediaType == 'video' && item.id != null) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        child: NasCoverImage(
          url: '$base/api/v1/video/poster?id=${Uri.encodeComponent(item.id!)}',
          headers: headers,
          cacheWidth: 480,
          icon: Icons.movie_outlined,
        ),
      );
    }
    if (item.mediaType == 'image') {
      final fullPath = _joinPath(_rootPath, item.path);
      return ClipRRect(
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        child: NasCoverImage(
          url: '$base/api/v1/files/thumb?path=${Uri.encodeComponent(fullPath)}&size=480',
          headers: headers,
          cacheWidth: 480,
          icon: Icons.image_outlined,
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: context.nasStyle.panelColor,
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        border: Border.all(color: context.nasStyle.panelBorderColor),
      ),
      child: Center(
        child: Icon(Icons.movie_outlined, size: 36, color: context.nasTextSecondary),
      ),
    );
  }

  /// 剧卡封面用第一集的海报：剧库的集海报就是这部剧的图
  Widget _seriesThumb(List<VideoBrowseItem> items) {
    VideoBrowseItem? withPoster;
    for (final it in items) {
      if (it.id != null) {
        withPoster = it;
        break;
      }
    }
    if (withPoster == null) {
      return Container(
        decoration: BoxDecoration(
          color: context.nasStyle.panelColor,
          borderRadius: BorderRadius.circular(NasTokens.radiusSm),
          border: Border.all(color: context.nasStyle.panelBorderColor),
        ),
        child: const Center(child: Icon(Icons.video_library_outlined, size: 36)),
      );
    }
    final base = ApiSession.instance.baseUrl;
    final token = ApiSession.instance.token;
    final headers =
        token == null ? const <String, String>{} : {'Authorization': 'Bearer $token'};
    return ClipRRect(
      borderRadius: BorderRadius.circular(NasTokens.radiusSm),
      child: NasCoverImage(
        url: '$base/api/v1/video/poster?id=${Uri.encodeComponent(withPoster.id!)}',
        headers: headers,
        cacheWidth: 480,
        icon: Icons.video_library_outlined,
      ),
    );
  }
}

enum _BrowseEntryKind { item, series }

/// 目录里的一个展示条目：文件夹 / 影片 / 图片，或剧集库聚合出来的一部剧
class _BrowseEntry {
  const _BrowseEntry.item(VideoBrowseItem this.item)
      : kind = _BrowseEntryKind.item,
        seriesKey = null,
        items = null;

  const _BrowseEntry.series(String this.seriesKey, List<VideoBrowseItem> this.items)
      : kind = _BrowseEntryKind.series,
        item = null;

  final _BrowseEntryKind kind;
  final VideoBrowseItem? item;
  final String? seriesKey;
  final List<VideoBrowseItem>? items;
}
