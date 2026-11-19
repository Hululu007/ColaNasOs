import 'client_id_stub.dart' if (dart.library.io) 'client_id_io.dart' as impl;

/// 客户端机器标识（随每个请求发 `x-colanas-client`）。
///
/// 用途：同步任务按「用户 + 机器」隔离 —— 同一个账号在两台电脑上各看各的任务，
/// 而同一台机器上的主客户端与独立同步客户端（`apps/sync_client`）共用同一个值，
/// 这样独立端看到的就是这台机器上的同步任务。
///
/// ColaNasOs PC 客户端启动时用同步文件能力提供的设备 ID 覆盖此值，使任务归属与
/// 请求隔离完全一致；其它直接使用 nas_core 的桌面调用以机器名作为兜底。
/// Web / Android / iOS 由应用层通过 [override] 提供稳定的本地客户端 ID。
class ColanasClientId {
  ColanasClientId._();

  static String? _override;

  /// 应用层覆盖（移动端 / Web 用本地持久化的随机 id）
  static set override(String? value) => _override = (value ?? '').trim();

  /// 当前请求要带的客户端标识；空串表示不带（服务端按历史同组处理）
  static String get value {
    final o = _override;
    if (o != null && o.isNotEmpty) return o;
    return impl.computeClientId();
  }
}
