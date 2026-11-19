import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../shell/app_nav_shell.dart';
import '../../shell/app_widgets.dart';

import '../../core/session.dart';
import 'sync_create_wizard.dart';
import 'sync_engine.dart';
import 'sync_record_dialog.dart';
import 'sync_task_card.dart';
import 'sync_tray_bridge.dart';

/// 目录同步：左侧二级菜单 + 任务列表。
///
/// 与旧页面的区别：旧页面是「选两个目录 → 立即合并」的一次性操作；
/// 这里是持久化任务（设备 / 模式 / 本地与 NAS 目录 / include-exclude）+
/// 三向比对执行 + 运行记录。服务端负责扫远端与基线，客户端负责本地扫描与传输。
class SyncPage extends StatefulWidget {
  const SyncPage({super.key});

  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final _engine = SyncEngine.instance;
  final _searchCtrl = TextEditingController();

  bool _loading = true;
  String? _error;
  List<SyncTask> _tasks = const [];
  String _keyword = '';
  String _deviceId = '';
  String _deviceName = '';

  @override
  void initState() {
    super.initState();
    _engine.revision.addListener(_onEngine);
    _searchCtrl.addListener(_onSearch);
    unawaited(_initializeAndLoad());
  }

  @override
  void dispose() {
    _engine.revision.removeListener(_onEngine);
    _searchCtrl.removeListener(_onSearch);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch() {
    if (mounted) setState(() => _keyword = _searchCtrl.text);
  }

  void _onEngine() {
    if (mounted) setState(() {});
  }

  Future<void> _initializeAndLoad() async {
    await _initDevice();
    await _load();
  }

  Future<void> _initDevice() async {
    try {
      final id = await _engine.fs.resolveDeviceId();
      final name = await _engine.fs.resolveDeviceName();
      if (!mounted) return;
      setState(() {
        _deviceId = id;
        _deviceName = name;
      });
      await _claimMachineTasks(id);
    } catch (_) {
      // 设备标识解析失败不阻断页面：创建任务时再兜底
    }
  }

  /// 将当前机器的旧客户端任务迁到统一机器 ID；失败不阻断列表加载
  Future<void> _claimMachineTasks(String deviceId) async {
    if (deviceId.isEmpty ||
        !_engine.fs.canSync ||
        ColanasClientId.value != deviceId) {
      return;
    }
    try {
      await ApiSession.instance.client.syncClaimLegacy(
        body: <String, dynamic>{'deviceId': deviceId},
      );
    } catch (e) {
      // 老服务端没有迁移接口时仍可加载当前 clientId 下的任务。
      debugPrint('[sync] claim machine tasks failed: $e');
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.syncTaskList();
      final raw = (res['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _tasks = raw
            .whereType<Map>()
            .map((e) => SyncTask.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        _loading = false;
      });
      // 任务增删后托盘里的「立即同步」是否可点要跟着变
      unawaited(syncTrayBridge.refresh());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _openWizard({SyncTask? editing}) async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => SyncCreateWizard(
        editing: editing,
        deviceId: _deviceId,
        deviceName: _deviceName,
      ),
    );
    if (ok == true) await _load();
  }

  Future<void> _delete(SyncTask task) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(tr('sync.delete.title')),
        content: Text(tr('sync.delete.body')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(tr('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('common.delete')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ApiSession.instance.client.syncTaskDelete(body: {'id': task.id});
      await _load();
    } catch (e) {
      if (!mounted) return;
      NasSnack.show(context, '$e');
    }
  }

  Future<void> _run(SyncTask task) async {
    final messenger = ScaffoldMessenger.of(context);
    final result = await _engine.run(task);
    if (!mounted) return;
    NasSnack.showOn(
      messenger,
      result.ok
          ? tr('sync.run.ok', {
              'up': result.uploaded,
              'down': result.downloaded,
              'del': result.deleted,
              'skip': result.skipped,
            })
          : tr('sync.run.failed', {
              'error':
                  result.error ??
                  (result.errors.isEmpty ? '' : result.errors.first),
            }),
    );
    await _load();
  }

  List<SyncTask> get _visible {
    final k = _keyword.trim().toLowerCase();
    if (k.isEmpty) return _tasks;
    return _tasks.where((t) {
      return t.deviceName.toLowerCase().contains(k) ||
          t.localDir.toLowerCase().contains(k) ||
          t.remoteDir.toLowerCase().contains(k);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final canSync = _engine.fs.canSync;
    // 2026-11-04：改用统一的二级菜单（AppNavShell）——菜单项来自
    // `contracts/apps.json#sync.nav`，和影视/相册/音乐同一套骨架，
    // 不再自己手写一套侧栏（宽度、折叠、选中态都各自一套，看着就不是一家人）。
    return AppNavShell(
      appId: 'sync',
      defaultKey: 'tasks',
      content: (key) => _content(key, canSync),
    );
  }

  /// 二级菜单分发（`tool/check/app-nav-check.js` 按这个方法名做对账）
  Widget _content(String key, bool canSync) {
    switch (key) {
      case 'help':
        return _help();
      // nav-default: tasks
      default:
        return _tasksView(canSync);
    }
  }

  Widget _tasksView(bool canSync) {
    if (_loading) return const NasLoading();
    if (_error != null) return NasErrorState(message: _error!, onRetry: _load);
    final items = _visible;
    final wide = MediaQuery.sizeOf(context).width >= 760;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NasTokens.spaceMd,
            NasTokens.spaceSm,
            NasTokens.spaceSm,
            0,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('sync.taskCount', {'count': items.length}),
                      style: TextStyle(
                        fontSize: NasTokens.fontCaption,
                        color: context.nasTextSecondary,
                      ),
                    ),
                    if (!canSync)
                      Text(
                        tr('sync.webUnsupported'),
                        style: TextStyle(
                          fontSize: NasTokens.fontMicro,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
              if (wide)
                SizedBox(
                  width: 220,
                  child: NasSearchField(
                    controller: _searchCtrl,
                    hintText: tr('common.search'),
                  ),
                ),
              const SizedBox(width: NasTokens.spaceXs),
              // 换成统一二级菜单后没有 AppBar 了，刷新与「新建」挪到这里
              NasRefreshButton(onPressed: _load),
              if (canSync)
                Padding(
                  padding: const EdgeInsets.only(left: NasTokens.spaceXs),
                  child: wide
                      ? FilledButton.icon(
                          onPressed: () => _openWizard(),
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(tr('sync.createTask')),
                        )
                      : IconButton.filled(
                          tooltip: tr('sync.createTask'),
                          onPressed: () => _openWizard(),
                          icon: const Icon(Icons.add, size: 18),
                        ),
                ),
            ],
          ),
        ),
        if (!wide)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NasTokens.spaceMd,
              NasTokens.spaceXs,
              NasTokens.spaceMd,
              0,
            ),
            child: NasSearchField(
              controller: _searchCtrl,
              hintText: tr('common.search'),
            ),
          ),
        Expanded(
          child: items.isEmpty
              ? ListView(
                  children: [
                    const SizedBox(height: NasTokens.spaceXl),
                    NasEmptyState(
                      title: tr('sync.emptyTasks'),
                      icon: Icons.sync,
                    ),
                    if (canSync)
                      Center(
                        child: FilledButton.icon(
                          onPressed: () => _openWizard(),
                          icon: const Icon(Icons.add, size: 18),
                          label: Text(tr('sync.createTask')),
                        ),
                      ),
                  ],
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(
                      horizontal: NasTokens.spaceMd,
                      vertical: NasTokens.spaceSm,
                    ),
                    itemCount: items.length,
                    itemBuilder: (context, i) {
                      final task = items[i];
                      return SyncTaskCard(
                        task: task,
                        engine: _engine,
                        canRun: canSync,
                        onRun: () => _run(task),
                        onEdit: () => _openWizard(editing: task),
                        onDelete: () => _delete(task),
                        onRecords: () => showDialog<void>(
                          context: context,
                          builder: (_) => SyncRecordDialog(task: task),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Widget _help() {
    return ListView(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      children: [
        Text(
          tr('sync.help.title'),
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: NasTokens.spaceSm),
        for (final line in tr('sync.help.body').split('\n'))
          Padding(
            padding: const EdgeInsets.only(bottom: NasTokens.spaceXs),
            child: Text(line),
          ),
      ],
    );
  }
}
