/// 全局「省 GPU」开关。
///
/// 默认 `false`（保留毛玻璃）。开启后 [NasPanel] 不再创建 `BackdropFilter`，
/// 半透明面板直接叠在背景上 —— 视觉上仍然是同一套材质，只是省掉了每帧
/// 对背景做高斯模糊的 GPU 开销。
///
/// 为什么做成全局静态而不是每个组件传参：模糊强度来自风格规格（`panelBlur`），
/// 全站几十处面板都在用；逐个传参既改不干净，也容易漏。设置页改完由
/// `MaterialApp` 重建整棵树，这里赋值即可生效。
class NasEffects {
  NasEffects._();

  static bool reduceBlur = false;
}
