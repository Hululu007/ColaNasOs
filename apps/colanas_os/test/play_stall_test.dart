import 'package:flutter_test/flutter_test.dart';
import 'package:colanas_os/core/play_stall.dart';

/// 播放停滞判定。
///
/// 这段逻辑来自一次真实的「跳 30 秒卡死 6 分钟」事故（2026-11-17，会话
/// `795ee81b`）：旧看门狗拿「seek 之前的位置」当基准，而 `seek()` 是瞬时生效的，
/// 第一拍就看见位置跳了几万毫秒 → 判「在播」→ 退场，之后再也没人管。
/// 下面第一条用例就是把那个场景钉死，防止有人把判据改回「跟上一拍比」。
void main() {
  Duration ms(int v) => Duration(milliseconds: v);

  group('classifyDirectPlaybackIssue', () {
    test('only marks buffered video with no frame after initialization grace', () {
      expect(
        classifyDirectPlaybackIssue(
          width: 1920,
          videoFrameReady: false,
          buffered: const Duration(seconds: 2),
          advanced: const Duration(seconds: 1),
          sample: 5,
          isWeb: false,
        ),
        isNull,
      );
      expect(
        classifyDirectPlaybackIssue(
          width: 1920,
          videoFrameReady: false,
          buffered: const Duration(seconds: 2),
          advanced: const Duration(seconds: 1),
          sample: 6,
          isWeb: false,
        ),
        DirectPlaybackIssue.noVideoFrame,
      );
      expect(
        classifyDirectPlaybackIssue(
          width: 0,
          videoFrameReady: false,
          buffered: Duration.zero,
          advanced: Duration.zero,
          sample: 9,
          isWeb: false,
        ),
        isNull,
        reason:
            'lack of buffered data must not be classified as a decoder failure',
      );
    });

    test('distinguishes decoder stalls from network starvation', () {
      expect(
        classifyDirectPlaybackIssue(
          width: 1920,
          videoFrameReady: true,
          buffered: const Duration(seconds: 2),
          advanced: Duration.zero,
          sample: 2,
          isWeb: false,
        ),
        DirectPlaybackIssue.decodeStalled,
      );
      expect(
        classifyDirectPlaybackIssue(
          width: 1920,
          videoFrameReady: true,
          buffered: const Duration(milliseconds: 500),
          advanced: Duration.zero,
          sample: 4,
          isWeb: false,
        ),
        DirectPlaybackIssue.noData,
      );
      expect(
        classifyDirectPlaybackIssue(
          width: 1920,
          videoFrameReady: true,
          buffered: const Duration(milliseconds: 500),
          advanced: Duration.zero,
          sample: 4,
          isWeb: true,
        ),
        isNull,
      );
    });
  });

  /// 一直喂同一个位置，返回「第几拍才动手」和「动手做的是什么」。
  ({int at, PlayStallAction action}) firstAction(
    PlayStallDetector d,
    Duration frozen, {
    int maxTicks = 40,
  }) {
    for (var i = 1; i <= maxTicks; i += 1) {
      final a = d.tick(frozen);
      if (a != PlayStallAction.none) return (at: i, action: a);
    }
    return (at: -1, action: PlayStallAction.none);
  }

  group('PlayStallDetector：只在「画面真的不动」时才动手', () {
    test('seek 回显不算停滞（回显阶段就该退场）', () {
      final d = PlayStallDetector();
      // 原位 0 → 用户跳到 30 秒，position 立刻报成 30000
      expect(
        d.tick(ms(30000)) == PlayStallAction.none,
        isTrue,
        reason: '跳过去的第一拍必须放过',
      );
      // 2 拍预热 + 8 拍判定 = 10 拍内必然发现「跳过去之后不动」
      final r = firstAction(d, ms(30000));
      expect(r.at, 10);
      expect(r.action, PlayStallAction.nudge);
    });

    test('位置在走就一直不报（含 0.8 倍速的慢网）', () {
      final d = PlayStallDetector();
      for (var i = 1; i <= 600; i += 1) {
        // 每拍走 800ms：慢，但在播
        expect(d.tick(ms(i * 800)), PlayStallAction.none, reason: '第 $i 拍');
      }
      expect(d.stage, 0);
    });

    test('爬行（每拍 300ms）也算卡住：一级 → 二级', () {
      final d = PlayStallDetector();
      var nudgeAt = -1;
      var rebuildAt = -1;
      for (var i = 1; i <= 40; i += 1) {
        final a = d.tick(ms(i * 300));
        if (a == PlayStallAction.nudge && nudgeAt < 0) nudgeAt = i;
        if (a == PlayStallAction.rebuild && rebuildAt < 0) rebuildAt = i;
      }
      expect(nudgeAt, 10);
      expect(rebuildAt, 18);
    });

    test('中间恢复过就重新计数，不会把两段卡顿累加成二级', () {
      final d = PlayStallDetector();
      expect(firstAction(d, Duration.zero).action, PlayStallAction.nudge);
      expect(d.stage, 1);
      // 服务端追上来了，画面重新走起来
      expect(d.tick(ms(2000)), PlayStallAction.none);
      expect(d.stage, 0, reason: '恢复后级别清零，后面再卡还能再救一次');
    });

    test('noteStageOne：转码还在后面时退回一级，不升级成重建', () {
      final d = PlayStallDetector();
      expect(firstAction(d, Duration.zero).action, PlayStallAction.nudge);
      expect(d.stage, 1);
      // 再卡 8 拍：本该给 rebuild，但调用方判定「转码还没追上」→ 退回一级
      expect(firstAction(d, Duration.zero).action, PlayStallAction.rebuild);
      d.noteStageOne(Duration.zero);
      expect(d.stage, 1);
      expect(
        firstAction(d, Duration.zero).action,
        PlayStallAction.rebuild,
        reason: '重新计时之后还会再救一次，不会立刻触发',
      );
    });
  });
}
