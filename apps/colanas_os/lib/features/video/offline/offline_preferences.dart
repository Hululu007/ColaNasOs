import '../../../core/settings_store.dart';

/// 下载策略（只影响本机）：仅 WiFi、限速、多连接加速。
///
/// 存在 `SettingsStore` 里而不是本地库索引里：这些是**用户偏好**，
/// 跟「下了哪些片子」无关；换下载目录也不该把它们弄丢。
class OfflinePreferences {
  OfflinePreferences._();

  static const String wifiOnlyKey = 'video.offline.wifiOnly';
  static const String maxKbpsKey = 'video.offline.maxKbps';
  static const String connectionsKey = 'video.offline.connections';

  /// 默认**开**：手机流量下悄悄下掉几百兆是最不能接受的意外。
  /// 没存过值就按开处理，用户显式关掉才走流量。
  static bool get wifiOnly => SettingsStore.instance.getBool(wifiOnlyKey) ?? true;

  /// 下载限速（kbps，0 = 不限速）
  static int get maxKbps => SettingsStore.instance.getInt(maxKbpsKey) ?? 0;

  /// 分片下载的连接数（1 = 单连接）。
  ///
  /// 默认 4：单连接在 WiFi 中继 / 反向代理 / 单流限速这类链路上跑不满带宽，
  /// 而生成本来就是静态文件 + 支持 Range，多连接是白拿的提速。
  static int get connections {
    final v = SettingsStore.instance.getInt(connectionsKey) ?? 4;
    return v.clamp(1, 8);
  }

  static Future<void> setWifiOnly(bool value) =>
      SettingsStore.instance.setBool(wifiOnlyKey, value);

  static Future<void> setMaxKbps(int value) =>
      SettingsStore.instance.setInt(maxKbpsKey, value);

  static Future<void> setConnections(int value) =>
      SettingsStore.instance.setInt(connectionsKey, value.clamp(1, 8));
}
