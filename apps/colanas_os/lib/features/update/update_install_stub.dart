import 'update_install_base.dart';
import 'update_service.dart';

UpdateInstaller createUpdateInstaller() => StubUpdateInstaller();

/// Web：服务端更新后刷新页面即可，客户端本身没有「安装包」。
class StubUpdateInstaller implements UpdateInstaller {
  @override
  Future<String> download({
    required UpdateAsset asset,
    required void Function(int loaded, int total, int speed) onProgress,
    required void Function() onVerify,
  }) async {
    throw UnsupportedError('浏览器里不需要下载客户端安装包');
  }

  @override
  Future<void> install({required String path, required UpdateAsset asset}) async {
    throw UnsupportedError('浏览器里不需要安装客户端');
  }

  @override
  void cancel() {}
}
