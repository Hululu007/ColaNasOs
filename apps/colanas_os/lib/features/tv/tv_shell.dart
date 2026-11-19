import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_visibility.dart';
import '../../core/session.dart';
import '../../shell/app_visuals.dart';
import '../music/music_playback.dart';
import 'tv_collections_section.dart';
import 'tv_focus.dart';
import 'tv_music_section.dart';
import 'tv_placeholder_section.dart';
import 'tv_profile_section.dart';
import 'tv_search_section.dart';
import 'tv_video_library_section.dart';
import 'tv_video_section.dart';

/// TV / 大屏版面（10-foot UI）。
///
/// 只由 `main_tv.dart` 这个 TV 专用入口挂载，普通 `main.dart` 完全不受影响：
/// - 顶部横向 tab：当前账号可访问的影视库 + 音乐等分区（契约 `apps.json` +
///   `appVisibleToCurrentUser` 过滤，影视库来自 `/video/libraries`）；
/// - 选中 tab 后下方展示该分区内容，不再用左侧栏切换；
/// - 键位由本文件显式解析 `KeyEvent`（方向键 / 回车 / OK / Backspace / Esc /
///   遥控器与手柄键码），不依赖平台默认快捷键 —— Web 默认把方向键映射成
///   `ScrollIntent`、Enter 映射成 `ButtonActivateIntent`，靠默认绑定在 TV 上
///   方向键不会移动焦点。
class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

enum _TvTabKind {
  search,
  videoLibrary,
  videoHome,
  collections,
  music,
  placeholder,
  profile,
}

class _TvTab {
  const _TvTab({
    required this.id,
    required this.label,
    required this.icon,
    required this.kind,
    this.library,
    this.app,
  });

  final String id;
  final String label;
  final IconData icon;
  final _TvTabKind kind;
  final VideoLibraryItem? library;
  final AppDescriptor? app;
}

class _TvShellState extends State<TvShell> {
  /// TV 首屏优先顺序：先把大屏最适合的影视 / 音乐放前面。
  static const List<String> _preferredOrder = <String>[
    'video',
    'music',
    'photo',
    'files',
    'settings',
  ];

  /// TV 版面暂不提供的分区：相册 / 文件 / 设置在遥控器上没有像样的入口，
  /// 挂上去只会把顶部 tab 挤满（实测 8 个 tab 就要横向滚）。
  static const Set<String> _hiddenApps = <String>{'photo', 'files', 'settings'};

  final TvBackController _back = TvBackController();

  /// 顶部 tab 栏的容器节点：本身不参与焦点遍历，`hasFocus` 用来判断
  /// 「现在焦点是不是还在 tab 栏里」。
  final FocusNode _tabBarFocusNode = FocusNode(
    debugLabel: 'tv-tabbar',
    canRequestFocus: false,
    skipTraversal: true,
  );
  final Map<String, FocusNode> _tabNodes = <String, FocusNode>{};
  final Map<String, FocusNode> _contentNodes = <String, FocusNode>{};
  final List<Timer> _contentFocusRetries = <Timer>[];

  /// 顶层「再按一次返回退出」的 armed 状态与倒计时。
  /// 只有连着两次返回（中间没按别的键、没超时）才真的退出。
  Timer? _exitTimer;
  bool _exitArmed = false;

  /// 同一次物理返回键可能同时走 PopScope（系统返回）和 KeyEvent（goBack），
  /// 不去重就会被算成「连按两次」直接退出。150ms 内的第二次只当同一个事件。
  DateTime? _lastBackAt;

  List<_TvTab> _tabs = const <_TvTab>[];
  String? _selectedTabId;
  String? _focusedTabId;
  bool _loadingTabs = true;

  bool get _tabsFocused => _tabBarFocusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    _loadTabs();
  }

  @override
  void dispose() {
    _exitTimer?.cancel();
    for (final timer in _contentFocusRetries) {
      timer.cancel();
    }
    for (final node in _tabNodes.values) {
      node.dispose();
    }
    for (final node in _contentNodes.values) {
      node.dispose();
    }
    _tabBarFocusNode.dispose();
    super.dispose();
  }

  /// 构建顶部 tab：最左固定「搜索」、最右固定「我的」（贴右边），
  /// 中间是影视库（服务端已按账号过滤）与其余契约里支持 TV 的 App。
  Future<void> _loadTabs() async {
    final apps = _tvApps;
    final tabs = <_TvTab>[
      _TvTab(
        id: 'search',
        label: tr('tv.tab.search'),
        icon: Icons.search_rounded,
        kind: _TvTabKind.search,
      ),
    ];

    final videoApp = _appById(apps, 'video');
    if (videoApp != null) {
      var libraries = const <VideoLibraryItem>[];
      try {
        final res = await ApiSession.instance.client.videoLibraryList();
        libraries = [...res.items]..sort(_compareLibraries);
      } catch (_) {
        // 拉不到库列表时退回「影视首页」tab，至少不会让影视分区消失。
        libraries = const <VideoLibraryItem>[];
      }
      // 有合集才出现「我的合集」tab：位置在「电视剧」之后、「日本电影库」之前
      // （合集本身是电影 / 剧集的集合，排在图片库后面没道理）。音乐紧跟其后。
      var hasCollections = false;
      try {
        final collections = await ApiSession.instance.client
            .videoCollectionList();
        hasCollections = collections.items.isNotEmpty;
      } catch (_) {
        hasCollections = false;
      }
      final musicApp = _appById(apps, 'music');
      var inserted = false;
      void addMidTabs() {
        if (hasCollections) tabs.add(_collectionsTab());
        if (musicApp != null) tabs.add(_musicTab(musicApp));
      }

      for (final lib in libraries) {
        if (!inserted && _libraryRank(lib.libType) >= 3) {
          addMidTabs();
          inserted = true;
        }
        tabs.add(
          _TvTab(
            id: 'lib:${lib.id}',
            label: lib.name,
            icon: _libraryIcon(lib.libType),
            kind: _TvTabKind.videoLibrary,
            library: lib,
          ),
        );
      }
      if (!inserted) addMidTabs();
      if (libraries.isEmpty) {
        tabs.add(
          _TvTab(
            id: 'video',
            label: tr(videoApp.nameKey),
            icon: AppVisuals.iconFor(videoApp.icon),
            kind: _TvTabKind.videoHome,
          ),
        );
      }
    }

    for (final app in apps) {
      // video 已经按库展开成多个 tab；music 已经提前到合集后面
      if (app.id == 'video' || app.id == 'music') continue;
      tabs.add(
        _TvTab(
          id: app.id,
          label: tr(app.nameKey),
          icon: AppVisuals.iconFor(app.icon),
          kind: app.id == 'music' ? _TvTabKind.music : _TvTabKind.placeholder,
          app: app,
        ),
      );
    }

    tabs.add(
      _TvTab(
        id: 'profile',
        label: tr('tv.tab.profile'),
        icon: Icons.person_outline_rounded,
        kind: _TvTabKind.profile,
      ),
    );

    if (!mounted) return;
    final initial = _defaultTabId(tabs);
    setState(() {
      _tabs = tabs;
      _loadingTabs = false;
      _selectedTabId = initial;
      _focusedTabId = initial;
    });
    if (initial == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _tabNodeFor(initial).requestFocus();
    });
  }

  /// 登录后默认落在第一个影视库（通常是电影），而不是「搜索」或首页兜底。
  static String? _defaultTabId(List<_TvTab> tabs) {
    for (final kind in <_TvTabKind>[
      _TvTabKind.videoLibrary,
      _TvTabKind.videoHome,
      _TvTabKind.music,
    ]) {
      for (final tab in tabs) {
        if (tab.kind == kind) return tab.id;
      }
    }
    for (final tab in tabs) {
      if (tab.kind != _TvTabKind.search && tab.kind != _TvTabKind.profile) {
        return tab.id;
      }
    }
    return tabs.isEmpty ? null : tabs.first.id;
  }

  List<AppDescriptor> get _tvApps {
    final apps = AppRegistry.apps
        .where(
          (app) =>
              app.available &&
              !_hiddenApps.contains(app.id) &&
              app.supports(ClientEndpoint.tv) &&
              appVisibleToCurrentUser(app),
        )
        .toList();
    int rank(AppDescriptor app) {
      final index = _preferredOrder.indexOf(app.id);
      return index < 0 ? _preferredOrder.length : index;
    }

    apps.sort((a, b) => rank(a).compareTo(rank(b)));
    return apps;
  }

  static AppDescriptor? _appById(List<AppDescriptor> apps, String id) {
    for (final app in apps) {
      if (app.id == id) return app;
    }
    return null;
  }

  static IconData _libraryIcon(String libType) => switch (libType) {
    'tv' || 'short_tv' => Icons.live_tv_rounded,
    'image' || 'mixed' => Icons.photo_library_outlined,
    _ => Icons.movie_outlined,
  };

  /// TV 顶部 tab 的库顺序（用户 2026-11-18 指定）：
  /// 电影 → 电视剧 → 合集 → 日本电影 → 图片视频混合 → 图片。
  ///
  /// 合集占 rank 2：它不是库，由 [_loadTabs] 插在第一个 rank>=3 的库之前。
  static int _libraryRank(String libType) => switch (libType) {
    'movie' => 0,
    'tv' || 'short_tv' => 1,
    'jp_movie' => 3,
    'mixed' => 4,
    'image' => 5,
    _ => 6,
  };

  static int _compareLibraries(VideoLibraryItem a, VideoLibraryItem b) {
    final rank = _libraryRank(a.libType).compareTo(_libraryRank(b.libType));
    if (rank != 0) return rank;
    final ao = a.sortOrder ?? 0;
    final bo = b.sortOrder ?? 0;
    if (ao != bo) return ao.compareTo(bo);
    return a.name.compareTo(b.name);
  }

  static _TvTab _collectionsTab() => _TvTab(
    id: 'collections',
    label: tr('video.collection.title'),
    icon: Icons.collections_bookmark_outlined,
    kind: _TvTabKind.collections,
  );

  static _TvTab _musicTab(AppDescriptor app) => _TvTab(
    id: app.id,
    label: tr(app.nameKey),
    icon: AppVisuals.iconFor(app.icon),
    kind: _TvTabKind.music,
    app: app,
  );

  FocusNode _tabNodeFor(String id) =>
      _tabNodes.putIfAbsent(id, () => FocusNode(debugLabel: 'tv-tab-$id'));

  FocusNode _contentNodeFor(String id) => _contentNodes.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'tv-content-$id'),
  );

  // ---------------------------------------------------------------------------
  // 键位：直接解析 KeyEvent
  // ---------------------------------------------------------------------------

  /// 逻辑键（Web 键盘 + Android 映射后的键）与物理键（部分遥控器只带物理码）
  /// 同时判断，覆盖：键盘方向键、Android TV 遥控器 D-pad、手柄 A、媒体键。
  static bool _match(
    KeyEvent event, {
    List<LogicalKeyboardKey> logical = const <LogicalKeyboardKey>[],
    List<PhysicalKeyboardKey> physical = const <PhysicalKeyboardKey>[],
  }) =>
      logical.contains(event.logicalKey) ||
      physical.contains(event.physicalKey);

  static _TvKey _resolve(KeyEvent event) {
    if (_match(
      event,
      logical: const <LogicalKeyboardKey>[LogicalKeyboardKey.arrowLeft],
      physical: const <PhysicalKeyboardKey>[PhysicalKeyboardKey.arrowLeft],
    )) {
      return _TvKey.left;
    }
    if (_match(
      event,
      logical: const <LogicalKeyboardKey>[LogicalKeyboardKey.arrowRight],
      physical: const <PhysicalKeyboardKey>[PhysicalKeyboardKey.arrowRight],
    )) {
      return _TvKey.right;
    }
    if (_match(
      event,
      logical: const <LogicalKeyboardKey>[LogicalKeyboardKey.arrowUp],
      physical: const <PhysicalKeyboardKey>[PhysicalKeyboardKey.arrowUp],
    )) {
      return _TvKey.up;
    }
    if (_match(
      event,
      logical: const <LogicalKeyboardKey>[LogicalKeyboardKey.arrowDown],
      physical: const <PhysicalKeyboardKey>[PhysicalKeyboardKey.arrowDown],
    )) {
      return _TvKey.down;
    }
    if (_match(
      event,
      logical: const <LogicalKeyboardKey>[
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.gameButtonA,
        LogicalKeyboardKey.space,
      ],
      physical: const <PhysicalKeyboardKey>[
        PhysicalKeyboardKey.enter,
        PhysicalKeyboardKey.numpadEnter,
        PhysicalKeyboardKey.select,
        PhysicalKeyboardKey.gameButtonA,
        PhysicalKeyboardKey.space,
      ],
    )) {
      return _TvKey.ok;
    }
    if (_match(
      event,
      logical: const <LogicalKeyboardKey>[
        LogicalKeyboardKey.escape,
        LogicalKeyboardKey.backspace,
        LogicalKeyboardKey.goBack,
        LogicalKeyboardKey.browserBack,
      ],
      physical: const <PhysicalKeyboardKey>[
        PhysicalKeyboardKey.escape,
        PhysicalKeyboardKey.backspace,
        PhysicalKeyboardKey.browserBack,
      ],
    )) {
      return _TvKey.back;
    }
    if (_match(
      event,
      logical: const <LogicalKeyboardKey>[LogicalKeyboardKey.mediaPlayPause],
      physical: const <PhysicalKeyboardKey>[PhysicalKeyboardKey.mediaPlayPause],
    )) {
      return _TvKey.playPause;
    }
    if (_match(
      event,
      logical: const <LogicalKeyboardKey>[LogicalKeyboardKey.mediaTrackNext],
      physical: const <PhysicalKeyboardKey>[PhysicalKeyboardKey.mediaTrackNext],
    )) {
      return _TvKey.next;
    }
    if (_match(
      event,
      logical: const <LogicalKeyboardKey>[
        LogicalKeyboardKey.mediaTrackPrevious,
      ],
      physical: const <PhysicalKeyboardKey>[
        PhysicalKeyboardKey.mediaTrackPrevious,
      ],
    )) {
      return _TvKey.previous;
    }
    return _TvKey.none;
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final isDown = event is KeyDownEvent;
    final isRepeat = event is KeyRepeatEvent;
    if (!isDown && !isRepeat) return KeyEventResult.ignored;
    final key = _resolve(event);
    // 「再按一次退出」的计数只对连续两次返回有效：其它任何键都清零，
    // 包括方向键、OK、媒体键。长按返回（repeat）不重复计数。
    if (key != _TvKey.back) _disarmExit();
    switch (key) {
      case _TvKey.left:
        _onHorizontal(-1);
        return KeyEventResult.handled;
      case _TvKey.right:
        _onHorizontal(1);
        return KeyEventResult.handled;
      case _TvKey.up:
        _onUp();
        return KeyEventResult.handled;
      case _TvKey.down:
        _onDown();
        return KeyEventResult.handled;
      case _TvKey.ok:
        if (isDown) _activateFocused();
        return KeyEventResult.handled;
      case _TvKey.back:
        if (isDown) _onBack();
        return KeyEventResult.handled;
      case _TvKey.playPause:
        if (isDown) _mediaToggle();
        return KeyEventResult.handled;
      case _TvKey.next:
        if (isDown) _mediaNext();
        return KeyEventResult.handled;
      case _TvKey.previous:
        if (isDown) _mediaPrevious();
        return KeyEventResult.handled;
      case _TvKey.none:
        return KeyEventResult.ignored;
    }
  }

  bool _moveFocus(TraversalDirection direction) {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus.context == null) return false;
    return focus.focusInDirection(direction);
  }

  void _onHorizontal(int delta) {
    if (!_tabsFocused) {
      _moveFocus(
        delta < 0 ? TraversalDirection.left : TraversalDirection.right,
      );
      return;
    }
    if (_tabs.isEmpty) return;
    final currentId = _focusedTabId ?? _selectedTabId;
    var index = _tabs.indexWhere((tab) => tab.id == currentId);
    if (index < 0) index = 0;
    final next = (index + delta).clamp(0, _tabs.length - 1);
    if (next == index) return;
    final id = _tabs[next].id;
    _tabNodeFor(id).requestFocus();
    _onTabFocused(id);
  }

  void _onDown() {
    if (_tabsFocused) {
      final id = _selectedTabId ?? _focusedTabId;
      if (id != null) _focusContent(id);
      return;
    }
    // 内容区：↓ 就是往下一行，走到底部没有下一行就停住（不跳去别的地方）。
    _moveContentRow(up: false);
  }

  void _onUp() {
    if (_tabsFocused) return;
    // ↑ 先往上一行；只有「这一页最顶上、确实没有上一行」才回顶部 tab。
    // 详情 / 子页面同样按行移动，但顶上不跳 tab（回上一级由返回键负责）。
    if (_moveContentRow(up: true)) return;
    if (!_back.hasOverlay) _focusTabs();
  }

  /// 按**行**移动焦点，一次一行。
  ///
  /// 不用 `focusInDirection`：方向遍历按矩形打分，遇上泳道里横向可滚的卡片、
  /// 网格里不同高度的卡片，经常斜着跳或者直接落到顶部 tab 上 —— 表现就是
  /// 「一按上就回 tab」。这里自己按焦点矩形的中心算「上一行 / 下一行」：
  /// 先取垂直距离最近的一行，再在这一行里挑水平位置最贴近当前列的卡片。
  /// 返回 false 表示这个方向已经没有行了。
  bool _moveContentRow({required bool up}) {
    final current = FocusManager.instance.primaryFocus;
    if (current == null || current.context == null) return false;
    final scope = current.nearestScope;
    final cur = current.rect;
    if (scope == null || cur.isEmpty || cur.height <= 0) return false;
    final barBottom = _tabBarFocusNode.rect.bottom;
    final cx = cur.center.dx;
    final cy = cur.center.dy;
    FocusNode? best;
    double bestDy = double.infinity;
    double bestDx = double.infinity;
    for (final node in scope.traversalDescendants) {
      if (node == current || !node.canRequestFocus || node.context == null) {
        continue;
      }
      final r = node.rect;
      if (r.isEmpty || r.width <= 0 || r.height <= 0) continue;
      // tab 栏 / 品牌行不在内容区，不能当「上一行」。
      if (r.top < barBottom - 1) continue;
      final dy = up ? cy - r.center.dy : r.center.dy - cy;
      // 同一行的卡片（高度略有差异时中心也会错开几像素）不算下一行。
      if (dy < cur.height * 0.4) continue;
      final dx = (r.center.dx - cx).abs();
      if (dy < bestDy - 1 || (dy <= bestDy + 1 && dx < bestDx)) {
        best = node;
        bestDy = dy;
        bestDx = dx;
      }
    }
    if (best == null) return false;
    best.requestFocus();
    return true;
  }

  void _activateFocused() {
    if (_tabsFocused) {
      final id = _selectedTabId ?? _focusedTabId;
      if (id != null) _focusContent(id);
      return;
    }
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return;
    // 直接派发 ActivateIntent：Web 上 Enter 默认映射的是 ButtonActivateIntent，
    // 只有 Material 按钮处理它，自定义卡片收不到。
    Actions.maybeInvoke(context, const ActivateIntent());
  }

  void _onBack() {
    final now = DateTime.now();
    final last = _lastBackAt;
    if (last != null && now.difference(last).inMilliseconds < 150) return;
    _lastBackAt = now;
    // 1) 详情 / 子页面 → 上一级列表（由当前分区消费）
    if (_back.handle()) {
      _disarmExit();
      return;
    }
    // 2) 内容区 → 回到「刚刚选中的这个栏目」的 tab，而不是随便一个 tab。
    if (!_tabsFocused) {
      _disarmExit();
      _focusTabs();
      return;
    }
    // 3) 已经站在 tab 上：第一次给提示，超时前再按一次才退出。
    //    网页预览没有「退出应用」这回事，只演示提示，不真的关页面。
    if (_exitArmed) {
      _disarmExit();
      if (!kIsWeb) SystemNavigator.pop();
      return;
    }
    _exitTimer?.cancel();
    setState(() => _exitArmed = true);
    _exitTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _exitArmed) setState(() => _exitArmed = false);
    });
  }

  /// 除了「连续第二次返回」以外的任何情况都把退出计数清零：按了别的键、
  /// 回了上一级、切了分区、超时。
  void _disarmExit() {
    _exitTimer?.cancel();
    _exitTimer = null;
    if (_exitArmed && mounted) setState(() => _exitArmed = false);
    _exitArmed = false;
  }

  void _focusTabs() {
    final id = _selectedTabId ?? _focusedTabId;
    if (id == null) return;
    _tabNodeFor(id).requestFocus();
  }

  void _focusContent(String tabId) {
    if (_selectedTabId != tabId) {
      setState(() {
        _selectedTabId = tabId;
        _focusedTabId = tabId;
      });
    }
    _requestContentFocus(tabId, _contentNodeFor(tabId), 12);
  }

  /// 内容区还在加载时首卡片尚未挂载，`FocusNode.context` 为空；
  /// 这里短轮询等它挂上再 request，避免「按下键没反应」。
  void _requestContentFocus(String tabId, FocusNode node, int remaining) {
    if (!mounted || _selectedTabId != tabId) return;
    if (node.context != null) {
      node.requestFocus();
      return;
    }
    if (remaining <= 0) return;
    late final Timer timer;
    timer = Timer(const Duration(milliseconds: 150), () {
      _contentFocusRetries.remove(timer);
      _requestContentFocus(tabId, node, remaining - 1);
    });
    _contentFocusRetries.add(timer);
  }

  void _onTabFocused(String id) {
    if (_focusedTabId == id && _selectedTabId == id) return;
    setState(() {
      _focusedTabId = id;
      _selectedTabId = id;
    });
  }

  void _mediaToggle() {
    final service = MusicPlaybackService.instance;
    if (service.hasTrack) service.toggle();
  }

  void _mediaNext() {
    final service = MusicPlaybackService.instance;
    if (service.hasTrack) service.next();
  }

  void _mediaPrevious() {
    final service = MusicPlaybackService.instance;
    if (service.hasTrack) service.previous();
  }

  // ---------------------------------------------------------------------------
  // 布局
  // ---------------------------------------------------------------------------

  _TvTab? get _selectedTab {
    for (final tab in _tabs) {
      if (tab.id == _selectedTabId) return tab;
    }
    return _tabs.isEmpty ? null : _tabs.first;
  }

  @override
  Widget build(BuildContext context) {
    // 系统返回（Android TV 遥控器 Back）走 PopScope，键盘 Backspace/Esc 走 _onKey。
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _onBack();
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: Scaffold(
          backgroundColor: Colors.transparent,
          body: Stack(
            children: [
              SafeArea(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final m = TvMetrics.of(constraints.maxWidth);
                    return TvMetricsScope(
                      metrics: m,
                      child: Padding(
                        padding: EdgeInsets.all(m.px(14)),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildBrandRow(context, m),
                            SizedBox(height: m.px(6)),
                            _buildTabBar(context, m),
                            SizedBox(height: m.px(10)),
                            Expanded(child: _buildContentPanel(context, m)),
                            const TvNowPlayingBar(),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
              if (_exitArmed) _buildExitPrompt(context),
            ],
          ),
        ),
      ),
    );
  }

  /// 顶层返回提示：全屏时也能看见，3 秒后自动消失。
  Widget _buildExitPrompt(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 48,
      child: IgnorePointer(
        child: Center(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: scheme.inverseSurface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(28),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              child: Text(
                tr('tv.exit.hint'),
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: scheme.onInverseSurface,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrandRow(BuildContext context, TvMetrics m) {
    final scheme = Theme.of(context).colorScheme;
    final host = ApiSession.instance.baseUrl.replaceFirst(
      RegExp('^https?://'),
      '',
    );
    return Row(
      children: [
        Image.asset(
          'assets/branding/app_icon.png',
          width: m.px(26),
          height: m.px(26),
          cacheWidth: 96,
          filterQuality: FilterQuality.medium,
        ),
        SizedBox(width: m.px(8)),
        Text(
          'ColaNasOs',
          style: TextStyle(
            fontSize: m.px(16),
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
        SizedBox(width: m.px(7)),
        Container(
          padding: EdgeInsets.symmetric(horizontal: m.px(7), vertical: m.px(1)),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(m.px(99)),
          ),
          child: Text(
            'TV',
            style: TextStyle(
              fontSize: m.px(10),
              fontWeight: FontWeight.w800,
              letterSpacing: 1.0,
              color: scheme.primary,
            ),
          ),
        ),
        SizedBox(width: m.px(12)),
        Expanded(
          flex: 3,
          child: Text(
            host,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(12),
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
        SizedBox(width: m.px(12)),
        Flexible(
          flex: 2,
          child: Text(
            tr('tv.hint.keys'),
            maxLines: 1,
            textAlign: TextAlign.right,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(11),
              color: scheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabBar(BuildContext context, TvMetrics m) {
    if (_loadingTabs) {
      return SizedBox(
        height: m.px(48),
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_tabs.isEmpty) {
      return Text(
        'No TV apps available',
        style: TextStyle(
          fontSize: m.px(16),
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    final scrollTabs = <_TvTab>[
      for (final tab in _tabs)
        if (tab.kind != _TvTabKind.profile) tab,
    ];
    final pinned = <_TvTab>[
      for (final tab in _tabs)
        if (tab.kind == _TvTabKind.profile) tab,
    ];
    return Focus(
      focusNode: _tabBarFocusNode,
      canRequestFocus: false,
      skipTraversal: true,
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: EdgeInsets.symmetric(
                horizontal: m.px(2),
                vertical: m.px(4),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < scrollTabs.length; i += 1) ...[
                    if (i > 0) SizedBox(width: m.px(9)),
                    _TvTabItem(
                      key: ValueKey<String>('tab-${scrollTabs[i].id}'),
                      tab: scrollTabs[i],
                      selected: scrollTabs[i].id == _selectedTabId,
                      focusNode: _tabNodeFor(scrollTabs[i].id),
                      onFocused: () => _onTabFocused(scrollTabs[i].id),
                      onTap: () {
                        _onTabFocused(scrollTabs[i].id);
                        _focusContent(scrollTabs[i].id);
                      },
                    ),
                  ],
                ],
              ),
            ),
          ),
          // 「我的」贴最右边，不跟着中间 tab 一起横滑。
          for (final tab in pinned) ...[
            SizedBox(width: m.px(9)),
            Padding(
              padding: EdgeInsets.symmetric(vertical: m.px(4)),
              child: _TvTabItem(
                key: ValueKey<String>('tab-${tab.id}'),
                tab: tab,
                selected: tab.id == _selectedTabId,
                focusNode: _tabNodeFor(tab.id),
                onFocused: () => _onTabFocused(tab.id),
                onTap: () {
                  _onTabFocused(tab.id);
                  _focusContent(tab.id);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildContentPanel(BuildContext context, TvMetrics m) {
    final tab = _selectedTab;
    return ClipRRect(
      borderRadius: BorderRadius.circular(m.px(18)),
      child: ColoredBox(
        color: context.nasStyle.panelColor,
        child: Padding(
          padding: EdgeInsets.all(m.px(12)),
          child: tab == null ? const SizedBox.shrink() : _buildSection(tab),
        ),
      ),
    );
  }

  Widget _buildSection(_TvTab tab) {
    final firstFocus = _contentNodeFor(tab.id);
    final key = ValueKey<String>(tab.id);
    return switch (tab.kind) {
      _TvTabKind.search => TvSearchSection(
        key: key,
        back: _back,
        firstFocusNode: firstFocus,
      ),
      _TvTabKind.videoLibrary => TvVideoLibrarySection(
        key: key,
        library: tab.library!,
        back: _back,
        firstFocusNode: firstFocus,
      ),
      _TvTabKind.videoHome => TvVideoSection(
        key: key,
        back: _back,
        firstFocusNode: firstFocus,
      ),
      _TvTabKind.collections => TvCollectionsSection(
        key: key,
        back: _back,
        firstFocusNode: firstFocus,
      ),
      _TvTabKind.music => TvMusicSection(
        key: key,
        back: _back,
        firstFocusNode: firstFocus,
      ),
      _TvTabKind.placeholder => TvPlaceholderSection(app: tab.app!),
      _TvTabKind.profile => TvProfileSection(
        key: key,
        firstFocusNode: firstFocus,
      ),
    };
  }
}

enum _TvKey { left, right, up, down, ok, back, playPause, next, previous, none }

/// 顶部 tab 单项：图标 + 库名。选中态跟随焦点（TV 上焦点在哪就是选中哪个）。
class _TvTabItem extends StatelessWidget {
  const _TvTabItem({
    super.key,
    required this.tab,
    required this.selected,
    required this.focusNode,
    required this.onFocused,
    required this.onTap,
  });

  final _TvTab tab;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onFocused;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return TvFocusCard(
      focusNode: focusNode,
      onTap: onTap,
      onFocused: onFocused,
      radius: m.px(14),
      focusScale: 1.04,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(horizontal: m.px(15), vertical: m.px(8)),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.2)
              : scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(m.px(14)),
          border: Border.all(
            color: selected
                ? scheme.primary.withValues(alpha: 0.55)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              tab.icon,
              size: m.px(19),
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            SizedBox(width: m.px(8)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: m.px(240)),
              child: Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: m.px(17),
                  fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                  color: selected ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
