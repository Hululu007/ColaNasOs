import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nas_ui/nas_ui.dart';

/// TV 版面缩放：与 `features/tv/tv_focus.dart#TvMetrics` 同一公式
/// （1920×1080 设计稿等比缩放，不设下限）。
///
/// 播放器在 Web / 手机 / 桌面也会用到这份代码，所以不 import TV 外壳目录 ——
/// TV 外壳是 TV 构建专属的，播放器不该被它绑住。
class TvLayout {
  const TvLayout(this.scale);

  factory TvLayout.of(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return TvLayout(width <= 0 ? 1 : (width / 1920).clamp(0.45, 2.4));
  }

  final double scale;

  double px(double value) => value * scale;
}

/// TV 播放控制层：全部是「自己画焦点」的组件，不依赖 Flutter 的焦点遍历。
///
/// 为什么不用 `TvFocusCard` + `focusInDirection`：遥控器的方向键在 Web / Android
/// 上会先被滚动体系吃掉，焦点能不能走完全取决于布局几何；播放页按钮是动态的
/// （有没有上一集 / 下一集、有没有字幕），布局一变焦点就可能卡住。这里改成
/// 由 [TvPlayerBar] 维护「第几行第几个」，方向键只改索引，**焦点永远存在**。
///
/// 组件职责边界：
/// - [TvPlayerButton] / [TvPlayerProgress] / [TvPlayerBar]：纯展示 + 点击回调；
/// - [TvPlayerPanel]：遥控器选项弹层（倍速 / 字幕 / 音轨 / 清晰度 / 信息）；
/// - 键位、seek 预览、自动隐藏、返回语义都在 `player_page.dart` 里。
class TvPlayerButton extends StatelessWidget {
  const TvPlayerButton({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.highlighted = false,
    this.size = 96,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool highlighted;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final color = enabled ? Colors.white : Colors.white38;
    // 内边距 / 图标 / 字号全部按 size 换算：只缩放宽度、内距写死的话，
    // 窄屏（scale < 0.7 的电视）上按钮会比宽度还高，看着是个竖着的长方形。
    final padding = size * 0.07;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedScale(
        scale: highlighted ? 1.06 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          // 宽 = size，高度略矮（0.88）：图标 + 一行文字就够了，
          // 正方形容器下面会空一大截，操作栏整体也就抬高（用户 2026-11-23：
          // 「不要太高就好」）。
          width: size,
          height: size * 0.88,
          padding: EdgeInsets.symmetric(horizontal: padding, vertical: padding),
          decoration: BoxDecoration(
            color: highlighted
                ? scheme.primary.withValues(alpha: 0.22)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: highlighted ? scheme.primary : Colors.transparent,
              width: 3,
            ),
            boxShadow: highlighted
                ? [
                    BoxShadow(
                      color: scheme.primary.withValues(alpha: 0.4),
                      blurRadius: 18,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: size * 0.34, color: color),
              SizedBox(height: size * 0.05),
              // 文字**不省略**：一行放不下就等比缩小字号。
              // 以前是 `maxLines: 1 + ellipsis`，像「画质 · 分辨率 / 码率」这种
              // 长标签会被截成「画质 ·…」，用户看不出这个按钮是干什么的。
              // 标签本身已经收短（见 `_tvActions`），这里只做兜底缩放。
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  style: TextStyle(
                    color: color,
                    fontSize: (size * 0.15).clamp(10.0, 16.0),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 大号进度条：底色 = 全片，亮色 = 已播，中间段 = 已转出，竖线 = seek 预览目标。
class TvPlayerProgress extends StatelessWidget {
  const TvPlayerProgress({
    super.key,
    required this.progress,
    required this.loaded,
    this.seekTarget,
    this.highlighted = false,
    required this.leftLabel,
    required this.rightLabel,
  });

  /// 0~1
  final double progress;

  /// 0~1（转码流已产出到哪；直连时传 null 表示不画）
  final double? loaded;

  /// 0~1（进度条聚焦、左右键调出来的待跳转位置）
  final double? seekTarget;
  final bool highlighted;
  final String leftLabel;
  final String rightLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final m = TvLayout.of(context);
    return Container(
      // 内距跟着版面缩放：大屏不显得挤、小屏也不白占高度
      padding: EdgeInsets.symmetric(horizontal: m.px(18), vertical: m.px(10)),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlighted ? scheme.primary : Colors.transparent,
          width: 3,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          LayoutBuilder(
            builder: (context, box) {
              final w = box.maxWidth;
              double at(double v) => (v.clamp(0.0, 1.0)) * w;
              return SizedBox(
                height: 14,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 4,
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    if (loaded != null)
                      Positioned(
                        left: 0,
                        width: at(loaded!),
                        top: 4,
                        child: Container(
                          height: 6,
                          decoration: BoxDecoration(
                            color: Colors.white38,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 0,
                      width: at(progress),
                      top: 4,
                      child: Container(
                        height: 6,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    Positioned(
                      left: (at(progress) - 6).clamp(0.0, w - 12),
                      top: 0,
                      child: Container(
                        width: 12,
                        height: 14,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                    ),
                    if (seekTarget != null)
                      Positioned(
                        left: (at(seekTarget!) - 1).clamp(0.0, w - 2),
                        top: 1,
                        child: Container(
                          width: 3,
                          height: 12,
                          color: Colors.white,
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                leftLabel,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              if (seekTarget != null)
                Text(
                  rightLabel,
                  style: TextStyle(
                    color: scheme.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                )
              else
                Text(
                  rightLabel,
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 底部按钮行：固定宽度 + 横向滚动到当前项。
///
/// 用 `SingleChildScrollView` 而不是 `Wrap`：TV 上「一行按钮」比两行更好按，
/// 窄窗口（浏览器预览 1280）也能靠滚动看到最后几个按钮。
class TvPlayerBar extends StatefulWidget {
  const TvPlayerBar({
    super.key,
    required this.buttons,
    required this.focusedIndex,
    this.itemWidth = 96,
    this.gap = 12,
  });

  final List<TvPlayerButton> buttons;

  /// -1 = 这一行没有焦点。
  final int focusedIndex;
  final double itemWidth;
  final double gap;

  @override
  State<TvPlayerBar> createState() => _TvPlayerBarState();
}

class _TvPlayerBarState extends State<TvPlayerBar> {
  final ScrollController _scroll = ScrollController();

  @override
  void didUpdateWidget(covariant TvPlayerBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusedIndex != widget.focusedIndex &&
        widget.focusedIndex >= 0) {
      final target = widget.focusedIndex * (widget.itemWidth + widget.gap);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        final max = _scroll.position.maxScrollExtent;
        _scroll.animateTo(
          target.clamp(0.0, max),
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      controller: _scroll,
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < widget.buttons.length; i += 1) ...[
            if (i > 0) SizedBox(width: widget.gap),
            widget.buttons[i],
          ],
        ],
      ),
    );
  }
}

/// 面板里的一项。
class TvPanelOption {
  const TvPanelOption({
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

/// 遥控器选项面板：标题 + 网格选项 + 「关闭」。
///
/// 返回被选中项的 `value`；返回 / 关闭返回 null。选项本身不可聚焦（用
/// GestureDetector 而不是 InkWell），焦点只留在面板根节点的 `Focus` 上，
/// 方向键由根节点统一换算成索引 —— 这样任何遥控器键码都不会「焦点跑丢」。
class TvPlayerPanel extends StatefulWidget {
  const TvPlayerPanel({
    super.key,
    required this.title,
    required this.options,
    this.hint,
    this.columns = 3,
    this.status,
  });

  final String title;
  final List<TvPanelOption> options;

  /// 面板底部的一行说明（例如「电视 HDR 能力：HDR10」）。
  final String? hint;
  final String? status;
  final int columns;

  static Future<String?> show(
    BuildContext context, {
    required String title,
    required List<TvPanelOption> options,
    String? hint,
    String? status,
    int columns = 3,
  }) {
    return showDialog<String>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => TvPlayerPanel(
        title: title,
        options: options,
        hint: hint,
        status: status,
        columns: columns,
      ),
    );
  }

  @override
  State<TvPlayerPanel> createState() => _TvPlayerPanelState();
}

class _TvPlayerPanelState extends State<TvPlayerPanel> {
  int _index = 0;

  int get _count => widget.options.length + 1; // 末尾多一个「关闭」

  bool get _onClose => _index >= widget.options.length;

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

  void _activate() {
    if (_onClose) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pop(widget.options[_index].value);
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
      _activate();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final m = TvLayout.of(context);
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: m.px(980)),
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
                  if (widget.status != null) ...[
                    SizedBox(height: m.px(6)),
                    Text(
                      widget.status!,
                      style: TextStyle(
                        color: Colors.white54,
                        fontSize: m.px(13),
                      ),
                    ),
                  ],
                  SizedBox(height: m.px(18)),
                  Wrap(
                    spacing: m.px(12),
                    runSpacing: m.px(12),
                    children: [
                      for (var i = 0; i < widget.options.length; i += 1)
                        _tile(context, m, i, widget.options[i]),
                      _tile(context, m, widget.options.length, null),
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
                  SizedBox(height: m.px(10)),
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
    TvLayout m,
    int index,
    TvPanelOption? option,
  ) {
    final scheme = Theme.of(context).colorScheme;
    final focused = _index == index;
    final selected = option?.selected ?? false;
    final color = selected ? scheme.primary : Colors.white;
    return GestureDetector(
      onTap: () {
        setState(() => _index = index);
        _activate();
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        // 宽度跟着文字给足：画质档位的完整名字是「1080P 1.4Mbps」，
        // 原来固定 210 在 1280 屏上会被截成「1080P 1.4Mb…」。
        width: m.px(option == null ? 140 : 268),
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
                    option?.label ?? tr('tv.player.close'),
                    // 允许两行：完整名字优先，极端长标签才省略
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: option == null ? Colors.white70 : color,
                      fontSize: m.px(16),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (option?.subtitle != null) ...[
                    SizedBox(height: m.px(4)),
                    Text(
                      option!.subtitle!,
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
