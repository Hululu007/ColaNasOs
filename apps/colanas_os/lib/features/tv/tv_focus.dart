import 'package:flutter/material.dart';

/// TV 版面尺寸：以 1920×1080 设计稿为基准等比缩放。
///
/// 浏览器预览窗口通常只有 1280~1600 宽，直接按 1920 排会显得空旷；
/// 这里给一个下限 0.85，保证窗口小一点时仍然是「大卡片 + 大字号」的观感。
class TvMetrics {
  const TvMetrics(this.scale);

  factory TvMetrics.of(double width) =>
      TvMetrics((width / 1920).clamp(0.85, 1.5));

  final double scale;

  double px(double value) => value * scale;
}

/// 分区内部的返回处理（详情 → 列表）。
///
/// 外壳收到 Backspace / Esc 时先问当前分区是否消费；没消费就把焦点送回左侧导航。
class TvBackController {
  bool Function()? handler;

  /// 当前分区是否处于详情 / 子页面。外壳据此决定 ↑ 是否直接回顶部 tab。
  bool Function()? overlay;

  bool handle() => handler?.call() ?? false;

  bool get hasOverlay => overlay?.call() ?? false;
}

class TvMetricsScope extends InheritedWidget {
  const TvMetricsScope({super.key, required this.metrics, required super.child});

  final TvMetrics metrics;

  static TvMetrics of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TvMetricsScope>()?.metrics ??
      const TvMetrics(1);

  @override
  bool updateShouldNotify(TvMetricsScope oldWidget) =>
      metrics.scale != oldWidget.metrics.scale;
}

/// 遥控器焦点卡片：方向键落到它身上时放大 + 主题色描边 + 外发光。
///
/// 只做「看起来被选中」和「Enter / Space / D-pad OK 触发」两件事；
/// 焦点移动由 TV 外壳显式解析方向键后调用 `FocusNode.focusInDirection`
/// （Web 默认把方向键映射成滚动，不能依赖平台默认快捷键）。
class TvFocusCard extends StatefulWidget {
  const TvFocusCard({
    super.key,
    required this.child,
    this.onTap,
    this.radius = 16,
    this.focusScale = 1.06,
    this.autofocus = false,
    this.focusNode,
    this.semanticLabel,
    this.onFocused,
    this.onLongPress,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// 遥控器菜单键之外的另一条入口：按住 OK 不放（长按）也能打开操作抽屉。
  final VoidCallback? onLongPress;
  final double radius;
  final double focusScale;
  final bool autofocus;
  final FocusNode? focusNode;
  final String? semanticLabel;

  /// 拿到焦点时回调（顶部 tab 用它做「选中跟随焦点」）。
  final VoidCallback? onFocused;

  @override
  State<TvFocusCard> createState() => _TvFocusCardState();
}

class _TvFocusCardState extends State<TvFocusCard> {
  bool _focused = false;

  /// 用 `onFocusChange` 而不是 `onShowFocusHighlight`：
  /// 后者只在「传统高亮模式」下触发，网页/触屏模式一进来时高亮是关的，
  /// 键盘第一次按下前焦点卡片看起来像没选中。TV 上焦点必须始终可见。
  void _onFocusChange(bool value) {
    if (_focused != value) {
      setState(() => _focused = value);
      if (value) {
        // 焦点可能落在横向列表外，滚到视口中间才看得见「现在选中了谁」。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          Scrollable.ensureVisible(
            context,
            alignment: 0.5,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
          );
        });
      }
    }
    if (value) widget.onFocused?.call();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = widget.onTap != null;
    return FocusableActionDetector(
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      enabled: enabled,
      mouseCursor: enabled ? SystemMouseCursors.click : MouseCursor.defer,
      onFocusChange: _onFocusChange,
      actions: enabled
          ? <Type, Action<Intent>>{
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  widget.onTap?.call();
                  return null;
                },
              ),
            }
          : const <Type, Action<Intent>>{},
      child: Semantics(
        button: enabled,
        label: widget.semanticLabel,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          child: AnimatedScale(
            scale: _focused ? widget.focusScale : 1,
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                widget.child,
                if (_focused)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(widget.radius),
                          border: Border.all(color: scheme.primary, width: 3),
                          boxShadow: [
                            BoxShadow(
                              color: scheme.primary.withValues(alpha: 0.45),
                              blurRadius: 20,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 横滑分区的标题行（大字号 + 数量提示）。
class TvSectionHeader extends StatelessWidget {
  const TvSectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(m.px(8), 0, m.px(8), m.px(14)),
      child: Row(
        children: [
          Container(
            width: m.px(5),
            height: m.px(26),
            decoration: BoxDecoration(
              color: scheme.primary,
              borderRadius: BorderRadius.circular(m.px(3)),
            ),
          ),
          SizedBox(width: m.px(12)),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: m.px(24),
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// 横向滚动的一排卡片。用 `SingleChildScrollView + Row` 而不是 `ListView`：
/// 列表默认只构建可视区域，方向键走不到还没构建出来的卡片上。
class TvCardRow extends StatelessWidget {
  const TvCardRow({
    super.key,
    required this.title,
    required this.children,
    this.trailing,
  });

  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    if (children.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TvSectionHeader(title: title, trailing: trailing),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.symmetric(horizontal: m.px(8), vertical: m.px(6)),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var i = 0; i < children.length; i += 1) ...[
                if (i > 0) SizedBox(width: m.px(24)),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}
