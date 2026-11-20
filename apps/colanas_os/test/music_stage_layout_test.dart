import 'package:colanas_os/core/session.dart';
import 'package:colanas_os/features/music/shell/compat/host.dart';
import 'package:colanas_os/features/music/shell/play_service/play_ctrl_fullscreen/parts/cola_stage_body.dart';
import 'package:colanas_os/features/music/shell/play_service/play_ctrl_fullscreen/parts/cola_stage_disc_block.dart';
import 'package:colanas_os/features/music/shell/play_service/play_ctrl_fullscreen/parts/cola_stage_lyric_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 歌词舞台的布局分档。
///
/// 这两条断言守的是一个很容易回归的点：宽屏（PC / 平板横屏）必须**同屏**
/// 左唱片右歌词，不能退化成「两个页面来回切」。之前的分档用的是
/// `DeviceUtils.isMobile`，而它在 Web 端恒为 true（判定里带了 `!kIsWeb`），
/// 于是 PC 浏览器永远走窄屏分页。改成按可用宽度分档后，用测试把这条钉住。
void main() {
  setUp(() {
    ApiSession.instance.baseUrl = 'http://127.0.0.1:9';
    // 窄屏分页的选择记在本地缓存里，单例会在用例间残留，先复位。
    CacheManager().setBool(CacheKeys.musicFullScreenShowLyrics, false);
  });

  Future<void> pumpStage(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColaMusicStageBody(
            isPlaying: false,
            coverUrl: '',
            discAsset: 'assets/music/icons/player_disc1.png',
            musicPath: '/music/demo.flac',
            trackDuration: const Duration(minutes: 4),
            onToggleFavorite: null,
            favoriteLoading: false,
            isFavorite: false,
            onNextDiscStyle: () {},
            onShowProperties: () {},
            onShowPlaylist: () {},
            title: 'Demo',
            album: 'Album',
            artist: 'Artist',
            lyrics: '',
            position: Duration.zero,
            onSeekTo: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('宽屏（≥900）：唱片与歌词同屏，左唱片右歌词', (tester) async {
    await pumpStage(tester, const Size(1280, 800));

    expect(find.byType(ColaMusicStageDisc), findsOneWidget);
    expect(find.byType(ColaMusicStageLyrics), findsOneWidget,
        reason: '宽屏下歌词应与唱片同屏，不再分页');

    final discX = tester.getCenter(find.byType(ColaMusicStageDisc)).dx;
    final lyricX = tester.getCenter(find.byType(ColaMusicStageLyrics)).dx;
    expect(discX, lessThan(lyricX), reason: '唱片在左、歌词在右');

    // 分页布局独有的切换动画容器不该出现
    expect(find.byType(AnimatedSwitcher), findsNothing);
  });

  testWidgets('窄屏（<900）：仍是一页一页切，先唱片后歌词', (tester) async {
    await pumpStage(tester, const Size(390, 844));

    expect(find.byType(ColaMusicStageDisc), findsOneWidget);
    expect(find.byType(ColaMusicStageLyrics), findsNothing,
        reason: '窄屏默认先显示唱片');

    // 点唱片切到歌词页
    await tester.tap(find.byType(ColaMusicStageDisc));
    await tester.pump(); // 触发切换
    await tester.pump(const Duration(milliseconds: 300)); // 走完 180ms 过渡
    await tester.pump(const Duration(milliseconds: 300)); // 旧页退场

    expect(find.byType(ColaMusicStageLyrics), findsOneWidget);
    expect(find.byType(ColaMusicStageDisc), findsNothing);
  });
}
