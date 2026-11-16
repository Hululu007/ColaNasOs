import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import '../../shell/app_visuals.dart';
import 'tv_focus.dart';

/// 尚未适配大屏的分区占位：仍然从契约拿到名称 / 图标，保证导航与端能力口径一致。
class TvPlaceholderSection extends StatelessWidget {
  const TvPlaceholderSection({super.key, required this.app});

  final AppDescriptor app;

  @override
  Widget build(BuildContext context) {
    final m = TvMetricsScope.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: m.px(120),
            height: m.px(120),
            decoration: BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.14),
              shape: BoxShape.circle,
            ),
            child: Icon(
              AppVisuals.iconFor(app.icon),
              size: m.px(56),
              color: scheme.primary,
            ),
          ),
          SizedBox(height: m.px(24)),
          Text(
            tr(app.nameKey),
            style: TextStyle(
              fontSize: m.px(34),
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          SizedBox(height: m.px(10)),
          Text(
            tr('tv.placeholder.title'),
            style: TextStyle(
              fontSize: m.px(22),
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          SizedBox(height: m.px(6)),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: m.px(720)),
            child: Text(
              tr('tv.placeholder.hint'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: m.px(16),
                height: 1.5,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
