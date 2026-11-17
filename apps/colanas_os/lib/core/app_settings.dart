import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import 'autostart.dart';
import 'settings_store.dart';
import 'start_hidden.dart';
import 'tv_mode.dart';

/// 外观设置：明暗 + 配色（25 套）+ 皮肤（4 套）+ 界面风格（3 套），**持久化**到本地设置文件。
///
/// id 一律存**字符串**（`shadBlue` / `windows11` / `aurora`），不存下标：
/// 将来增删配色或皮肤时，老用户的设置不会错位到另一套主题上。
class AppSettings {
  AppSettings._();

  static final AppSettings instance = AppSettings._();

  final ValueNotifier<ThemeMode> themeMode = ValueNotifier<ThemeMode>(
    ThemeMode.dark,
  );
  final ValueNotifier<String> schemeId = ValueNotifier<String>('shadBlue');
  final ValueNotifier<String> skinId = ValueNotifier<String>('windows11');

  /// 界面风格：`aurora` / `card` / `fluent`（见 `NasStyles`）
  final ValueNotifier<String> styleId = ValueNotifier<String>('aurora');

  /// 界面字体：`system` / `sans` / `serif` / `mono`（见 `NasFonts`）
  final ValueNotifier<String> fontId = ValueNotifier<String>(NasFonts.system);

  /// 流畅模式：关闭面板毛玻璃模糊（`NasEffects.reduceBlur`）。
  ///
  /// **默认关**：极光玻璃是默认观感，不能因为少数机器卡就默认降级。
  /// 老显卡 / 4K 屏这类 GPU 吃得紧的场景由用户在「设置 → 其他 → 性能诊断」里打开。
  final ValueNotifier<bool> reduceBlur = ValueNotifier<bool>(false);

  /// TV / 大屏模式：大字号 + 常显侧栏 + D-pad 焦点导航
  final ValueNotifier<bool> tvMode = ValueNotifier<bool>(kTvBuild);

  /// 是否在页面顶部显示「× 在当前端为受限能力」横幅。
  ///
  /// **默认关闭**。理由：绝大多数人在固定设备上用，横幅每次进页面都占一行、
  /// 还说不到具体哪个按钮不能用，属于噪音；真要排查端差异时在「设置 → 外观」打开。
  /// 能力矩阵数据仍然保留（导航 / 文档 / 测试在用），只是不再默认打扰用户。
  final ValueNotifier<bool> capabilityNotice = ValueNotifier<bool>(false);

  /// 开机自动启动（仅桌面端；Windows 写 HKCU 登录启动项）
  ///
  /// 状态存本地设置，系统启动项由 `core/autostart.dart` 落地。
  /// 默认关：装完不吭声就往系统启动项里塞东西，用户会觉得是流氓软件。
  final ValueNotifier<bool> startAtBoot = ValueNotifier<bool>(false);

  /// 启动时最小化到托盘（仅桌面端）：开机自启 / 双击图标都直接缩进托盘，
  /// 点托盘图标才把主窗口叫出来。
  ///
  /// **默认关**：主角是「看得见的窗口」，静默启动是给常驻后台的人用的。
  /// 落地靠 `core/start_hidden.dart` 写一个标记文件给原生 runner 看 ——
  /// 原生拿到它就不在首帧 Show 窗口，全程零闪烁。
  final ValueNotifier<bool> startInTray = ValueNotifier<bool>(false);

  Listenable get listenable => Listenable.merge(
        [
          themeMode,
          schemeId,
          skinId,
          styleId,
          fontId,
          tvMode,
          reduceBlur,
          capabilityNotice,
          startAtBoot,
          startInTray,
        ],
      );

  Future<void> load() async {
    await SettingsStore.instance.load();
    final mode = SettingsStore.instance.getString('theme.mode');
    if (mode == 'light') themeMode.value = ThemeMode.light;
    if (mode == 'system') themeMode.value = ThemeMode.system;
    if (mode == 'dark') themeMode.value = ThemeMode.dark;

    final scheme = SettingsStore.instance.getString('theme.scheme');
    if (scheme != null && scheme.isNotEmpty) schemeId.value = scheme;

    final skin = SettingsStore.instance.getString('theme.skin');
    if (skin != null && skin.isNotEmpty) skinId.value = skin;

    final style = SettingsStore.instance.getString('theme.style');
    if (style != null && style.isNotEmpty) styleId.value = style;

    final font = SettingsStore.instance.getString('theme.font');
    if (font != null && NasFonts.ids.contains(font)) fontId.value = font;

    reduceBlur.value = SettingsStore.instance.getBool('ui.reduceBlur') == true;

    // 未保存过时沿用构建开关（电视盒子固件可直接编 `COLANAS_TV=1`）
    final tv = SettingsStore.instance.getString('ui.tv');
    tvMode.value = tv == null ? kTvBuild : tv == '1';

    // 未保存过 = 关（默认不打扰）
    capabilityNotice.value =
        SettingsStore.instance.getString('ui.capabilityNotice') == '1';

    startAtBoot.value = SettingsStore.instance.getString('boot.autostart') == '1';
    // 按当前 exe 路径对账一次：便携版挪目录 / 安装位置变了也能开机起来
    if (startAtBoot.value) unawaited(syncAutostartEntry(true));

    // 静默启动标记每次都按设置对一遍：手删过 APPDATA、从别的机器拷过配置，
    // 都可能让标记和开关不一致（开关开着却弹窗 / 关着却缩进托盘）
    startInTray.value = SettingsStore.instance.getString('ui.startInTray') == '1';
    unawaited(StartHidden.sync(startInTray.value));
  }

  /// 开关 + 落地系统启动项（写注册表失败也不回滚 UI：状态仍记着，下次启动重试）
  Future<void> setStartAtBoot(bool on) async {
    startAtBoot.value = on;
    await SettingsStore.instance.setString('boot.autostart', on ? '1' : '0');
    await setAutostartEnabled(on);
  }

  /// 静默启动：写设置 + 同步原生标记文件（下次启动才生效，本次不动窗口）
  Future<void> setStartInTray(bool on) async {
    startInTray.value = on;
    await SettingsStore.instance.setString('ui.startInTray', on ? '1' : '0');
    await StartHidden.sync(on);
  }

  Future<void> setCapabilityNotice(bool on) async {
    capabilityNotice.value = on;
    await SettingsStore.instance.setString('ui.capabilityNotice', on ? '1' : '0');
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    themeMode.value = mode;
    await SettingsStore.instance.setString(
      'theme.mode',
      mode == ThemeMode.light
          ? 'light'
          : mode == ThemeMode.system
          ? 'system'
          : 'dark',
    );
  }

  Future<void> setScheme(String id) async {
    schemeId.value = id;
    await SettingsStore.instance.setString('theme.scheme', id);
  }

  Future<void> setSkin(String id) async {
    skinId.value = id;
    await SettingsStore.instance.setString('theme.skin', id);
  }

  Future<void> setStyle(String id) async {
    styleId.value = id;
    await SettingsStore.instance.setString('theme.style', id);
  }

  Future<void> setFont(String id) async {
    fontId.value = NasFonts.ids.contains(id) ? id : NasFonts.system;
    await SettingsStore.instance.setString('theme.font', fontId.value);
  }

  /// 流畅模式：关掉面板毛玻璃模糊（GPU 省一层 BackdropFilter）
  Future<void> setReduceBlur(bool on) async {
    reduceBlur.value = on;
    await SettingsStore.instance.setBool('ui.reduceBlur', on);
  }

  Future<void> setTvMode(bool enabled) async {
    tvMode.value = enabled;
    await SettingsStore.instance.setString('ui.tv', enabled ? '1' : '0');
  }
}
