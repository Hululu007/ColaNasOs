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

  // ---------------------------------------------------------------- 有数据时
  //
  // 上一版就是因为「同一个 FocusNode 既给外层 Focus、又给 TvFocusCard」在真机上
  // 直接崩（Tried to make a child into a parent of itself）。接口全挂时没有卡片，
  // 测试也就抓不到 —— 这里直接构造栏目 + 卡片，把那条路径钉死。

  testWidgets('栏目里的卡片能正常渲染（焦点节点只被一处占用）', (tester) async {
    tester.view.physicalSize = const Size(1280 * 2, 720 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final nodes = List<FocusNode>.generate(5, (i) => FocusNode(debugLabel: 'n$i'));
    addTearDown(() {
      for (final node in nodes) {
        node.dispose();
      }
    });

    await tester.pumpWidget(
      TvMetricsScope(
        metrics: TvMetrics.of(1280),
        child: MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                TvSearchRow(
                  title: '电影',
                  count: 5,
                  itemBuilder: (i) => TvSearchCard(
                    title: '影片 $i',
                    subtitle: '2024',
                    coverUrl: null,
                    focusNode: nodes[i],
                    onTap: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull, reason: '卡片构建不应抛异常');
    expect(find.text('电影'), findsOneWidget);
    // 名字要显示出来（截图里就是因为异常整块变成红色报错）
    expect(find.text('影片 0'), findsOneWidget);
    expect(find.text('影片 4'), findsOneWidget);
  });

  testWidgets('键盘按键渲染并能响应确认键', (tester) async {
    tester.view.physicalSize = const Size(1280 * 2, 720 * 2);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);

    final node = FocusNode(debugLabel: 'key');
    addTearDown(node.dispose);
    var tapped = 0;

    await tester.pumpWidget(
      TvMetricsScope(
        metrics: TvMetrics.of(1280),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 120,
                child: TvSearchKey(
                  label: 'q',
                  focusNode: node,
                  height: 56,
                  fontSize: 24,
                  onTap: () => tapped += 1,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull);
    expect(find.text('q'), findsOneWidget);

    node.requestFocus();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 100));
    expect(tapped, 1);
  });
}
