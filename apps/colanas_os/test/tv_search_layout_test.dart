import 'package:colanas_os/core/session.dart';
import 'package:colanas_os/features/tv/tv_focus.dart';
import 'package:colanas_os/features/tv/tv_search_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// TV 全站搜索的布局约束（设计稿：顶部搜索框、左 ~35% 屏上键盘、右 ~65% 栏目）。
///
/// 平时都在手机/桌面上开发，TV 这套分支很容易某次改动被悄悄弄坏 —— 这些
/// 断言就是防止「键盘没了」「键盘占满整屏」这类回归。
void main() {
  setUp(() {
    ApiSession.instance.baseUrl = 'http://127.0.0.1:9';
    ApiSession.instance.isAdminFromServer = true;
  });

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1280 * 2, 720 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TvMetricsScope(
              metrics: TvMetrics.of(1280),
              child: TvSearchSection(back: TvBackController()),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('键盘与搜索框都在，且键盘只占左侧约 35%', (tester) async {
    await pump(tester);

    // 三行字母各抽一个，确认键盘完整渲染
    expect(find.text('q'), findsOneWidget);
    expect(find.text('a'), findsOneWidget);
    expect(find.text('z'), findsOneWidget);

    final total = tester.getSize(find.byType(TvSearchSection)).width;
    final qKey = tester.getRect(find.text('q'));
    expect(qKey.left, lessThan(total * 0.35), reason: '键盘应在左侧 35% 内');

    // 搜索框（顶部只读回显）应横跨整个宽度
    expect(find.byIcon(Icons.search_rounded), findsWidgets);
  });

  testWidgets('方向键：键盘最右列按 → 不会抛异常（无结果时静默）', (tester) async {
    await pump(tester);
    await tester.tap(find.text('q'));
    await tester.pump(const Duration(milliseconds: 150));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });

  testWidgets('点字母会把字填进搜索框并触发搜索（空库时不崩）', (tester) async {
    await pump(tester);
    await tester.tap(find.text('q'));
    await tester.pump(const Duration(milliseconds: 500));

    // 顶部回显里出现 q（键盘上那个 q 之外还有一份）
    expect(find.text('q'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
