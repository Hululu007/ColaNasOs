import 'update_service.dart';

/// 更新安装器的抽象：三端各一份实现（Web 端不支持客户端自更新）。
///
/// `update_install.dart` 按 `dart.library.io` 条件导出具体实现，
/// 调用方只认 `createUpdateInstaller()`。
abstract class UpdateInstaller {
  /// 下载到临时目录并校验 sha256，返回本地文件路径。
  ///
  /// 支持 Range 续传：上次留下的 `.part` 会接着下（弱网 / 切后台中断很常见）。
  Future<String> download({
    required UpdateAsset asset,
    required void Function(int loaded, int total, int speed) onProgress,
    required void Function() onVerify,
  });

  /// 拉起安装：PC 走 NSIS 静默安装（`COLANAS_RELAUNCH=1` 让它装完自动开回来），
  /// 安卓交给系统安装器（Intent），Web 不支持。
  Future<void> install({required String path, required UpdateAsset asset});

  /// 取消当前下载（已下片段保留）
  void cancel();
}
