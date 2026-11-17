/// 播放停滞判定。
///
/// 为什么需要它：转码播放时「画面不动」有一堆互不相干的原因（分片还没转出来 /
/// 播放器拿了个 404 把整条 HLS 流废掉 / 解码器卡住 / 只是网慢），但它们对用户
/// 来说是同一件事 —— 卡住了，而且不会自己好。
///
/// 判据只能有一条：**水位**（历史最大播放位置）在多少秒内没涨过 [minAdvance]。
///
/// ⛔ 不能用「跟上一拍比 position 有没有变」：`player.seek()` 是**瞬时生效**的，
/// seek 一返回 position 立刻就是目标值。拿 seek 之前的旧值当基准，第一拍就会
/// 看见「一下跳了几万毫秒」→ 判「在播」→ 看门狗退场，之后卡多久都没人管。
/// 2026-11-17 线上会话 `795ee81b` 就是这么冻了 6 分钟、日志里一条告警都没有。
///
/// ⛔ 也不能用「buffer 有没有涨」当健康信号：卡住的那一刻播放器往往还在后台
/// 预取（那个会话一直拉到 150MB），数据在涨、画面不动正是要救的那种。
library;

/// 停滞级别：不动 / 一级补救（续转 + 重 seek）/ 二级补救（重建会话）。
enum PlayStallAction {
  /// 正常：位置在往前走，或者还在预热期
  none,

  /// 一级：让服务端续转 + 重新 seek 一次。便宜，绝大多数情况够了。
  nudge,

  /// 二级：原地救不回来，按当前位置重建会话。
  rebuild,
}

class PlayStallDetector {
  PlayStallDetector({
    this.limitSeconds = 8,
    this.minAdvance = const Duration(milliseconds: 700),
    this.warmupTicks = 2,
  }) {
    // 刚建出来也先做基线：调用方第一拍拿到的是「当前播放器位置」，
    // 不是「从 0 起涨了多少」，不让它直接算停滞。
    _warmup = warmupTicks;
  }

  /// 水位连续多少拍没涨算卡住（每拍 1 秒）。
  ///
  /// 8 秒意味着连 4 个 2 秒分片都没消化掉 —— 正常播放绝不会这样，
  /// 慢网也只是「走得很慢」（[minAdvance] 每秒 0.7 秒已经给出 30% 的宽限）。
  final int limitSeconds;

  /// 一拍（1 秒）里水位至少要走这么多才算「在播」。
  final Duration minAdvance;

  /// 开表 / seek 之后的预热拍数：这几拍只做基线，不判停滞。
  final int warmupTicks;

  Duration _mark = Duration.zero;
  int _warmup = 0;
  int _still = 0;
  int _stage = 0;

  /// 已经做到第几级补救（0 = 没动过）。
  int get stage => _stage;

  /// 重置：换了播放源 / 用户主动 seek / 暂停恢复之后都要来一次。
  void reset([Duration position = Duration.zero]) {
    _mark = position;
    _warmup = warmupTicks;
    _still = 0;
    _stage = 0;
  }

  /// 看过了一级补救（续转 + 重 seek）：把级别固定在一级，重新计时。
  ///
  /// 用于「转码还落在播放位置后面」——那种情况重建会话只会更慢，
  /// 应该继续等它追上来，而不是每 8 秒重开一次 ffmpeg。
  void noteStageOne(Duration position) {
    _stage = 1;
    _still = 0;
    _warmup = 1;
    _mark = position;
  }

  /// 走一拍（调用方保证每秒一次）。返回这一拍该做的补救。
  PlayStallAction tick(Duration position) {
    // 水位**每拍都推进**（1 秒滑动窗口）：这样「每拍只走 300ms」的爬行也会被
    // 判成卡住。如果只在达标的那些拍里推进，慢慢爬的位置攒够 700ms 就会被
    // 当成「在播」清一次计数，永远到不了阈值。
    final delta = position - _mark;
    _mark = position;
    if (delta >= minAdvance) {
      // 真的在往前走：级别清零（后面再卡还能再救一次）
      _still = 0;
      _stage = 0;
      return PlayStallAction.none;
    }
    if (_warmup > 0) {
      _warmup -= 1;
      return PlayStallAction.none;
    }
    _still += 1;
    if (_still < limitSeconds) return PlayStallAction.none;
    _still = 0;
    _stage += 1;
    return _stage <= 1 ? PlayStallAction.nudge : PlayStallAction.rebuild;
  }
}
