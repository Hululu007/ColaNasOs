import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:nas_ui/nas_ui.dart' show NasStyleContext;

import '../../../compat/getx.dart';
import '../../../list/models/cola_list_models.dart';
import '../../../shared/music_primitives.dart';
import '../../controller/cola_player_controller.dart';

typedef MusicStageCoverResolver = String Function(
  MusicListItem item, {
  int size,
});

/// 播放队列面板：窄屏弹底部抽屉，宽屏从右侧滑出。
class ColaMusicStageQueueSheet {
  const ColaMusicStageQueueSheet._();

  static Future<void> showBottomSheet({
    required BuildContext context,
    required MusicPlayServiceController controller,
    required MusicStageCoverResolver coverUrlResolver,
  }) async {
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final height = (media.size.height * 0.86).clamp(380.0, media.size.height);

    await showModalBottomSheet<void>(
      useSafeArea: true,
      isScrollControlled: true,
      context: context,
      backgroundColor: Color.alphaBlend(
        context.nasStyle.panelColor,
        context.nasStyle.baseColor,
      ),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SizedBox(
        height: height,
        child: _QueuePanel(
          controller: controller,
          coverUrlResolver: coverUrlResolver,
          theme: theme,
        ),
      ),
    );
  }

  static Future<void> show({
    required BuildContext context,
    required MusicPlayServiceController controller,
    required MusicStageCoverResolver coverUrlResolver,
  }) async {
    final theme = Theme.of(context);
    final panelWidth = _panelWidth(context);

    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.35),
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (_, anim, _, child) {
        final slide = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic));
        return SlideTransition(position: slide, child: child);
      },
      pageBuilder: (_, _, _) {
        final screen = MediaQuery.sizeOf(context);
        return SafeArea(
          // 固定在屏幕右侧、垂直居中、约占屏高 82%：面板位置不再跟随唤起按钮。
          // 之前按锚点位置裁可用区域（_surroundingInsets），从底部播放条唤起时
          // 可用高度只剩播放条那一小条，面板被压到右下角溢出屏幕、点开完全看不到。
          child: Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 24, 12, 24),
              child: SizedBox(
                height: math.max(
                  320.0,
                  math.min(screen.height * 0.82, screen.height - 48),
                ),
                child: Material(
                  color: Color.alphaBlend(
                    context.nasStyle.panelColor,
                    context.nasStyle.baseColor,
                  ),
                  borderRadius: const BorderRadius.all(Radius.circular(12)),
                  clipBehavior: Clip.antiAlias,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: panelWidth.max,
                      minWidth: panelWidth.min,
                    ),
                    child: _QueuePanel(
                      controller: controller,
                      coverUrlResolver: coverUrlResolver,
                      theme: theme,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  static ({double min, double max}) _panelWidth(BuildContext context) {
    // 宽度按屏幕算，不取唤起按钮的 RenderBox：从底部播放条的小按钮唤起时
    // 锚点只有播放条那么宽，算出来的 min/max 会被压到很窄，面板几乎看不见。
    final width = MediaQuery.sizeOf(context).width * 0.92;
    return (min: math.min(380.0, width), max: math.min(520.0, width));
  }
}

/// 面板内容：标题栏 + 队列列表，两种容器共用。
class _QueuePanel extends StatelessWidget {
  const _QueuePanel({
    required this.controller,
    required this.coverUrlResolver,
    required this.theme,
  });

  final MusicPlayServiceController controller;
  final MusicStageCoverResolver coverUrlResolver;
  final ThemeData theme;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        _titleBar(context),
        Expanded(
          child: Obx(() {
            final tracks = controller.playlist;
            final playingIndex = controller.currentIndex.value;
            return ListView.builder(
              itemCount: tracks.length,
              itemBuilder: (_, index) => _QueueTile(
                item: tracks[index],
                selected: index == playingIndex,
                coverUrl: coverUrlResolver(tracks[index], size: 120),
                onTap: () async {
                  await controller.playAt(index);
                  if (context.mounted) Navigator.of(context).pop();
                },
              ),
            );
          }),
        ),
      ],
    );
  }

  Widget _titleBar(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: <Widget>[
          const SizedBox(width: 16),
          Expanded(
            child: Text(
              'player_playlist'.tr,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    required this.item,
    required this.selected,
    required this.coverUrl,
    required this.onTap,
  });

  final MusicListItem item;
  final bool selected;
  final String coverUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      selected: selected,
      leading: SizedBox(
        width: 42,
        height: 42,
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(8)),
              child: MusicCoverImage(
                url: coverUrl,
                width: 42,
                height: 42,
                fit: BoxFit.cover,
              ),
            ),
            if (selected)
              Container(
                color: Colors.black.withValues(alpha: 0.35),
                child: const Icon(Icons.play_arrow, color: Colors.white),
              ),
          ],
        ),
      ),
      title: Text(
        item.displayTitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        item.artist.trim(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      onTap: onTap,
    );
  }
}
