import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../core/app_version.dart';
import '../tv/tv_focus.dart';
import 'update_service.dart';

/// TV 端更新弹窗。
///
/// 为什么不能直接用 `AlertDialog`：Android TV 上遥控器的 DPAD 会被系统先吃掉一层，
/// Flutter 自带的焦点遍历经常「按了不动」；项目里已有的做法是**自己记索引**，
/// 方向键直接改选择项（见 `tv_option_dialog.dart` 的说明）。这里沿用同一套：
///   左右/上下：在两个按钮之间切；OK：确认；返回：稍后（下载中 = 取消）。
///
/// 版式也按 10-foot UI：字大、进度条粗、说明文字最多三行可滚。
class TvUpdateDialog extends StatefulWidget {
  const TvUpdateDialog({super.key, required this.info});

  final ClientUpdate info;

  @override
  State<TvUpdateDialog> createState() => _TvUpdateDialogState();
}

class _TvUpdateDialogState extends State<TvUpdateDialog> {
  /// 默认落在右侧「立即更新」：插上就能按 OK 更新，不用先挪焦点
  int _index = 1;

  @override
  void initState() {
    super.initState();
    UpdateService.instance.status.addListener(_onStatus);
  }

  @override
  void dispose() {
    UpdateService.instance.status.removeListener(_onStatus);
    super.dispose();
  }

  void _onStatus() {
    if (!mounted) return;
    setState(() {
      final n = _actions().length;
      if (_index >= n) _index = n - 1;
      if (_index < 0) _index = 0;
    });
  }

  List<_TvAction> _actions() {
    final phase = UpdateService.instance.status.value.phase;
    // 清单里没有本端能装的包（TV 只认 apk_tv）：不给「立即更新」，只能稍后
    final hasAsset =
        widget.info.assetFor(UpdateService.instance.component) != null;
    switch (phase) {
      case UpdatePhase.downloading:
      case UpdatePhase.verifying:
      case UpdatePhase.installing:
        return const [_TvAction.cancel];
      case UpdatePhase.done:
        return const [_TvAction.close];
      case UpdatePhase.failed:
        return hasAsset
            ? const [_TvAction.later, _TvAction.retry]
            : const [_TvAction.later];
      default:
        return hasAsset
            ? const [_TvAction.later, _TvAction.install]
            : const [_TvAction.later];
    }
  }

  void _activate(_TvAction action) {
    final service = UpdateService.instance;
    switch (action) {
      case _TvAction.later:
        service.dismiss();
        Navigator.of(context).pop();
      case _TvAction.install:
      case _TvAction.retry:
        service.startInstall();
      case _TvAction.cancel:
        service.cancel();
        Navigator.of(context).pop();
      case _TvAction.close:
        Navigator.of(context).pop();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final actions = _actions();
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.arrowUp) {
      if (_index > 0) setState(() => _index -= 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowDown) {
      if (_index < actions.length - 1) setState(() => _index += 1);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.backspace ||
        key == LogicalKeyboardKey.goBack) {
      // 返回键 = 稍后；下载中返回 = 取消（片段保留，下次续传）
      final phase = UpdateService.instance.status.value.phase;
      if (phase == UpdatePhase.downloading ||
          phase == UpdatePhase.verifying ||
          phase == UpdatePhase.installing) {
        UpdateService.instance.cancel();
      } else {
        UpdateService.instance.dismiss();
      }
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.gameButtonA ||
        key == LogicalKeyboardKey.space) {
      _activate(actions[_index]);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: m.px(920)),
          child: Material(
            color: const Color(0xFF171717),
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: EdgeInsets.all(m.px(30)),
              child: ValueListenableBuilder<UpdateStatus>(
                valueListenable: UpdateService.instance.status,
                builder: (context, status, _) => Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr('update.title'),
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: m.px(30),
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    SizedBox(height: m.px(12)),
                    Row(
                      children: [
                        Text(
                          'v$kAppVersion',
                          style: TextStyle(
                            color: Colors.white54,
                            fontSize: m.px(20),
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: m.px(10)),
                          child: Icon(
                            Icons.arrow_forward,
                            size: m.px(18),
                            color: Colors.white54,
                          ),
                        ),
                        Text(
                          'v${widget.info.latestSemver}',
                          style: TextStyle(
                            color: const Color(0xFF7FD1FF),
                            fontSize: m.px(22),
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                    if (widget.info.notes.trim().isNotEmpty) ...[
                      SizedBox(height: m.px(16)),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxHeight: m.px(150)),
                        child: SingleChildScrollView(
                          child: Text(
                            widget.info.notes,
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: m.px(17),
                              height: 1.55,
                            ),
                          ),
                        ),
                      ),
                    ],
                    SizedBox(height: m.px(14)),
                    Text(
                      _sizeLine(status),
                      style: TextStyle(color: Colors.white54, fontSize: m.px(15)),
                    ),
                    if (status.busy) ...[
                      SizedBox(height: m.px(20)),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(m.px(6)),
                        // 进度条按 10-foot UI 加粗：隔着 3 米要看得出走了多少
                        child: LinearProgressIndicator(
                          minHeight: m.px(12),
                          value: status.progress > 0 ? status.progress : null,
                          backgroundColor: Colors.white12,
                          valueColor: const AlwaysStoppedAnimation(Color(0xFF7FD1FF)),
                        ),
                      ),
                      SizedBox(height: m.px(10)),
                      Text(
                        _progressLine(status),
                        style: TextStyle(color: Colors.white70, fontSize: m.px(16)),
                      ),
                    ],
                    if (status.phase == UpdatePhase.failed) ...[
                      SizedBox(height: m.px(14)),
                      Text(
                        tr('update.failed', {'error': status.error}),
                        style: TextStyle(color: const Color(0xFFFF8A80), fontSize: m.px(15)),
                      ),
                    ],
                    if (status.phase == UpdatePhase.done) ...[
                      SizedBox(height: m.px(14)),
                      Text(
                        tr('update.restartHint'),
                        style: TextStyle(color: const Color(0xFF7FD1FF), fontSize: m.px(16)),
                      ),
                    ],
                    SizedBox(height: m.px(26)),
                    Row(
                      children: [
                        for (var i = 0; i < _actions().length; i += 1) ...[
                          _button(m, _actions()[i], i == _index),
                          if (i < _actions().length - 1) SizedBox(width: m.px(16)),
                        ],
                      ],
                    ),
                    SizedBox(height: m.px(14)),
                    Text(
                      tr('update.tvHint'),
                      style: TextStyle(color: Colors.white38, fontSize: m.px(13)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _button(TvMetrics m, _TvAction action, bool focused) {
    final label = switch (action) {
      _TvAction.later => tr('update.later'),
      _TvAction.install => tr('update.now'),
      _TvAction.retry => tr('update.retry'),
      _TvAction.cancel => tr('update.cancel'),
      _TvAction.close => tr('common.ok'),
    };
    final primary = action != _TvAction.later;
    return Expanded(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        height: m.px(56),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: focused
              ? (primary ? const Color(0xFF2D7FF9) : Colors.white24)
              : (primary ? const Color(0xFF1D5FBF) : Colors.white10),
          borderRadius: BorderRadius.circular(m.px(14)),
          border: Border.all(
            color: focused ? Colors.white : Colors.transparent,
            width: m.px(2),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: m.px(20),
            fontWeight: focused ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  String _sizeLine(UpdateStatus status) {
    final asset = widget.info.assetFor(UpdateService.instance.component);
    if (asset == null) return tr('update.noAsset');
    final size = asset.size;
    if (size <= 0) return '';
    return tr('update.size', {'size': UpdateService.formatBytes(size)});
  }

  String _progressLine(UpdateStatus status) {
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

enum _TvAction { later, install, retry, cancel, close }

/// 打开 TV 版更新弹窗（遥控器可用）
Future<void> showTvUpdateDialog(BuildContext context, ClientUpdate info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => TvUpdateDialog(info: info),
  );
}
