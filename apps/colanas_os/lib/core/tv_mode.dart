import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// TV 构建开关：`flutter build ... --dart-define=COLANAS_TV=true` 默认开启 TV 模式。
const bool kTvBuild = bool.fromEnvironment('COLANAS_TV');

/// 本次运行装的是不是 **TV 包**。
///
/// 由入口决定：`main_tv.dart` → `runColanasApp(tvEntry: true)` 时置位。
///
/// 为什么不能只信 [kTvBuild]：`--dart-define=COLANAS_TV=1` 会被
/// `bool.fromEnvironment` 当成 **false**（它只认 `true`），那一份 TV 包就会
/// 以为自己是手机包 —— 检查更新时按手机去要安装包，把电视端换成手机 UI，
/// 遥控器直接废掉（2026-11-22 用户实机踩到）。
///
/// 入口标记不会错：TV 包一定从 `main_tv.dart` 编出来。
bool tvPackage = kTvBuild;

/// 包身份：TV 包只认 `apk_tv`，手机包只认 `apk`。更新逻辑一律用它。
bool get isTvPackage => tvPackage;

/// TV 遥控器 / 手柄的确认键映射。
///
/// Flutter 默认只把 Enter / Space 映射到 `ActivateIntent`；Android TV 的
/// DPAD_CENTER、部分手柄的 A 键走的是 `select` / `gameButtonA`，这里补齐。
const Map<ShortcutActivator, Intent> kTvShortcuts = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
  SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
};
