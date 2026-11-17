// tray_manager 0.8.x / window_manager 0.6.x 的新式 nativeapi 接口需要手动管理
// 图标与菜单事件流；这里沿用稳定的兼容层，等插件接口定稿再迁移。
// ignore_for_file: deprecated_member_use

import 'dart:async';
import 'dart:io';

import 'package:nas_ui/nas_ui.dart';
import 'package:tray_manager/legacy.dart';
import 'package:window_manager/legacy.dart';

import '../core/app_settings.dart';
import '../core/autostart.dart';
import 'desktop_tray.dart';

class _DesktopTray with TrayListener, WindowListener implements DesktopTray {
  bool _ready = false;

  @override
  bool get supported =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  @override
  Future<void> init() async {
    if (!supported || _ready) return;
    try {
      await windowManager.ensureInitialized();
      windowManager.addListener(this);
      await trayManager.setIcon('assets/icons/tray.png');
      await trayManager.setToolTip('ColaNasOs 客户端');
      await _installMenu();
      trayManager.addListener(this);
      // 设置页改了这两个开关时，托盘菜单里的勾选态要跟着变（菜单是快照，
      // 不重建就一直显示旧值，用户会以为没生效）
      AppSettings.instance.startAtBoot.addListener(_refreshMenu);
      AppSettings.instance.startInTray.addListener(_refreshMenu);
      // 托盘就绪后才拦截关闭：否则窗口藏起来就再也叫不回来
      await windowManager.setPreventClose(true);
      _ready = true;
    } catch (_) {
      windowManager.removeListener(this);
      AppSettings.instance.startAtBoot.removeListener(_refreshMenu);
      AppSettings.instance.startInTray.removeListener(_refreshMenu);
      _ready = false;
      // 托盘起不来就绝不能保持隐藏：静默启动时原生根本没 Show 过窗口，
      // 再没有托盘图标，用户就彻底够不到它了（只能再双击一次快捷方式）。
      try {
        await windowManager.show();
      } catch (_) {
        /* 连 show 都失败：交给下一次启动 */
      }
    }
  }

  Future<void> _installMenu() {
    return trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: tr('tray.show')),
          // 开机自启勾选态跟着本地设置走；点一下当场写系统启动项
          MenuItem.checkbox(
            key: 'autostart',
            label: tr('tray.autostart'),
            checked: AppSettings.instance.startAtBoot.value,
            disabled: !autostartSupported,
            onClick: _toggleAutostart,
          ),
          // 静默启动：和设置页的开关是同一份设置，改完下次启动生效
          MenuItem.checkbox(
            key: 'startInTray',
            label: tr('tray.startInTray'),
            checked: AppSettings.instance.startInTray.value,
            onClick: _toggleStartInTray,
          ),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: tr('tray.quit')),
        ],
      ),
    );
  }

  /// 设置变化 → 重建菜单（失败静默：菜单旧一点不影响功能）
  void _refreshMenu() {
    if (!_ready) return;
    unawaited(_installMenu().catchError((_) {}));
  }

  Future<void> _toggleAutostart(MenuItem item) async {
    // 库里点完会按 menuItem.checked 回写原生勾选态，所以这里必须自己翻一次
    final next = !(item.checked ?? false);
    item.checked = next;
    await AppSettings.instance.setStartAtBoot(next);
  }

  Future<void> _toggleStartInTray(MenuItem item) async {
    final next = !(item.checked ?? false);
    item.checked = next;
    await AppSettings.instance.setStartInTray(next);
  }

  @override
  Future<void> dispose() async {
    if (!_ready) return;
    _ready = false;
    AppSettings.instance.startAtBoot.removeListener(_refreshMenu);
    AppSettings.instance.startInTray.removeListener(_refreshMenu);
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    try {
      await windowManager.setPreventClose(false);
      await trayManager.destroy();
    } catch (_) {
      /* 退出路径上失败无需处理 */
    }
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _quit() async {
    await dispose();
    exit(0);
  }

  @override
  void onTrayIconMouseDown() {
    _show();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _show();
      case 'quit':
        _quit();
    }
  }

  @override
  void onWindowClose() {
    if (!_ready) return;
    windowManager.hide();
  }
}

DesktopTray createPlatformDesktopTray() => _DesktopTray();