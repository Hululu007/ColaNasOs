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

  Widget _tabChip(int index, String label, int count) {
    final selected = _tab == index;
    return ChoiceChip(
      label: Text(count > 0 ? '$label $count' : label),
      selected: selected,
      onSelected: (_) => setState(() => _tab = index),
      selectedColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.16),
    );
  }

  Widget _empty(String text) => Center(
    child: Text(text, style: TextStyle(color: context.nasTextSecondary)),
  );

  // ---------------------------------------------------------------- 进行中

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
        final label = switch (task.state) {
          OfflineTaskState.waitingWifi => tr('video.offline.waitingWifi'),
          OfflineTaskState.paused => tr('video.offline.pausedState'),
          OfflineTaskState.transcoding || OfflineTaskState.queued =>
            tr('video.offline.preparing'),
          _ => tr('video.offline.downloading'),
        };
        return _card(
          title: task.title,
          subtitle: label,
          progress: task.overall,
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
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(value: progress, minHeight: 6),
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
