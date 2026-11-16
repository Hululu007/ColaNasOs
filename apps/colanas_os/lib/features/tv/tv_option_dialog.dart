import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_ui/nas_ui.dart';

import 'tv_focus.dart';

/// 一个选项：`value` 是回传值，`selected` 决定打勾与高亮。
class TvOptionItem {
  const TvOptionItem({
    required this.value,
    required this.label,
    this.subtitle,
    this.selected = false,
  });

  final String value;
  final String label;
  final String? subtitle;
  final bool selected;
}

/// TV 通用选项弹窗：单列 / 双列网格 + 遥控器方向键 + OK + 返回。
///
/// 和播放页里的 `TvPlayerPanel` 是同一套交互，但这里不依赖播放器状态，
/// 「我的」页的设置项用它（默认码率 / 默认解码方式）。
///
/// 焦点不用 Flutter 的遍历，而是自己记「第几个」：遥控器方向键在 Android TV
/// 上会先被系统当 DPAD 事件，交给遍历时经常不移动；索引式永远能走。
Future<String?> showTvOptionDialog(
  BuildContext context, {
  required String title,
  required List<TvOptionItem> items,
  String? hint,
  int columns = 2,
}) {
  return showDialog<String>(
    context: context,
    barrierColor: Colors.black54,
    builder: (_) => _TvOptionDialog(
      title: title,
      items: items,
      hint: hint,
      columns: columns,
    ),
  );
}

class _TvOptionDialog extends StatefulWidget {
  const _TvOptionDialog({
    required this.title,
    required this.items,
    required this.hint,
    required this.columns,
  });

  final String title;
  final List<TvOptionItem> items;
  final String? hint;
  final int columns;

  @override
  State<_TvOptionDialog> createState() => _TvOptionDialogState();
}

class _TvOptionDialogState extends State<_TvOptionDialog> {
  int _index = 0;

  /// 末尾多一个「关闭」，保证任何时候都能用 OK 退出。
  int get _count => widget.items.length + 1;

  bool get _onClose => _index >= widget.items.length;

  void _move(int dx, int dy) {
    final cols = widget.columns;
    var next = _index;
    if (dy != 0) {
      next = (_index + dy * cols).clamp(0, _count - 1);
    } else if (dx != 0) {
      next = (_index + dx).clamp(0, _count - 1);
    }
    if (next != _index) setState(() => _index = next);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowLeft) {
      _move(-1, 0);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _move(1, 0);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      _move(0, -1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(0, 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.backspace ||
        k == LogicalKeyboardKey.goBack) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.numpadEnter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.gameButtonA ||
        k == LogicalKeyboardKey.space) {
      if (_onClose) {
        Navigator.of(context).pop();
      } else {
        Navigator.of(context).pop(widget.items[_index].value);
      }
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
          constraints: BoxConstraints(maxWidth: m.px(900)),
          child: Material(
            color: const Color(0xFF171717),
            borderRadius: BorderRadius.circular(22),
            child: Padding(
              padding: EdgeInsets.all(m.px(26)),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.title,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: m.px(24),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  SizedBox(height: m.px(18)),
                  Wrap(
                    spacing: m.px(12),
                    runSpacing: m.px(12),
                    children: [
                      for (var i = 0; i < widget.items.length; i += 1)
                        _tile(context, m, i, widget.items[i]),
                      _tile(context, m, widget.items.length, null),
                    ],
                  ),
                  if (widget.hint != null) ...[
                    SizedBox(height: m.px(16)),
                    Text(
                      widget.hint!,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: m.px(13),
                        height: 1.5,
                      ),
                    ),
                  ],
                  SizedBox(height: m.px(8)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context,
    TvMetrics m,
    int index,
    TvOptionItem? item,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _index == index;
    final selected = item?.selected ?? false;
    return GestureDetector(
      onTap: () {
        setState(() => _index = index);
        if (item == null) {
          Navigator.of(context).pop();
        } else {
          Navigator.of(context).pop(item.value);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: m.px(item == null ? 140 : 240),
        padding: EdgeInsets.symmetric(horizontal: m.px(16), vertical: m.px(12)),
        decoration: BoxDecoration(
          color: focused
              ? scheme.primary.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(m.px(14)),
          border: Border.all(
            color: focused ? scheme.primary : Colors.transparent,
            width: 3,
          ),
        ),
        child: Row(
          children: [
            if (selected)
              Padding(
                padding: EdgeInsets.only(right: m.px(8)),
                child: Icon(
                  Icons.check_rounded,
                  size: m.px(18),
                  color: scheme.primary,
                ),
              ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item?.label ?? tr('tv.player.close'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: item == null ? Colors.white70 : Colors.white,
                      fontSize: m.px(16),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (item?.subtitle != null) ...[
                    SizedBox(height: m.px(4)),
                    Text(
                      item!.subtitle!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: m.px(12),
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
