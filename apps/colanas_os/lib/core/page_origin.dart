/// 页面同源（`scheme://host[:port]`），**只在 Web 上有意义**。
///
/// 为什么不能直接写 `Uri.base.origin`：Dart 的 `Uri.origin` 只接受 http/https，
/// 原生端（Windows / macOS / 安卓 / TV）的 `Uri.base` 是 `file:`，取值直接抛
/// `StateError: Origin is only applicable to schemes http and https`。
/// 一旦这行写在 `build()` 里，release 包会退回 ErrorWidget —— 一整块纯灰色，
/// 用户看到的现象就是「这一页是空白的」（2026-11-22 用户反馈音乐设置整页空白）。
///
/// 返回空字符串表示「没有页面地址可用」，调用方应回落到配置里的服务端地址。
String pageOrigin() {
  final base = Uri.base;
  final http = base.scheme == 'http' || base.scheme == 'https';
  return http && base.host.isNotEmpty ? base.origin : '';
}
