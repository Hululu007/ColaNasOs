import 'dart:async';

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

/// 传输来源标记：后台搬运（同步 / 备份）在传输中心里不长驻。
///
/// 同步任务一次几千个文件，每个文件一个传输会话，会把「传输中」刷满；
/// 但这些会话在服务端仍要落库（进度、排错都靠它）。做法是发请求时带一个
/// `x-colanas-transfer-scope: background`，服务端据此分层，面板默认不列。
///
/// 用 Zone 而不是全局开关：上传是异步跑的，两路并发（同步 + 用户手点上传）
/// 时全局标记会互相污染 —— 用户自己的文件会被误标成后台任务。
class ColanasTransferScope {
  ColanasTransferScope._();

  static const String background = 'background';

  static const Object _key = #colanasTransferScope;

  /// 当前协程的标记，`null` 表示用户自己的传输
  static String? get current {
    final Object? v = Zone.current[_key];
    return v is String && v.isNotEmpty ? v : null;
  }

  /// 在「后台搬运」标记下执行一段异步逻辑
  static Future<T> runBackground<T>(Future<T> Function() body) {
    return runZoned(body, zoneValues: <Object, Object>{_key: background});
  }
}
