/// 播放进度条的几个时间口径。
///
/// 转码播放走的是 EVENT 播放列表，`<video>.duration` 只等于**已经转出来的那一段**，
/// 而且 hls.js 每次刷新播放列表还会让它短暂归零。如果拿它当总长，进度条就会在
/// 「已转出长度」和「整片长度」之间反复横跳（实测《匹诺曹》：1:40 ↔ 1:57:45）。
///
/// 所以几件事分开：
///   - **显示的总长**用片源时长（库里就有，恒定）；
///   - **已加载到哪儿**（进度条粗的那一段）用「播放器报的值 / 服务端回报的已转出长度」；
///   - **能不能直接 seek** 看目标是否落在已加载区间里，落在外面就另起一个从中途起转的会话。
///
/// 会话可以从片源中途起转（`startedMs` > 0），此时播放器时间轴 0 不等于片头，
/// 所以对外显示一律要加 [startedMs] 偏移。
library;

/// 进度条右端显示的总时长。
///
/// 片源时长优先；只有它拿不到（未知片源 / 时长为 0）时才用播放器报的值，
/// 两个都没有就给 0（界面显示 `--:--`）。
Duration timelineDuration({
  required Duration reported,
  required Duration source,
}) {
  if (source > Duration.zero) return source;
  return reported > Duration.zero ? reported : Duration.zero;
}

/// 能直接 seek 的上限（**不建新会话**的那种）。
///
/// - 直链播放：整片都能跳，等于 [timelineDuration]；
/// - 转码播放：只能跳到**已经转出来的位置**。超出的部分要另起一个从中途起转的
///   会话（见 [seekNeedsJump]），不然 hls.js 拿不到分片只会干转圈。
///   播放器还没报出有效值时（刚起播）退回整片长度，别把进度条锁死在 0。
Duration seekLimit({
  required Duration reported,
  required Duration source,
  required bool isTranscode,
}) {
  final full = timelineDuration(reported: reported, source: source);
  if (!isTranscode) return full;
  if (reported <= Duration.zero) return full;
  return reported < full ? reported : full;
}

/// 已加载（已转出）到的**片源绝对位置**（毫秒）。
///
/// 两个来源取大的那个：
///   - `serverMs`：会话详情回报的 `transcodedMs`（已经是绝对位置，含起转偏移）；
///   - `startMs + playerMs`：播放器报的 HLS 时长 —— 只在老会话（`leadMs = 0`，
///     2026-11-16 起不再新建）里服务端不给 `transcodedMs` 时才靠它。
int loadedEndMs({
  required int startMs,
  required int playerMs,
  required int serverMs,
}) {
  final byPlayer = startMs + (playerMs > 0 ? playerMs : 0);
  final byServer = serverMs > 0 ? serverMs : 0;
  return byServer > byPlayer ? byServer : byPlayer;
}

/// 快进 / 快退（键盘 →、←，遥控器，双击左右）的基准位置。
///
/// 不能一律拿「播放器位置 + 起转偏移」：新建跳转会话时 `startMs` 已经换成
/// 新起点，而播放器还停在**上一条流**上（首片要等好几秒），两者一加就是
/// 翻倍 —— 2026-11-17 实测：目标 338040 = 149020 + 189020，用户按 4 次 →、
/// 直接飞到 5 分半，然后一路卡死。
///
/// 只要「播放器手里的时间轴不属于当前操作」（正在跳转 / 新流还没 open /
/// 等待当前转码追上目标），基准就退回最近一次 seek 的目标。
int seekBaseMs({
  required int playerPosMs,
  required int startMs,
  required int lastTargetMs,
  required bool jumping,
  required bool streamPending,
}) {
  if (jumping || streamPending) return lastTargetMs;
  return startMs + (playerPosMs > 0 ? playerPosMs : 0);
}

/// 「等转码追上」该给多久（跳转目标超出已转出末尾时用）。
///
/// 同机实测转码约 **3.5 倍实时**（2 秒一片、约 0.6 秒出一片），所以追上 [gap]
/// 大约要 `gap / 3.5`，再留 2 秒余量。上下夹紧：太短会白重建会话（新会话首片
/// 要等好几秒），太长用户就是在看静止画面 —— 2026-11-17 反馈的「卡住」就是
/// 早期实现动辄等 14~20 秒造成的。
Duration clampWaitBudget(
  Duration gap, {
  Duration min = const Duration(seconds: 3),
  Duration max = const Duration(seconds: 10),
}) {
  final need = (gap.inMilliseconds / 3.5).round() + 2000;
  return Duration(
    milliseconds: need.clamp(min.inMilliseconds, max.inMilliseconds).toInt(),
  );
}

/// 目标位置是否需要「另起一个中途起转的会话」。
///
/// 需要的情况只有两种：
///   - 目标在会话起点之前（时间轴没有负数，往回跳只能重建）；
///   - 目标超出已加载区间（顺序转码还没转到这里）。
///
/// [toleranceMs] 给一点余量：拖到已加载末尾那一两像素不该反复重建会话。
bool seekNeedsJump({
  required Duration target,
  required Duration start,
  required Duration loadedEnd,
  int toleranceMs = 800,
}) {
  if (target < start) return true;
  return target.inMilliseconds >
      loadedEnd.inMilliseconds + (toleranceMs > 0 ? toleranceMs : 0);
}
