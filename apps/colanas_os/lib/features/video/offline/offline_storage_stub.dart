/// Web / 不支持 `dart:io` 的端的空实现。
///
/// 离线下载只做 PC + Android。Web 端连「写本地文件」这个概念都没有，
/// 入口在 UI 层就该隐藏（`OfflineStorage.supported == false`）。
const bool supported = false;

const List<String> offlineSubdirs = <String>[];

Future<String> rootPath({String? custom}) async =>
    throw UnsupportedError('离线下载仅支持桌面与 Android 客户端');

Future<void> ensureLayout(String root) async {}

Future<int?> freeBytes(String root) async => null;
