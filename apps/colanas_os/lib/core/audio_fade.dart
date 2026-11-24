import 'dart:async';

import 'package:media_kit/media_kit.dart';

/// 短淡入淡出：切换音源 / 起停时的「爆音」消除。
///
/// 现象（2026-11-24 用户反馈）：AI 播客正在播，点开音乐时切换瞬间有一声
/// 很明显的杂音，像打碟；反过来从暂停恢复也有轻微爆音。
///
/// 原因是音频输出在「一路停、另一路开」时被硬切：末尾样本停在非零位置，
/// 播放器又立刻重新配置输出。这里在停顿前把音量压到 0（约 160ms），
/// 起播时再从 0 拉回原音量，把切换点藏进淡入淡出里。
///
/// 只动音量，不碰播放状态机：暂停 / 播放仍由调用方原来的路径执行。
class AudioFader {
  AudioFader(this._player);

  final Player _player;

  /// 动作代号：新的淡入淡出会作废还在跑的旧斜坡，避免两段斜坡互相打架。
  int _generation = 0;

  /// 正常播放时的目标音量（media_kit 的 0~100）。
  double target = 100;

  /// 淡出到 0 再暂停，暂停后把音量复位（下次不经淡入的 play 也不会没声）。
  Future<void> fadeOutAndPause() async {
    final generation = ++_generation;
    final from = _player.state.volume;
    await _ramp(from, 0, generation);
    if (generation != _generation) return;
    await _player.pause();
    await _setVolumeSafe(target);
  }

  /// 从当前状态起播：先把音量压到 0，播起来之后再拉回目标音量。
  Future<void> fadeInAndPlay() async {
    final generation = ++_generation;
    await _setVolumeSafe(0);
    if (generation != _generation) return;
    await _player.play();
    unawaited(_ramp(0, target, generation));
  }

  /// `open(play: true)` 之前先把音量压到 0（避免首帧就以满音量出声）。
  Future<void> silence() async {
    _generation++;
    await _setVolumeSafe(0);
  }

  /// 承接 [silence]：打开完成后把音量淡回来。
  void fadeInFromSilence() {
    final generation = ++_generation;
    unawaited(_ramp(0, target, generation));
  }

  Future<void> _ramp(double from, double to, int generation) async {
    const steps = 8;
    for (var i = 1; i <= steps; i++) {
      if (generation != _generation) return;
      final value = from + (to - from) * i / steps;
      if (!await _setVolumeSafe(value)) return;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// 播放器可能已经被 dispose（切模块 / 热重载），音量调用失败不能抛给上层。
  Future<bool> _setVolumeSafe(double value) async {
    try {
      await _player.setVolume(value.clamp(0, 100).toDouble());
      return true;
    } catch (_) {
      return false;
    }
  }
}
