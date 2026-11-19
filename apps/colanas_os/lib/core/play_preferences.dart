import 'app_settings.dart';
import 'play_quality.dart';
import 'settings_store.dart';

enum AudioNormalizeMode { inherit, enabled, disabled }

/// 播放偏好的唯一落盘入口（改进 6.4）。
///
/// 画质 / 编码统一写在 `player.preset` / `player.codec` 两个键上，
/// Web、桌面、后续安卓 / TV 端读同一份；早期键名 `video.preset` / `video.codec`
/// 作为回退值读取，升级后首次保存即迁移到新键。
///
/// 响度归一支持跟随库级设置、强制开启和强制关闭；旧版 false 迁移为跟随库级设置。
class PlayPreferences {
  static const _presetKey = 'player.preset';
  static const _codecKey = 'player.codec';
  static const _normalizeKey = 'player.audioNormalize';
  static const _downmixKey = 'player.audioDownmix';
  static const _toneMapKey = 'player.toneMap';
  static const _leadKey = 'player.leadMinutes';
  static const _tvDirectKey = 'player.tvDirectOriginal';

  static String get preset {
    final saved =
        SettingsStore.instance.getString(_presetKey) ??
        SettingsStore.instance.getString('video.preset');
    final preset = playQualityPresetOf(saved ?? '');
    return preset == null || preset.copy
        ? defaultPresetForPlatform
        : preset.key;
  }

  static const defaultTvPlayPreset = '2160p_15m';

  static String get defaultPresetForPlatform =>
      defaultPresetFor(tvMode: AppSettings.instance.tvMode.value);

  static String defaultPresetFor({required bool tvMode}) =>
      tvMode ? defaultTvPlayPreset : defaultPlayPreset;

  /// 用户**显式保存过**的档位；没存过返回 null。
  ///
  /// 播放器要用它判断「是不是第一次用」：TV 端第一次进来默认原画（电视本来就
  /// 该放原片，转码是降级），PC / 手机默认 1080P，TV 转码档位默认 4K。
  /// 不能直接用 [preset] 判断 —— 它已经把默认值填进去了，分不出「没存过」。
  static String? get savedPreset {
    final saved =
        SettingsStore.instance.getString(_presetKey) ??
        SettingsStore.instance.getString('video.preset');
    final preset = playQualityPresetOf(saved ?? '');
    return preset == null || preset.copy ? null : preset.key;
  }

  static String get codec {
    final saved =
        SettingsStore.instance.getString(_codecKey) ??
        SettingsStore.instance.getString('video.codec');
    final savedPreset =
        SettingsStore.instance.getString(_presetKey) ??
        SettingsStore.instance.getString('video.preset');
    // Older versions represented original playback as a quality preset.
    if (playQualityPresetOf(savedPreset ?? '')?.copy == true) return 'original';
    final codec = playCodecOf(saved ?? '');
    if (codec?.selectable == true) return codec!.key;
    // H.264 remains an internal fallback, not a user preference.
    if (codec?.key == 'h264') return defaultPlayCodec;
    return defaultCodecForPlatform;
  }

  /// 没存过编码时 TV 优先原码，其它端默认 H.265。
  static String get defaultCodecForPlatform =>
      defaultCodecFor(tvMode: AppSettings.instance.tvMode.value);

  static String defaultCodecFor({required bool tvMode}) =>
      tvMode ? 'original' : defaultPlayCodec;

  static AudioNormalizeMode get audioNormalizeMode {
    final store = SettingsStore.instance;
    return audioNormalizeModeFrom(
      store.getString(_normalizeKey) ?? store.getBool(_normalizeKey),
      tvMode: AppSettings.instance.tvMode.value,
    );
  }

  static AudioNormalizeMode audioNormalizeModeFrom(
    Object? storedValue, {
    bool tvMode = false,
  }) {
    switch (storedValue) {
      case 'enabled':
        return AudioNormalizeMode.enabled;
      case 'disabled':
        return AudioNormalizeMode.disabled;
      case 'inherit':
        return AudioNormalizeMode.inherit;
    }
    // Previous bool=false meant "do not override the library setting".
    if (storedValue == true) return AudioNormalizeMode.enabled;
    if (storedValue == false) return AudioNormalizeMode.inherit;
    return tvMode ? AudioNormalizeMode.disabled : AudioNormalizeMode.inherit;
  }

  static bool? get audioNormalizeOverride => switch (audioNormalizeMode) {
    AudioNormalizeMode.inherit => null,
    AudioNormalizeMode.enabled => true,
    AudioNormalizeMode.disabled => false,
  };

  static bool audioNormalizeEnabled(bool? libraryValue) =>
      audioNormalizeOverride ?? (libraryValue == true);

  static bool get toneMap =>
      SettingsStore.instance.getBool(_toneMapKey) ?? false;

  static bool get audioDownmix =>
      SettingsStore.instance.getBool(_downmixKey) == true;

  /// 电视上 DV / HDR 片源直接走原片（不服务端色调映射）。默认开；
  /// 某些盒子的解码器会把 DV 显示成紫绿色，用户可以在播放设置里关掉回落。
  static bool get tvDirectOriginal =>
      SettingsStore.instance.getBool(_tvDirectKey) != false;

  static Future<void> saveTvDirectOriginal(bool value) =>
      SettingsStore.instance.setBool(_tvDirectKey, value);

  /// 所有端统一的默认提前转码时长（分钟）。
  /// 服务端 API 有同样的兜底值（`DEFAULT_LEAD_MINUTES`），保证 SDK / 直接调用
  /// 不传这个字段时也是同一个值。
  ///
  /// 2026-11-16：**取消「整片一次转完」**。整片模式下 ffmpeg 没有 `-t` 终点，
  /// 响度归一（dynaudnorm）会把音频扣住、视频先写出两片 → 浏览器播到 7 秒卡死；
  /// 而且整片动辄一两个小时，退出就白转。现在一律按段转，播到哪儿转到哪儿。
  static const int defaultLeadMinutes = 3;

  /// 提前转码时长（分钟）。**永远 > 0**：本地偏好存过 0（整片模式）的，这里
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
    final storedPreset =
        codec != 'original' && playQualityPresetOf(preset)?.copy == true
        ? defaultPresetForPlatform
        : preset;
    await SettingsStore.instance.setString(_presetKey, storedPreset);
    await SettingsStore.instance.setString(_codecKey, codec);
  }

  static Future<void> savePreset(String preset) =>
      SettingsStore.instance.setString(
        _presetKey,
        playQualityPresetOf(preset)?.copy == true
            ? defaultPresetForPlatform
            : preset,
      );

  static Future<void> saveCodec(String codec) async {
    final savedPreset =
        SettingsStore.instance.getString(_presetKey) ??
        SettingsStore.instance.getString('video.preset');
    if (codec != 'original' &&
        playQualityPresetOf(savedPreset ?? '')?.copy == true) {
      await SettingsStore.instance.setString(
        _presetKey,
        defaultPresetForPlatform,
      );
    }
    await SettingsStore.instance.setString(_codecKey, codec);
  }

  static Future<void> saveAudio({
    AudioNormalizeMode? normalizeMode,
    bool? downmix,
  }) async {
    if (normalizeMode != null) {
      await SettingsStore.instance.setString(_normalizeKey, normalizeMode.name);
    }
    if (downmix != null) {
      await SettingsStore.instance.setBool(_downmixKey, downmix);
    }
  }

  static Future<void> saveToneMap(bool enabled) =>
      SettingsStore.instance.setBool(_toneMapKey, enabled);
}
