/// 下载按钮的几种状态（详情页动作条要用，不能依赖 dart:io）。
enum OfflineBadgeState {
  /// 当前端不支持离线下载（Web / TV）
  unsupported,

  /// 没下过，也没有进行中的任务
  none,

  /// 排队 / 等编码
  preparing,

  /// 正在下载
  downloading,

  /// 已下载（可进本地视频页管理）
  downloaded,

  /// 上次失败，可重试
  failed,
}
