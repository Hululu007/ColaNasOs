import 'package:nas_core/nas_core.dart';

import 'settings_store.dart';

/// 字幕语言偏好（SP3-03 二期）：
///
/// `off` = 关闭字幕，`auto` = 用第一个可用字幕，其余是语言标签（`zh` / `zh-CN` / `en`）。
/// 选择记在本地设置里，下次打开任意影片自动套用。
class VideoSubtitlePrefs {
  VideoSubtitlePrefs._();

  static final VideoSubtitlePrefs instance = VideoSubtitlePrefs._();

  static const String key = 'video.subtitleLang';
  static const String auto = 'auto';
  static const String off = 'off';

  /// 字号倍数（TV 面板可调，0.8x ~ 2.0x）。默认 1.0 = 与旧版完全一致。
  static const String scaleKey = 'player.subtitleScale';

  /// 字幕垂直位置：0 = 底部，1 = 居中偏下，2 = 偏上。
  static const String positionKey = 'player.subtitlePos';

  String get preferred => SettingsStore.instance.getString(key) ?? auto;

  Future<void> set(String value) =>
      SettingsStore.instance.setString(key, value);

  /// 字号倍数：没存过 / 非法 → 1.0；越界夹到 0.8~2.0。
  double get scale {
    final raw = double.tryParse(
      SettingsStore.instance.getString(scaleKey) ?? '',
    );
    if (raw == null || raw.isNaN || raw <= 0) return 1.0;
    return raw.clamp(0.8, 2.0).toDouble();
  }

  Future<void> setScale(double value) =>
      SettingsStore.instance.setString(scaleKey, '${value.clamp(0.8, 2.0)}');

  /// 位置档位：0 底部 / 1 居中偏下 / 2 偏上；越界回落 0。
  int get position {
    final raw = int.tryParse(
      SettingsStore.instance.getString(positionKey) ?? '',
    );
    if (raw == null || raw < 0 || raw > 2) return 0;
    return raw;
  }

  Future<void> setPosition(int value) =>
      SettingsStore.instance.setString(positionKey, '${value.clamp(0, 2)}');
}

/// 按偏好挑字幕（纯函数，便于单测）：
///
/// - `off` → null；
/// - `auto` → 第一条；
/// - 语言标签按前缀匹配（`zh` 命中 `zh-CN`），都匹配不上时回退第一条；
/// - 空列表 → null。
VideoSubtitleFile? pickSubtitle(
  List<VideoSubtitleFile> items,
  String preferred,
) {
  if (items.isEmpty) return null;
  if (preferred == VideoSubtitlePrefs.off) return null;
  if (preferred == VideoSubtitlePrefs.auto) return items.first;

  final want = preferred.toLowerCase();
  for (final item in items) {
    final lang = (item.lang ?? '').toLowerCase();
    if (lang.isEmpty) continue;
    if (lang == want || lang.startsWith('$want-') || lang.startsWith(want)) {
      return item;
    }
  }
  return items.first;
}

/// 按播放位置取当前应显示的字幕文本（纯函数，便于单测）。
///
/// 服务端 `/video/subtitle` 已经把 srt/ass/vtt 解析成结构化 `cues`，播放器
/// 直接按位置自绘，不再走 media_kit 的 `SubtitleTrack.data`：Web 内核挂的是
/// blob `<track>`，`open()` 会用 `element.innerHTML = ''` 把它清掉，切换字幕时
/// 又固定读 `textTracks[0]`。多条 cue 重叠时按文件顺序换行合并；ASS 的
/// Dialogue 未必按时间排序，所以线性扫而不假设有序。
String activeSubtitleText(List<VideoSubtitleCue> cues, int positionMs) {
  if (cues.isEmpty) return '';
  final lines = <String>[];
  for (final cue in cues) {
    if (cue.startMs <= positionMs && cue.endMs > positionMs) {
      final text = cue.text.trim();
      if (text.isNotEmpty) lines.add(text);
    }
  }
  return lines.join('\n');
}
