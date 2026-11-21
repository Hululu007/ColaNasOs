import 'dart:async';

import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_version.dart';
import '../../core/session.dart';
import 'update_dialog.dart';
import 'update_service.dart';

/// 设置 →「软件更新」区块（客户端 + 服务端）。
///
/// 设计取舍：
///   - 客户端更新只在**登录后**检查一次，这里点「检查更新」是强制的（`force=1`）；
///   - 服务端更新默认**不自动**安装：NAS 常在跑转码 / 做种，切版本会重启内核，
///     所以必须用户点「立即更新」→ 看进度 → 再点「重启生效」。
class UpdateSection extends StatefulWidget {
  const UpdateSection({super.key});

  @override
  State<UpdateSection> createState() => _UpdateSectionState();
}

class _UpdateSectionState extends State<UpdateSection> {
  SystemUpdateCheckResponse? _server;
  SystemUpdateJob? _job;
  Timer? _poll;
  bool _checking = false;
  bool _autoCheck = false;
  String? _error;
  String _versionDir = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
    _refreshServer();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    try {
      final cfg = await ApiSession.instance.client.systemUpdateConfig();
      if (!mounted) return;
      setState(() {
        _autoCheck = cfg.autoCheck;
        _versionDir = cfg.versionDir;
      });
    } catch (_) {
      // 老服务端没有这个接口：静默，界面上少一行而已
    }
  }

  Future<void> _refreshServer({bool force = true}) async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final res = await ApiSession.instance.client.systemUpdateCheck(
        component: 'server',
        force: force ? '1' : '0',
      );
      if (!mounted) return;
      setState(() {
        _server = res;
        // 服务端检查失败是 200 + error（离线 NAS 是常态），要如实告诉用户
        _error = res.error.isEmpty ? null : res.error;
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _checking = false;
      });
    }
  }

  Future<void> _startServerUpdate() async {
    try {
      final res = await ApiSession.instance.client.systemUpdateInstall(
        body: SystemUpdateInstallBody(force: true),
      );
      if (!mounted) return;
      setState(() => _job = res.job);
      _startPolling();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  void _startPolling() {
    _poll?.cancel();
    _poll = Timer.periodic(const Duration(milliseconds: 800), (timer) async {
      try {
        final res = await ApiSession.instance.client.systemUpdateStatus();
        if (!mounted) {
          timer.cancel();
          return;
        }
        setState(() => _job = res.job);
        final phase = res.job.phase;
        if (phase != 'preparing' &&
            phase != 'downloading' &&
            phase != 'verifying' &&
            phase != 'assembling' &&
            phase != 'activating') {
          timer.cancel();
          if (phase == 'ready') await _refreshServer(force: false);
        }
      } catch (_) {
        timer.cancel();
      }
    });
  }

  Future<void> _restartServer() async {
    try {
      await ApiSession.instance.client.systemUpdateRestart();
      if (!mounted) return;
      NasSnack.show(context, tr('update.restartingServer'));
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _rollback() async {
    try {
      await ApiSession.instance.client.systemUpdateRollback();
      await _refreshServer();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  Future<void> _toggleAutoCheck(bool on) async {
    setState(() => _autoCheck = on);
    try {
      await ApiSession.instance.client.systemUpdateConfigSave(
        body: SystemUpdateConfigBody(autoCheck: on),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _autoCheck = !on;
        _error = '$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final clientInfo = UpdateService.instance.available.value;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _clientRow(),
        if (clientInfo != null && clientInfo.hasUpdate)
          Padding(
            padding: const EdgeInsets.only(top: NasTokens.spaceXs),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    tr('update.clientAvailable', {'version': clientInfo.latestSemver}),
                    style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
                  ),
                ),
                TextButton(
                  onPressed: () => UpdateDialog.show(context, clientInfo),
                  child: Text(tr('update.now')),
                ),
              ],
            ),
          ),
        const Divider(height: NasTokens.spaceLg),
        // ---------------- 服务端 ----------------
        Row(
          children: [
            Expanded(
              child: Text(
                tr('update.serverTitle'),
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            if (_checking)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              TextButton(
                onPressed: () => _refreshServer(),
                child: Text(tr('update.check')),
              ),
          ],
        ),
        const SizedBox(height: NasTokens.spaceXs),
        _serverBody(),
        if (_versionDir.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: NasTokens.spaceXs),
            child: SelectableText(
              tr('update.versionDir', {'dir': _versionDir}),
              style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
            ),
          ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _autoCheck,
          onChanged: _toggleAutoCheck,
          title: Text(tr('update.autoCheck')),
          subtitle: Text(
            tr('update.autoCheckHint'),
            style: TextStyle(fontSize: NasTokens.fontCaption),
          ),
        ),
        if (_error != null)
          Text(
            _error!,
            style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
          ),
      ],
    );
  }

  Widget _clientRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tr('update.clientTitle'), style: const TextStyle(fontWeight: FontWeight.w600)),
              Text(
                'v$kAppVersion',
                style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
              ),
            ],
          ),
        ),
        ValueListenableBuilder<UpdateStatus>(
          valueListenable: UpdateService.instance.status,
          builder: (context, status, _) {
            if (status.phase == UpdatePhase.checking) {
              return const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              );
            }
            return TextButton(
              onPressed: () async {
                await UpdateService.instance.check(force: true);
                if (!context.mounted) return;
                final info = UpdateService.instance.available.value;
                if (info != null && info.hasUpdate) {
                  await UpdateDialog.show(context, info);
                } else {
                  NasSnack.show(context, tr('update.none'));
                }
              },
              child: Text(tr('update.check')),
            );
          },
        ),
      ],
    );
  }

  Widget _serverBody() {
    final scheme = Theme.of(context).colorScheme;
    final server = _server;
    if (server == null) {
      return Text(
        _checking ? tr('update.checking') : '',
        style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
      );
    }
    final job = _job;
    if (job != null &&
        job.phase != 'idle' &&
        job.phase != 'ready' &&
        job.phase != 'failed' &&
        job.phase != 'cancelled') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          LinearProgressIndicator(value: job.percent > 0 ? job.percent / 100 : null),
          const SizedBox(height: NasTokens.spaceXs),
          Text(
            '${job.message}  ${job.total > 0 ? '${UpdateService.formatBytes(job.loaded)} / ${UpdateService.formatBytes(job.total)}' : ''}'
            '${job.speed > 0 ? ' · ${UpdateService.formatSpeed(job.speed)}' : ''}',
            style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
          ),
        ],
      );
    }
    if (job?.phase == 'failed') {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('update.failed', {'error': job?.error ?? ''}),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
          ),
          if (job?.hint != 'manual')
            TextButton(onPressed: _startServerUpdate, child: Text(tr('update.retry'))),
        ],
      );
    }
    if (job?.phase == 'ready') {
      // 全量模式下载的是安装包：重启内核装不上它，只能把路径交给人
      if (job?.mode == 'full') {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('update.fullReady'),
              style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
            ),
            if ((job?.hint ?? '').isNotEmpty)
              SelectableText(
                job?.hint ?? '',
                style: TextStyle(
                  fontSize: NasTokens.fontCaption,
                  color: context.nasTextSecondary,
                ),
              ),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            tr('update.serverReady'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
          ),
          Row(
            children: [
              FilledButton(onPressed: _restartServer, child: Text(tr('update.restartNow'))),
              const SizedBox(width: NasTokens.spaceSm),
              TextButton(onPressed: _restartServer, child: Text(tr('update.serverRestart'))),
            ],
          ),
        ],
      );
    }
    if (!server.hasUpdate) {
      return Text(
        tr('update.noneWithVersion', {'version': server.currentSemver}),
        style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
      );
    }
    final modeText = server.mode == 'delta'
        ? tr('update.modeDelta', {'size': UpdateService.formatBytes(server.deltaBytes)})
        : tr('update.modeFull');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          tr('update.serverAvailable', {'version': server.latestSemver}),
          style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
        ),
        Text(
          modeText,
          style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
        ),
        if (server.needsReshell)
          Text(
            tr('update.needsReshell'),
            style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
          ),
        const SizedBox(height: NasTokens.spaceXs),
        Wrap(
          spacing: NasTokens.spaceSm,
          children: [
            if (!server.needsReshell)
              FilledButton(onPressed: _startServerUpdate, child: Text(tr('update.serverInstall'))),
            TextButton(onPressed: _rollback, child: Text(tr('update.rollback'))),
          ],
        ),
      ],
    );
  }
}
