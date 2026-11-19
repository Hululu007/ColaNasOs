import 'dart:io';

/// 未由应用层覆盖时，以桌面主机名作客户端标识兜底。
///
/// 机器名是 localhost / 空串（部分容器、个别移动端）时返回空串，
/// 交给应用层的持久化随机 id 兜底。
String computeClientId() {
  if (!(Platform.isWindows || Platform.isMacOS || Platform.isLinux)) return '';
  final host = Platform.localHostname.trim().toLowerCase();
  if (host.isEmpty || host == 'localhost' || host == '127.0.0.1') return '';
  return 'pc:$host';
}
