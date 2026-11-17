import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';

import 'offline_badge.dart';
import 'offline_download_dialog.dart' as dialog;
import 'offline_download_manager.dart';
import 'offline_models.dart';
import 'video_offline_page.dart';

/// 桌面 / Android 的真实实现（`dart:io` 允许使用）。
const bool supported = true;

ValueListenable<int> get revision => OfflineDownloadManager.instance.libraryRevision;

Future<void> openDialog(
  BuildContext context,
  VideoItem item, {
  String? libraryName,
  String? seriesTitle,
  int? totalEpisodes,
}) => dialog.openOfflineDownloadDialog(
  context,
  item,
  libraryName: libraryName,
  seriesTitle: seriesTitle,
  totalEpisodes: totalEpisodes,
);

OfflineBadgeState stateOf(String itemId) {
  final store = OfflineDownloadManager.instance.store;
  // 还没加载过：按「没下过」显示，`ensureLoaded()` 之后 revision 会把它刷对
  if (store == null) return OfflineBadgeState.none;
  if (store.item(itemId) != null) return OfflineBadgeState.downloaded;
  final task = store.tasks[itemId];
  if (task == null) return OfflineBadgeState.none;
  switch (task.state) {
    case OfflineTaskState.queued:
    case OfflineTaskState.transcoding:
      return OfflineBadgeState.preparing;
    case OfflineTaskState.downloading:
    case OfflineTaskState.verifying:
    case OfflineTaskState.replacing:
      return OfflineBadgeState.downloading;
    case OfflineTaskState.done:
      return OfflineBadgeState.downloaded;
    case OfflineTaskState.failed:
      return OfflineBadgeState.failed;
    case OfflineTaskState.canceled:
      return OfflineBadgeState.none;
  }
}

void ensureLoaded() {
  // 失败无所谓：进详情页只是想把按钮刷成「已下载」，加载失败按未下载显示
  OfflineDownloadManager.instance.ensureStore().ignore();
}

Widget buildPage() => const VideoOfflinePage();

Future<void> cancel(String itemId) => OfflineDownloadManager.instance.cancel(itemId);

Future<String?> rootPath() async =>
    (await OfflineDownloadManager.instance.ensureStore()).root;

Future<int> usedBytes() async =>
    (await OfflineDownloadManager.instance.ensureStore()).totalBytes;

Future<int> itemCount() async =>
    (await OfflineDownloadManager.instance.ensureStore()).items.length;

Future<String?> pickRoot() async {
  // Android 的下载目录固定在应用专属外部目录（不进相册的前提），不给改
  if (defaultTargetPlatform == TargetPlatform.android) return null;
  try {
    final picked = await getDirectoryPath(confirmButtonText: '选择');
    return picked;
  } catch (_) {
    return null;
  }
}

Future<String?> migrateRoot(
  String target, {
  void Function(int done, int total)? onProgress,
}) async {
  try {
    await OfflineDownloadManager.instance.migrateRoot(target, onProgress: onProgress);
    return null;
  } catch (err) {
    return '$err';
  }
}

Future<void> clearAll() async {
  final manager = OfflineDownloadManager.instance;
  final store = await manager.ensureStore();
  await manager.deleteItems(store.items.keys.toList());
}
