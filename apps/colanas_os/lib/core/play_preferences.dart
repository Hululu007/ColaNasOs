import 'play_quality.dart';
import 'settings_store.dart';

/// 播放偏好的唯一落盘入口（改进 6.4）。
///
/// 画质 / 编码统一写在 `player.preset` / `player.codec` 两个键上，
/// Web、桌面、后续安卓 / TV 端读同一份；旧版 `video.preset` / `video.codec`
/// 作为回退值读取，升级后首次保存即迁移到新键。
///
/// 音频两项（`player.audioNormalize` / `player.audioDownmix`）是**客户端覆盖**：
/// 只有用户显式打开才随转码会话传下去；关闭 = 不传 = 跟随库级 `audio_normalize` 开关，
/// 所以默认值与加这两个开关之前的行为完全一致。
class PlayPreferences {
  static const _presetKey = 'player.preset';
  static const _codecKey = 'player.codec';
  static const _normalizeKey = 'player.audioNormalize';
  static const _downmixKey = 'player.audioDownmix';
  static const _leadKey = 'player.leadMinutes';

  static String get preset {
    final saved =
        SettingsStore.instance.getString(_presetKey) ??
        SettingsStore.instance.getString('video.preset');
    return playQualityPresetOf(saved ?? '')?.key ?? defaultPlayPreset;
  }

  /// 用户**显式保存过**的档位；没存过返回 null。
  ///
  /// 播放器要用它判断「是不是第一次用」：TV 端第一次进来默认原画（电视本来就
  /// 该放原片，转码是降级），桌面 / Web 仍然默认 [defaultPlayPreset]。
  /// 不能直接用 [preset] 判断 —— 它已经把默认值填进去了，分不出「没存过」。
  static String? get savedPreset {
    final saved =
        SettingsStore.instance.getString(_presetKey) ??
        SettingsStore.instance.getString('video.preset');
    return playQualityPresetOf(saved ?? '')?.key;
  }

  static String get codec {
    final saved =
        SettingsStore.instance.getString(_codecKey) ??
        SettingsStore.instance.getString('video.codec');
    return playCodecOf(saved ?? '')?.key ?? defaultPlayCodec;
  }

  static bool get audioNormalize =>
      SettingsStore.instance.getBool(_normalizeKey) == true;

  static bool get audioDownmix =>
      SettingsStore.instance.getBool(_downmixKey) == true;

  /// 所有端统一的默认提前转码时长（分钟）。
  /// 服务端 API 有同样的兜底值（`DEFAULT_LEAD_MINUTES`），保证 SDK / 直接调用
  /// 不传这个字段时也是同一个值。
  ///
  /// 2026-11-16：**取消「整片一次转完」**。整片模式下 ffmpeg 没有 `-t` 终点，
  /// 响度归一（dynaudnorm）会把音频扣住、视频先写出两片 → 浏览器播到 7 秒卡死；
  /// 而且整片动辄一两个小时，退出就白转。现在一律按段转，播到哪儿转到哪儿。
  static const int defaultLeadMinutes = 3;

  /// 提前转码时长（分钟）。**永远 > 0**：老版本存过 0（整片模式）的，这里
  /// 直接回落默认值，UI / 建会话都不会再产生整片会话。
  static int get leadMinutes {
    final v = int.tryParse(SettingsStore.instance.getString(_leadKey) ?? '');
    if (v == null || v <= 0) return defaultLeadMinutes;
    return v > 60 ? 60 : v;
  }

  static Future<void> saveLeadMinutes(int minutes) =>
      SettingsStore.instance.setString(
        _leadKey,
        '${minutes <= 0 ? defaultLeadMinutes : (minutes > 60 ? 60 : minutes)}',
      );

  static Future<void> save({
    required String preset,
    required String codec,
  }) async {
    await SettingsStore.instance.setString(_presetKey, preset);
    await SettingsStore.instance.setString(_codecKey, codec);
  }

  static Future<void> savePreset(String preset) =>
      SettingsStore.instance.setString(_presetKey, preset);

  static Future<void> saveCodec(String codec) =>
      SettingsStore.instance.setString(_codecKey, codec);

  static Future<void> saveAudio({bool? normalize, bool? downmix}) async {
    if (normalize != null) {
      await SettingsStore.instance.setBool(_normalizeKey, normalize);
    }
    if (downmix != null) {
      await SettingsStore.instance.setBool(_downmixKey, downmix);
    }
  }
}
