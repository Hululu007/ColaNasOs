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
  static const Set<String> _hiddenApps = <String>{
    'photo',
    'files',
    'settings',
  };

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
        libraries = [...res.items]..sort((a, b) {
          final ao = a.sortOrder ?? 0;
          final bo = b.sortOrder ?? 0;
          if (ao != bo) return ao.compareTo(bo);
          return a.name.compareTo(b.name);
        });
      } catch (_) {
        // 拉不到库列表时退回「影视首页」tab，至少不会让影视分区消失。
        libraries = const <VideoLibraryItem>[];
      }
      for (final lib in libraries) {
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

    // 有合集才出现「我的合集」tab（和 PC 端二级菜单同一份数据）
    try {
      final collections = await ApiSession.instance.client.videoCollectionList();
      if (collections.items.isNotEmpty) {
        tabs.add(
          _TvTab(
            id: 'collections',
            label: tr('video.collection.title'),
            icon: Icons.collections_bookmark_outlined,
            kind: _TvTabKind.collections,
          ),
        );
      }
    } catch (_) {
      // 合集读不到：少一个 tab，不影响其它分区
    }

    for (final app in apps) {
      if (app.id == 'video') continue;
      tabs.add(
        _TvTab(
          id: app.id,
          label: tr(app.nameKey),
          icon: AppVisuals.iconFor(app.icon),
          kind: app.id == 'music'
              ? _TvTabKind.music
              : _TvTabKind.placeholder,
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

  FocusNode _tabNodeFor(String id) => _tabNodes.putIfAbsent(
    id,
    () => FocusNode(debugLabel: 'tv-tab-$id'),
  );

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
    switch (_resolve(event)) {
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
    _moveFocus(TraversalDirection.down);
  }

  void _onUp() {
    if (_tabsFocused) return;
    final current = FocusManager.instance.primaryFocus;
    // 详情 / 子页面里 ↑ 只在页面内部移动，不跳回 tab（返回键才回上一级）。
    if (_back.hasOverlay) {
      _moveFocus(TraversalDirection.up);
      return;
    }
    // 内容区还有上一行 → 行内上移；已在首行 → 回顶部 tab。
    // 不能直接交给方向遍历：tab 栏在内容上方，遍历可能随机落到某个 tab 上。
    if (current != null && _hasContentNodeAbove(current)) {
      _moveFocus(TraversalDirection.up);
      return;
    }
    _focusTabs();
  }

  bool _hasContentNodeAbove(FocusNode current) {
    final scope = current.nearestScope;
    if (scope == null) return false;
    final barBottom = _tabBarFocusNode.rect.bottom;
    final top = current.rect.top;
    for (final node in scope.traversalDescendants) {
      if (node == current) continue;
      final rect = node.rect;
      if (rect.bottom > top + 1) continue;
      // tab 栏里的节点不算「内容区的上一行」
      if (rect.top < barBottom - 1) continue;
      return true;
    }
    return false;
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
    // 1) 详情 / 子页面 → 上一级列表（由当前分区消费）
    if (_back.handle()) return;
    // 2) 内容区 → 顶部 tab
    if (!_tabsFocused) {
      _focusTabs();
      return;
    }
    // 3) 已在最顶层：Android TV 上退出应用；网页预览保持不动
    if (kIsWeb) return;
    SystemNavigator.pop();
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
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final m = TvMetrics.of(constraints.maxWidth);
                return TvMetricsScope(
                  metrics: m,
                  child: Padding(
                    padding: EdgeInsets.all(m.px(18)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildBrandRow(context, m),
                        SizedBox(height: m.px(10)),
                        _buildTabBar(context, m),
                        SizedBox(height: m.px(14)),
                        Expanded(child: _buildContentPanel(context, m)),
                        const TvNowPlayingBar(),
                      ],
                    ),
                  ),
                );
              },
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
          width: m.px(34),
          height: m.px(34),
          cacheWidth: 96,
          filterQuality: FilterQuality.medium,
        ),
        SizedBox(width: m.px(10)),
        Text(
          'ColaNasOs',
          style: TextStyle(
            fontSize: m.px(19),
            fontWeight: FontWeight.w800,
            color: scheme.onSurface,
          ),
        ),
        SizedBox(width: m.px(8)),
        Container(
          padding: EdgeInsets.symmetric(
            horizontal: m.px(8),
            vertical: m.px(2),
          ),
          decoration: BoxDecoration(
            color: scheme.primary.withValues(alpha: 0.16),
            borderRadius: BorderRadius.circular(m.px(99)),
          ),
          child: Text(
            'TV',
            style: TextStyle(
              fontSize: m.px(12),
              fontWeight: FontWeight.w800,
              letterSpacing: 1.1,
              color: scheme.primary,
            ),
          ),
        ),
        SizedBox(width: m.px(14)),
        Expanded(
          flex: 3,
          child: Text(
            host,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: m.px(13),
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
              fontSize: m.px(12),
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
        height: m.px(64),
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
                vertical: m.px(6),
              ),
              child: Row(
                children: [
                  for (var i = 0; i < scrollTabs.length; i += 1) ...[
                    if (i > 0) SizedBox(width: m.px(12)),
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
            SizedBox(width: m.px(12)),
            Padding(
              padding: EdgeInsets.symmetric(vertical: m.px(6)),
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
      borderRadius: BorderRadius.circular(m.px(22)),
      child: ColoredBox(
        color: context.nasStyle.panelColor,
        child: Padding(
          padding: EdgeInsets.all(m.px(18)),
          child: tab == null
              ? const SizedBox.shrink()
              : _buildSection(tab),
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
      radius: m.px(16),
      focusScale: 1.04,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: EdgeInsets.symmetric(
          horizontal: m.px(20),
          vertical: m.px(12),
        ),
        decoration: BoxDecoration(
          color: selected
              ? scheme.primary.withValues(alpha: 0.2)
              : scheme.onSurface.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(m.px(16)),
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
              size: m.px(24),
              color: selected ? scheme.primary : scheme.onSurfaceVariant,
            ),
            SizedBox(width: m.px(10)),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: m.px(300)),
              child: Text(
                tab.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: m.px(20),
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
