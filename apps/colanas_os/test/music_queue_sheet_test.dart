import 'package:colanas_os/core/session.dart';
import 'package:colanas_os/features/music/shell/play_service/controller/cola_player_controller.dart';
import 'package:colanas_os/features/music/shell/play_service/play_ctrl_fullscreen/parts/cola_stage_playlist_drawer.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 播放队列面板的落位。
///
/// 曾经的 bug：面板从底部播放条唤起时，会按「唤起按钮周围还剩多少空间」去裁
/// 面板高度，播放条贴着窗口底边，可用高度只剩播放条那一小条，面板被压成一条
/// 塞在右下角，点开等于看不见。现在面板固定在屏幕右侧、垂直居中、约 82% 屏高。
/// 这里断言的就是「整块面板都在屏幕内」，位置再退回角落会立刻红。
void main() {
  setUp(() {
    ApiSession.instance.baseUrl = 'http://127.0.0.1:9';
  });

  testWidgets('从底部播放条唤起：面板整块落在屏幕内，靠右居中', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final controller = MusicPlayServiceController.instance;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              // 模拟贴在窗口底边的播放条按钮
              alignment: Alignment.bottomCenter,
              child: TextButton(
                onPressed: () => ColaMusicStageQueueSheet.show(
                  context: context,
                  controller: controller,
                  coverUrlResolver: (item, {size = 120}) => '',
                ),
                child: const Text('open-queue'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-queue'));
    await tester.pump(); // 弹出
    await tester.pump(const Duration(milliseconds: 300)); // 滑入动画

    final panel = tester.getRect(find.byType(ListView));
    expect(panel.left, greaterThanOrEqualTo(0), reason: '面板不能超出左边界');
    expect(panel.right, lessThanOrEqualTo(1280), reason: '面板不能超出右边界');
    expect(panel.top, greaterThanOrEqualTo(0), reason: '面板不能顶出屏幕');
    expect(panel.bottom, lessThanOrEqualTo(800), reason: '面板不能溢出屏幕底部');
    expect(panel.height, greaterThan(400), reason: '面板要有足够高度，不能被压成一条');
    expect(panel.center.dx, greaterThan(1280 / 2), reason: '面板应在屏幕右半边');
  });
}
