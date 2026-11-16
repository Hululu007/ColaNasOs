import 'shell/app_launch.dart';

/// TV 专用入口：只由 `TV.bat` / Android TV 构建（`--target lib/main_tv.dart`）使用。
///
/// 普通入口 `main.dart` 不引用本文件，桌面 / 移动 / 网页的行为完全不变。
void main() => runColanasApp(tvEntry: true);
