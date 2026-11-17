import 'offline_storage_stub.dart'
    if (dart.library.io) 'offline_storage_io.dart' as impl;

/// 设备侧离线目录（PC / Android）。
///
/// 只有这两端能写本地文件，Web / TV 端的能力判定看 [supported]。
class OfflineStorage {
  OfflineStorage._();

  /// 当前端是否支持离线下载（Web 为 false）
  static bool get supported => impl.supported;

  /// 解析离线根目录。`custom` 非空时优先（PC 设置里的自定义位置）。
  static Future<String> rootPath({String? custom}) => impl.rootPath(custom: custom);

  /// 建齐 `videos/ posters/ backdrops/ subtitles/ temp/ index/` 与 `.nomedia`
  static Future<void> ensureLayout(String root) => impl.ensureLayout(root);

  /// 剩余空间（字节）；当前端拿不到时返回 null（见 io 实现的说明）
  static Future<int?> freeBytes(String root) => impl.freeBytes(root);
}
