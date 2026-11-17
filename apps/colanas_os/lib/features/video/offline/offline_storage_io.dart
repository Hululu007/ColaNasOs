import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 设备侧离线目录的解析与布局创建（桌面 / Android 走这份实现）。
///
/// 目录约定（PC 与 Android 完全一致，方便排查与迁移）：
///
/// ```
/// Offline/
///   videos/  posters/  backdrops/  subtitles/  temp/  index/
///   .nomedia            ← 仅 Android
/// ```
///
/// 为什么 Android 用 `getExternalStorageDirectory()`：那是
/// `/storage/emulated/0/Android/data/com.colanas.os/files`，即**应用专属外部目录**。
/// 它不需要任何存储权限、不注册 MediaStore、卸载时随应用清掉 —— 正好满足
/// 「离线视频不进手机相册」这条要求，而且不需要申请任何权限。
const bool supported = true;

/// 子目录清单：初始化时一次性建齐，后续写入不再判断
const List<String> offlineSubdirs = <String>[
  'videos',
  'posters',
  'backdrops',
  'subtitles',
  'temp',
  'index',
];

Future<String> rootPath({String? custom}) async {
  final manual = (custom ?? '').trim();
  if (manual.isNotEmpty) return manual;

  if (Platform.isAndroid) {
    final ext = await getExternalStorageDirectory();
    if (ext != null) return p.join(ext.path, 'Offline');
    // 极少数机器拿不到外部目录（外置存储被禁用）：退回内部支持目录，
    // 能力上一样（同样不进相册），只是占的是内部空间。
    final support = await getApplicationSupportDirectory();
    return p.join(support.path, 'Offline');
  }

  // 桌面：放进用户「视频」目录下，资源管理器里能直接看到下载好的片子
  final downloads = await getDownloadsDirectory();
  final home = downloads?.parent;
  if (home != null) {
    final videos = Directory(p.join(home.path, 'Videos'));
    if (await videos.exists()) return p.join(videos.path, 'ColaNasOs');
  }
  final support = await getApplicationSupportDirectory();
  return p.join(support.path, 'Offline');
}

Future<void> ensureLayout(String root) async {
  await Directory(root).create(recursive: true);
  for (final dir in offlineSubdirs) {
    await Directory(p.join(root, dir)).create(recursive: true);
  }

  // `.nomedia` 只是双保险：应用专属目录本来就不进 MediaStore，
  // 但部分厂商 ROM 的图库会把 `Android/data` 也扫进去。
  if (Platform.isAndroid) {
    for (final dir in <String>[root, p.join(root, 'videos'), p.join(root, 'posters')]) {
      final marker = File(p.join(dir, '.nomedia'));
      if (!await marker.exists()) {
        await marker.writeAsString('');
      }
    }
  }
}

/// 剩余空间（字节）；拿不到返回 null。
///
/// ⚠️ 已知缺口：Dart 没有跨平台 API 能查剩余空间，这里只能返回 null，
/// 由调用方在真正写盘失败（ENOSPC / ERROR_DISK_FULL）时给「空间不足」提示。
/// 要提前拦截得引第三方插件，留到 P7 存储管理时再补。
Future<int?> freeBytes(String root) async => null;
