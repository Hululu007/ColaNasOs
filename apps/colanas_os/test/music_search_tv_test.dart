import 'package:colanas_os/core/session.dart';
import 'package:colanas_os/features/music/music_search_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nas_ui/nas_ui.dart';

/// TV 搜索页的布局约束（设计稿：左 ~35% 屏上键盘 / 右 ~65% 栏目结果）。
///
/// 这些断言的意义：TV 布局是**另一套分支**，平时开发都在手机上跑，
/// 很容易某次改动把键盘分支整个弄没了却没人发现（手机上看不出问题）。
void main() {
  setUp(() {
    ApiSession.instance.baseUrl = 'http://127.0.0.1:9';
  });

  Future<void> pump(WidgetTester tester, {required bool tv}) async {
    tester.view.physicalSize = const Size(1280 * 2, 720 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      TvScope(
        enabled: tv,
        child: const MaterialApp(home: Scaffold(body: MusicSearchPage())),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('TV 模式渲染屏上键盘，非 TV 不渲染', (tester) async {
    await pump(tester, tv: false);
    expect(find.text('q'), findsNothing);

    await pump(tester, tv: true);
    // 三行字母都要在（z 在最后一行，能顺带验证没有被裁掉）
    expect(find.text('q'), findsOneWidget);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('z'), findsOneWidget);
  });

  testWidgets('键盘占左侧约 35%，搜索框横跨全宽', (tester) async {
    await pump(tester, tv: true);

    final width = tester.getSize(find.byType(MusicSearchPage)).width;
    // 键盘面板：从屏幕左边缘到分隔线之间的区域，用「z 键」所在的 Row 量
    final keyRect = tester.getRect(find.text('q'));
    expect(keyRect.left, lessThan(width * 0.35), reason: '键盘应在左侧 35% 内');

    final field = tester.getRect(find.byType(TextField));
    expect(field.width, greaterThan(width * 0.9), reason: '搜索框应横跨全宽');
  });

  testWidgets('方向键：键盘最右列按 → 进结果区（无结果时不崩）', (tester) async {
    await pump(tester, tv: true);
    // 先给键盘一个焦点（TV 上初始焦点在键盘）
    final q = find.text('q');
    await tester.tap(q);
    await tester.pump(const Duration(milliseconds: 200));

    // 最右列 → 没有结果卡片时应静默返回，而不是抛异常
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
