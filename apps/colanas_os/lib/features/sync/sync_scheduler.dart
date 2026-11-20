import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:nas_core/nas_core.dart';

import '../../core/session.dart';
import 'sync_engine.dart';
import 'sync_watch.dart';

/// 后台自动同步（主客户端内置）。
///
/// 应用运行期间每分钟检查一次：到点的任务（距上次运行 ≥ 间隔）自动跑一轮。
/// 调度由应用生命周期托管，任务自己的 intervalMinutes 是唯一的定时配置。
class SyncScheduler {
  SyncScheduler._();

  static final SyncScheduler instance = SyncScheduler._();

  Timer? _timer;
  bool _busy = false;
  String? _deviceId;
  String? _claimedScope;
  final _watch = createSyncWatcher();

  /// 当前账号没有同步权限（403）时置位：本进程内不再重复请求。
  ///
  /// 以前 claim 失败只打一行 debugPrint，`_claimedScope` 也不写，于是每分钟
  /// 重试一次 —— 服务端日志里 3MB 就攒了 466 条 403，真正的问题全被冲掉了。
  /// 权限是按账号发的（`auth_users.scopes` 里没有 sync:read / sync:write），
  /// 重试一万次也不会自己好，收益为零。
  bool _scopeDenied = false;

  void start() {
    if (!SyncEngine.instance.fs.canSync) return;
    if (_timer != null) return;
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    unawaited(_tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _watch.stop();
  }

  /// 立即同步：忽略每任务间隔，把本机所有任务跑一轮。
  ///
  /// 托盘的「立即同步」用它 —— `_tick` 只跑到点的任务，用户主动点的时候
  /// 预期是「现在就同步」，不该被间隔挡住。跑的还是同一套 [SyncEngine.run]，
  /// 所以进度、冲突、记录都跟界面里点「同步」一致。
  Future<void> runAllNow() async {
    if (_busy || !ApiSession.instance.authed) return;
    if (!SyncEngine.instance.fs.canSync) return;
    _busy = true;
    try {
      _deviceId ??= await SyncEngine.instance.fs.resolveDeviceId();
      final tasks = await _loadTasks();
      for (final task in tasks) {
        // 只跑本机创建的任务：别的设备的目录/基线不该被这台机器动
        if (task.deviceId.isNotEmpty && task.deviceId != _deviceId) continue;
        if (SyncEngine.instance.isRunning(task.id)) continue;
        await SyncEngine.instance.run(task);
      }
    } catch (e) {
      debugPrint('[sync] runAllNow failed: $e');
    } finally {
      _busy = false;
    }
  }

  /// 拉一次任务列表（托盘要用它算「本机任务数」，界面也要用）
  Future<List<SyncTask>> _loadTasks() async {
    // 没有同步权限就别再去拉列表：任务列表接口同样要 sync:read，只会再来一条 403
    if (_scopeDenied) return const [];
    final deviceId = _deviceId;
    await _claimMachineTasks(deviceId);
    if (_scopeDenied) return const [];
    final res = await ApiSession.instance.client.syncTaskList();
    final raw = (res['items'] as List?) ?? const [];
    return raw
        .whereType<Map>()
        .map((e) => SyncTask.fromJson(Map<String, dynamic>.from(e)))
        .toList();
  }

  Future<void> _claimMachineTasks(String? deviceId) async {
    if (_scopeDenied) return;
    if (deviceId == null ||
        deviceId.isEmpty ||
        ColanasClientId.value != deviceId) {
      return;
    }
    final scope =
        '${ApiSession.instance.baseUrl}|${ApiSession.instance.username}|$deviceId';
    if (_claimedScope == scope) return;
    try {
      await ApiSession.instance.client.syncClaimLegacy(
        body: <String, dynamic>{'deviceId': deviceId},
      );
      _claimedScope = scope;
    } on ApiError catch (e) {
      // 403 / 401 是权限或登录态问题，按账号发的权限不会因为重试而变好：
      // 记一次就停手，等用户改权限或重新登录（重启进程）再试。
      if (e.statusCode == 403 || e.statusCode == 401) {
        _scopeDenied = true;
        debugPrint('[sync] 当前账号没有同步权限（${e.statusCode}），本次运行不再重试');
        return;
      }
      debugPrint('[sync] claim machine tasks failed: $e');
    } catch (e) {
      debugPrint('[sync] claim machine tasks failed: $e');
    }
  }

  /// 本机任务数：托盘的「立即同步」据此置灰（0 个任务时点了也没事可做）
  Future<int> localTaskCount() async {
    if (!ApiSession.instance.authed) return 0;
    try {
      _deviceId ??= await SyncEngine.instance.fs.resolveDeviceId();
      final tasks = await _loadTasks();
      return tasks
          .where((t) => t.deviceId.isEmpty || t.deviceId == _deviceId)
          .length;
    } catch (e) {
      debugPrint('[sync] localTaskCount failed: $e');
      return 0;
    }
  }

  Future<void> _tick() async {
    if (_busy || !ApiSession.instance.authed) return;
    if (!SyncEngine.instance.fs.canSync) return;
    _busy = true;
    try {
      _deviceId ??= await SyncEngine.instance.fs.resolveDeviceId();
      final tasks = await _loadTasks();
      _watch.sync(tasks);
      final now = DateTime.now().millisecondsSinceEpoch;
      for (final task in tasks) {
        // 只跑本机创建的任务：别的设备的目录/基线不该被这台机器动
        if (task.deviceId.isNotEmpty && task.deviceId != _deviceId) continue;
        if (SyncEngine.instance.isRunning(task.id)) continue;
        // 每任务间隔：0 = 仅手动
        final minutes = task.syncConfig.intervalMinutes;
        if (minutes <= 0) continue;
        final gap = minutes * 60 * 1000;
        // lastRunAt 是 Unix **秒**，跟毫秒的 now 直接相减会得出 1.7e12 的巨值 →
        // 间隔判断永远成立，等于「每分钟都同步一次」。这里统一到毫秒再比。
        final lastMs = task.lastRunAt == null ? null : task.lastRunAt! * 1000;
        if (lastMs != null && now - lastMs < gap) continue;
        await SyncEngine.instance.run(task);
      }
    } catch (e) {
      debugPrint('[sync] auto scheduler tick failed: $e');
    } finally {
      _busy = false;
    }
  }
}
