import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:nas_core/nas_core.dart';

import 'offline_badge.dart';
import 'offline_entry_stub.dart' if (dart.library.io) 'offline_entry_io.dart' as impl;

// 详情页要按状态切图标，枚举跟着门面一起导出，省得每个页面再 import 一次
export 'offline_badge.dart';

/// 离线下载的门面。
///
/// 为什么要有这一层：`video_shell.dart` 与影视详情页在 **Web 端也会编译**，
/// 而真正的实现要 `dart:io`（写文件、`Image.file`）。直接 import 会让 web 构建
/// 直接失败，所以这里用条件导入把两端隔开 —— Web 侧全是空实现。
bool get offlineSupported => impl.supported;

/// 离线库 / 任务发生变化时 +1（详情页按钮与本地视频页据此重建）
ValueListenable<int> get offlineRevision => impl.revision;

/// 打开下载配置弹窗；不支持时为 no-op
Future<void> openOfflineDownloadDialog(
  BuildContext context,
  VideoItem item, {
  String? libraryName,
  String? seriesTitle,
  int? totalEpisodes,
}) => impl.openDialog(
  context,
  item,
  libraryName: libraryName,
  seriesTitle: seriesTitle,
  totalEpisodes: totalEpisodes,
);

/// 某个片源在本机的下载状态（按钮五态）
OfflineBadgeState offlineStateOf(String itemId) => impl.stateOf(itemId);

/// 触发一次本地库加载（详情页 initState 里调一次即可，幂等）
void offlineEnsureLoaded() => impl.ensureLoaded();

/// 影视 → 合集 → 本地视频 的页面
Widget buildOfflinePage() => impl.buildPage();

/// 取消某个下载任务
Future<void> offlineCancel(String itemId) => impl.cancel(itemId);

/// 本地库根目录（Web 为 null）
Future<String?> offlineRootPath() => impl.rootPath();

/// 已占用字节数
Future<int> offlineUsedBytes() => impl.usedBytes();

/// 已下载条目数
Future<int> offlineItemCount() => impl.itemCount();

/// 清空本机所有离线副本（不动服务器）
Future<void> offlineClearAll() => impl.clearAll();

/// 选一个新的下载目录；Web / Android / 用户取消都返回 null
Future<String?> offlinePickRoot() => impl.pickRoot();

/// 迁移到新目录。返回 null = 成功，否则是错误信息（此时旧目录原样保留）
Future<String?> offlineMigrateRoot(
  String target, {
  void Function(int done, int total)? onProgress,
}) => impl.migrateRoot(target, onProgress: onProgress);
