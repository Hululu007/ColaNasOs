import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_settings.dart';
import '../../core/app_version.dart';
import 'tv_update_dialog.dart';
import 'update_service.dart';

/// 更新提示对话框：版本说明 / 进度 / 稍后 / 失败兜底。
///
/// 文案要求（方案 §8.8）：每个状态都给一句有用的话，失败时必须告诉用户
/// 「下一步能做什么」（重试 / 手动下载），不允许出现「正在处理…」。
class UpdateDialog extends StatelessWidget {
  const UpdateDialog({super.key, required this.info});

  final ClientUpdate info;

  static Future<void> show(BuildContext context, ClientUpdate info) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => UpdateDialog(info: info),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ValueListenableBuilder<UpdateStatus>(
      valueListenable: UpdateService.instance.status,
      builder: (context, status, _) {
        final busy = status.busy;
        return AlertDialog(
          title: Text(tr('update.title')),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'v$kAppVersion',
                      style: TextStyle(
                        color: context.nasTextSecondary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6),
                      child: Icon(Icons.arrow_forward, size: 14),
                    ),
                    Text(
                      'v${info.latestSemver}',
                      style: TextStyle(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
                if (info.notes.trim().isNotEmpty) ...[
                  const SizedBox(height: NasTokens.spaceSm),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 160),
                    child: SingleChildScrollView(
                      child: Text(info.notes, style: const TextStyle(height: 1.5)),
                    ),
                  ),
                ],
                const SizedBox(height: NasTokens.spaceSm),
                Text(
                  _sizeHint(info, status),
                  style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                ),
                if (busy) ...[
                  const SizedBox(height: NasTokens.spaceMd),
                  LinearProgressIndicator(value: status.progress > 0 ? status.progress : null),
                  const SizedBox(height: NasTokens.spaceXs),
                  Text(
                    _progressHint(status),
                    style: TextStyle(fontSize: NasTokens.fontCaption, color: context.nasTextSecondary),
                  ),
                ],
                if (status.phase == UpdatePhase.failed) ...[
                  const SizedBox(height: NasTokens.spaceSm),
                  Text(
                    tr('update.failed', {'error': status.error}),
                    style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.error),
                  ),
                ],
                if (status.phase == UpdatePhase.done) ...[
                  const SizedBox(height: NasTokens.spaceSm),
                  Text(
                    tr('update.restartHint'),
                    style: TextStyle(fontSize: NasTokens.fontCaption, color: scheme.primary),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            if (!busy && status.phase != UpdatePhase.done)
              TextButton(
                onPressed: () {
                  UpdateService.instance.dismiss();
                  Navigator.of(context).pop();
                },
                child: Text(tr('update.later')),
              ),
            if (busy)
              TextButton(
                onPressed: () {
                  UpdateService.instance.cancel();
                },
                child: Text(tr('update.cancel')),
              ),
            if (!busy && status.phase != UpdatePhase.done)
              FilledButton(
                onPressed: () => UpdateService.instance.startInstall(),
                child: Text(
                  status.phase == UpdatePhase.failed ? tr('update.retry') : tr('update.now'),
                ),
              ),
            if (status.phase == UpdatePhase.done)
              FilledButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(tr('common.ok')),
              ),
          ],
        );
      },
    );
  }

  String _sizeHint(ClientUpdate info, UpdateStatus status) {
    final asset = info.assetFor(UpdateService.instance.component);
    final size = asset?.size ?? 0;
    if (size <= 0) return '';
    return tr('update.size', {'size': UpdateService.formatBytes(size)});
  }

  String _progressHint(UpdateStatus status) {
    switch (status.phase) {
      case UpdatePhase.downloading:
        final loaded = UpdateService.formatBytes(status.loaded);
        final total = status.total > 0 ? UpdateService.formatBytes(status.total) : '';
        final speed = UpdateService.formatSpeed(status.speed);
        final base = total.isEmpty ? loaded : '$loaded / $total';
        return speed.isEmpty ? base : '$base · $speed';
      case UpdatePhase.verifying:
        return tr('update.verifying');
      case UpdatePhase.installing:
        return tr('update.installing');
      default:
        return '';
    }
  }
}

/// 登录后挂在整个壳上的「有新版本」提示：只弹一次，用户点「稍后」不再打扰。
class UpdatePromptHost extends StatefulWidget {
  const UpdatePromptHost({super.key, required this.child});

  final Widget child;

  @override
  State<UpdatePromptHost> createState() => _UpdatePromptHostState();
}

class _UpdatePromptHostState extends State<UpdatePromptHost> {
  bool _showing = false;

  @override
  void initState() {
    super.initState();
    UpdateService.instance.available.addListener(_onAvailable);
  }

  @override
  void dispose() {
    UpdateService.instance.available.removeListener(_onAvailable);
    super.dispose();
  }

  void _onAvailable() {
    if (!mounted || _showing) return;
    final info = UpdateService.instance.available.value;
    if (info == null || !UpdateService.instance.shouldPrompt) return;
    _showing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // TV 端用索引式焦点弹窗：普通 AlertDialog 在 Android TV 上方向键经常不动
      if (AppSettings.instance.tvMode.value) {
        await showTvUpdateDialog(context, info);
      } else {
        await UpdateDialog.show(context, info);
      }
      _showing = false;
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
