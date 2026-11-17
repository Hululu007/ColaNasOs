import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:nas_core/nas_core.dart';
import 'package:nas_ui/nas_ui.dart';

import 'offline_badge.dart';

/// Web / 不支持文件系统的端：能力一律为 false，界面给出明确提示。
const bool supported = false;

final ValueNotifier<int> _revision = ValueNotifier<int>(0);

ValueListenable<int> get revision => _revision;

OfflineBadgeState stateOf(String itemId) => OfflineBadgeState.unsupported;

Future<void> openDialog(
  BuildContext context,
  VideoItem item, {
  String? libraryName,
  String? seriesTitle,
  int? totalEpisodes,
}) async {
  ScaffoldMessenger.maybeOf(
    context,
  )?.showSnackBar(SnackBar(content: Text(tr('video.offline.unsupported'))));
}

void ensureLoaded() {}

Future<void> cancel(String itemId) async {}

Widget buildPage() => const _UnsupportedPage();

class _UnsupportedPage extends StatelessWidget {
  const _UnsupportedPage();

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(NasTokens.spaceLg),
      child: Text(
        tr('video.offline.unsupported'),
        textAlign: TextAlign.center,
        style: TextStyle(color: context.nasTextSecondary),
      ),
    ),
  );
}
