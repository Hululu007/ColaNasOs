import '../../../core/settings_store.dart';

/// 下载策略（只影响本机）：仅 WiFi、限速。
///
/// 存在 `SettingsStore` 里而不是本地库索引里：这两个是**用户偏好**，
/// 跟「下了哪些片子」无关；换下载目录也不该把它们弄丢。
class OfflinePreferences {
  OfflinePreferences._();

  static const String wifiOnlyKey = 'video.offline.wifiOnly';
  static const String maxKbpsKey = 'video.offline.maxKbps';

  /// 移动网络下不开始下载（默认关：内网 NAS 大多在 WiFi，但不是所有人都这样）
  static bool get wifiOnly => SettingsStore.instance.getBool(wifiOnlyKey) ?? false;

  /// 下载限速（kbps，0 = 不限速）
  static int get maxKbps => SettingsStore.instance.getInt(maxKbpsKey) ?? 0;

  static Future<void> setWifiOnly(bool value) =>
      SettingsStore.instance.setBool(wifiOnlyKey, value);

  static Future<void> setMaxKbps(int value) =>
      SettingsStore.instance.setInt(maxKbpsKey, value);
}
