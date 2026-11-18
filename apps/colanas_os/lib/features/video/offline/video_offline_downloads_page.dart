import 'dart:io';

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../player_page.dart';
import 'offline_download_manager.dart';
import 'offline_models.dart';
import 'offline_store.dart';

/// 影视 → 合集 → 下载管理。
///
/// 三个页签对应任务生命周期的三段：
///   进行中 —— 排队 / 转码 / 下载 / 等 WiFi / 已暂停，可暂停、继续、取消；
///   失败 —— 自动重试耗尽或编码失败，可重试（新的一次机会）或删掉任务；
///   已完成 —— 直接从本地库读（任务记录在入库时就删了），可播放或删文件。
///
/// 为什么不给已完成单独存一份任务历史：本地库里的条目本来就带着规格、体积和
/// 下载时间，再造一份「历史任务」只会让两边的数据打架。
class VideoOfflineDownloadsPage extends StatefulWidget {
  const VideoOfflineDownloadsPage({super.key});

  @override
  State<VideoOfflineDownloadsPage> createState() => _VideoOfflineDownloadsPageState();
}

class _VideoOfflineDownloadsPageState extends State<VideoOfflineDownloadsPage> {
  OfflineStore? _store;
  bool _loading = true;
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    OfflineDownloadManager.instance.tasks.addListener(_onChanged);
    OfflineDownloadManager.instance.libraryRevision.addListener(_load);
    _load();
  }

  @override
  void dispose() {
    OfflineDownloadManager.instance.tasks.removeListener(_onChanged);
    OfflineDownloadManager.instance.libraryRevision.removeListener(_load);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    try {
      final store = await OfflineDownloadManager.instance.ensureStore();
      if (!mounted) return;
      setState(() {
        _store = store;
        _loading = false;
      });
    } catch (_) {
      // 目录拿不到（测试环境没有 path_provider / 磁盘被拔）：
      // 按空列表显示，别把整页炸掉
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final manager = OfflineDownloadManager.instance;
    final tasks = manager.tasks.value;
    final active = tasks.where((t) => t.active).toList();
    final failed = tasks.where((t) => t.state == OfflineTaskState.failed).toList();
    final done = (_store?.items.values.toList() ?? <LocalMediaItem>[])
      ..sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(NasTokens.spaceMd, 10, NasTokens.spaceMd, 6),
          child: Wrap(
            spacing: 8,
            children: [
              _tabChip(0, tr('video.offline.tabActive'), active.length),
              _tabChip(1, tr('video.offline.tabFailed'), failed.length),
              _tabChip(2, tr('video.offline.tabDone'), done.length),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: switch (_tab) {
            1 => _failedList(failed),
            2 => _doneList(done),
            _ => _activeList(active),
          },
        ),
      ],
    );
  }

  /// 页签用同一套胶囊样式：未选中是面板色底 + 次要文字色，选中换成主色淡底 +
  /// 主色文字 + 加粗。统一自己画形状，不再让 ChoiceChip 给未选中项描一圈边框、
  /// 给选中项去掉边框还塞一个对勾（两套形状叠在一起看着像两种控件）。
  Widget _tabChip(int index, String label, int count) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _tab == index;
    final radius = BorderRadius.circular(999);
    return Material(
      color: selected
          ? scheme.primary.withValues(alpha: 0.14)
          : context.nasStyle.panelColor,
      borderRadius: radius,
      child: InkWell(
        borderRadius: radius,
        onTap: () => setState(() => _tab = index),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: NasTokens.fontBody,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: selected ? scheme.primary : context.nasTextSecondary,
                ),
              ),
              if (count > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: selected
                        ? scheme.primary.withValues(alpha: 0.20)
                        : context.nasStyle.panelBorderColor,
                    borderRadius: radius,
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      height: 1.3,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? scheme.primary
                          : context.nasTextSecondary,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _empty(String text) => Center(
    child: Text(text, style: TextStyle(color: context.nasTextSecondary)),
  );

  // ---------------------------------------------------------------- 进行中

  /// 阶段文案 + 该阶段的百分比（排队、校验这类阶段没有百分比就返回 null）。
  ///
  /// 百分比按**当前阶段**算，不用 `task.overall`：整体进度里转码只占前 30%，
  /// 直接显示会让转码到一半的片子看着像刚起步。
  (String, int?) _stageOf(OfflineTaskRecord task) {
    switch (task.state) {
      case OfflineTaskState.waitingWifi:
        return (tr('video.offline.waitingWifi'), null);
      case OfflineTaskState.paused:
        return (tr('video.offline.pausedState'), null);
      case OfflineTaskState.queued:
        return (tr('video.offline.stageQueued'), null);
      case OfflineTaskState.transcoding:
        final pct = (task.progress * 100).clamp(0, 100).round();
        return (tr('video.offline.stageTranscoding', {'percent': '$pct'}), pct);
      case OfflineTaskState.downloading:
        if (task.totalBytes <= 0) return (tr('video.offline.downloading'), null);
        final pct = (task.downloadedBytes * 100 / task.totalBytes)
            .clamp(0, 100)
            .round();
        return (
          '${tr('video.offline.stageDownloading', {'percent': '$pct'})} · '
              '${formatBytes(task.downloadedBytes)} / ${formatBytes(task.totalBytes)}',
          pct,
        );
      case OfflineTaskState.verifying:
        return (tr('video.offline.stageVerifying'), null);
      case OfflineTaskState.replacing:
        return (tr('video.offline.stageReplacing'), null);
      default:
        return (tr('video.offline.downloading'), null);
    }
  }

  Widget _activeList(List<OfflineTaskRecord> tasks) {
    if (tasks.isEmpty) return _empty(tr('video.offline.empty'));
    return ListView.separated(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      itemCount: tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final task = tasks[i];
        final paused =
            task.state == OfflineTaskState.paused || task.state == OfflineTaskState.waitingWifi;
        final (label, percent) = _stageOf(task);
        return _card(
          title: task.title,
          subtitle: label,
          progress: task.overall,
          percent: percent,
          showProgress: true,
          actions: [
            if (paused)
              TextButton(
                onPressed: () => OfflineDownloadManager.instance.resume(task.itemId),
                child: Text(tr('video.offline.resume')),
              )
            else
              TextButton(
                onPressed: () => OfflineDownloadManager.instance.pause(task.itemId),
                child: Text(tr('video.offline.pause')),
              ),
            TextButton(
              onPressed: () => OfflineDownloadManager.instance.cancel(task.itemId),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(tr('video.offline.cancel')),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- 失败

  Widget _failedList(List<OfflineTaskRecord> tasks) {
    if (tasks.isEmpty) return _empty(tr('video.offline.empty'));
    return ListView.separated(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      itemCount: tasks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, i) {
        final task = tasks[i];
        return _card(
          title: task.title,
          subtitle: task.error ?? tr('video.offline.failed'),
          danger: true,
          actions: [
            TextButton(
              onPressed: () => OfflineDownloadManager.instance.retry(task.itemId),
              child: Text(tr('video.offline.retry')),
            ),
            TextButton(
              onPressed: () => OfflineDownloadManager.instance.cancel(task.itemId),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
              child: Text(tr('video.offline.removeTask')),
            ),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- 已完成

  Widget _doneList(List<LocalMediaItem> items) {
    if (items.isEmpty) return _empty(tr('video.offline.empty'));
    return ListView.separated(
      padding: const EdgeInsets.all(NasTokens.spaceMd),
      itemCount: items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final item = items[i];
        return ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(
            '${item.specLabel}${item.bytes > 0 ? ' · ${formatBytes(item.bytes)}' : ''}',
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: context.nasTextSecondary,
            ),
          ),
          onTap: () => _play(item),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                tooltip: tr('video.series.play'),
                icon: const Icon(Icons.play_arrow),
                onPressed: () => _play(item),
              ),
              IconButton(
                tooltip: tr('video.offline.deleteTitle'),
                icon: const Icon(Icons.delete_outline),
                onPressed: () => _delete(item),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _card({
    required String title,
    required String subtitle,
    required List<Widget> actions,
    double? progress,
    int? percent,
    bool showProgress = false,
    bool danger = false,
  }) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      decoration: BoxDecoration(
        color: context.nasStyle.panelColor,
        borderRadius: BorderRadius.circular(NasTokens.radiusSm),
        border: Border.all(color: context.nasStyle.panelBorderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            subtitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: NasTokens.fontCaption,
              color: danger
                  ? Theme.of(context).colorScheme.error
                  : context.nasTextSecondary,
            ),
          ),
          if (showProgress) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: progress,
                      minHeight: 6,
                    ),
                  ),
                ),
                // 百分比跟着条一起出现：光看条分不出「刚起步」还是「卡住了」
                if (percent != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '$percent%',
                    style: TextStyle(
                      fontSize: NasTokens.fontMicro,
                      fontWeight: FontWeight.w600,
                      color: context.nasTextSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ],
          Align(
            alignment: Alignment.centerRight,
            child: Row(mainAxisSize: MainAxisSize.min, children: actions),
          ),
        ],
      ),
    );
  }

  Future<void> _play(LocalMediaItem item) async {
    final store = _store;
    if (store == null) return;
    final file = File(store.absolute(item.filePath));
    if (!await file.exists()) {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(tr('video.offline.empty'))));
      await _load();
      return;
    }
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          url: file.uri.toString(),
          title: item.title,
          durationMs: item.durationMs > 0 ? item.durationMs : null,
          startAt: item.playbackMs > 5000 ? Duration(milliseconds: item.playbackMs) : null,
          onPosition: (pos) => OfflineDownloadManager.instance
              .savePlayback(item.id, pos.inMilliseconds)
              .ignore(),
          localSubtitles: [
            for (final rel in item.subtitlePaths) store.absolute(rel),
          ],
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _delete(LocalMediaItem item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('video.offline.deleteTitle')),
        content: Text(tr('video.offline.deleteBody')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('video.offline.deleteSelected', {'n': '1'})),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await OfflineDownloadManager.instance.deleteItems([item.id]);
    if (mounted) await _load();
  }
}
