# 手机端杜比视界播放：渲染通道设计与实施计划

- 日期：2026-11-22
- 适用端：Android 手机 / 平板（TV 已可用，不在本次范围，但共用同一套底层）
- 版本基线：1.3.22（预览通道）

## 1. 现象

杜比视界（Profile 5）片源在安卓手机上播放异常，按渲染通道不同表现不同：

| 渲染通道 | 画面 | 声音 | 说明 |
| --- | --- | --- | --- |
| libmpv（MediaCodec 硬解 + gpu vo） | 紫 / 荧光绿 | 正常 | libmpv 不解析 DV RPU，IPTPQc2 被当普通 YUV |
| Media3 + PlatformView（Hybrid Composition，SurfaceView） | 纯黑 | 正常 | 原生 PlayerView 的 layout 恒为 0×0 |
| Media3 + AndroidView（纹理合成，TextureView） | 画面正常但颜色错（紫） | 正常（合并音频后） | 纹理只承载 SDR 像素，HDR 元数据丢失 |

## 2. 实测数据（决定设计的前提）

真机日志（小米系，`c2.qti.dv.decoder` 可用，`displayHdr=dolbyVision`）：

```
视频容器约束 365x800                                  ← Flutter 侧约束正常
Media3 首帧/解码器就绪 decoder=c2.qti.dv.decoder size=0x0 view=0x0 surface=0x0
```

- **解码器能初始化并且能被选中**（`c2.qti.dv.decoder`），说明硬件 DV 解码可用；
- **原生视图尺寸恒为 0**（`view=0x0`），`Positioned.fill` 包裹后依然为 0；
- 换成 `AndroidView`（纹理合成）后画面立即出现 —— 说明 View 树本身正常，问题只在「真实 Surface（expensive HC）」这条路径；
- 纹理通道下颜色错，符合「纹理只保留 SDR 像素」的预期。

结论：**解码与音频链路已经打通，缺口只有一处 —— 把解码结果以 HDR 直出到屏幕的容器建不起来。**

## 3. 音频链路（已完成，不在本次改动范围）

- 手机普遍没有 E-AC3 / DTS-HD 解码器，原片音轨选不上时不再中断播放；
- 服务端建一条「视频原样 copy + 音频 AAC」的会话（实测 6 分钟内容 3.6 秒转完）；
- 客户端用 `MergingMediaSource(原片视频源, HLS 音频源)` 合并播放：
  - 视频源：原片直链（`dvcC` 配置完整）
  - 音频源：服务端 AAC（`MimeTypes.APPLICATION_M3U8`）
- 状态经 `audioUnsupported` 字段由原生回传，Dart 侧据此触发合并（`_startAudioMerge`）。

## 4. 方案对比

| 方案 | HDR/DV | 起播 | 服务端开销 | 实现成本 | 风险 |
| --- | --- | --- | --- | --- | --- |
| **A. 原生 SurfaceView 覆盖层** | 真 DV 直通 | 秒开 | 零 | 高（改 Activity 结构） | 层序与透明背景易碎 |
| **B. 纹理 + 端上 tone map 到 SDR** | SDR（颜色正确） | 秒开 | 零 | 中 | 依赖 Media3 的 GL 处理能力，需实测 |
| **C. 纹理 + 服务端 tone map** | SDR（颜色正确） | 慢（4K 无硬件滤镜，CPU 重编码） | 高 | 低 | 已验证可用，仅性能代价 |

推荐顺序：**B → A → C**。先验证 B（成本低、失败也能快速回退到 C），B 不可行再上 A。

## 5. 方案 B：端上 tone map（已判定为不可行）

### 5.1 结论先行

Media3 版本为 **1.10.0**，纹理输出时对 HDR10 / HDR10+ 有内置的 HDR→SDR 处理。但**杜比视界 Profile 5 不在这条能力范围内**：

- DV 的色彩空间是 IPTPQc2，不是标准 PQ；Media3 的 tone mapper 按 `colorInfo` 里的 PQ/HLG 分支处理，遇到 DV 只会当成「未知色彩」直通；
- 实测结果印证了这一点：同一套纹理通道下，HDR10+ 片（Avatar）与 DV 片（功夫女足）表现不同 —— DV 片稳定偏紫，说明不是「统一的 HDR 丢失」，而是 DV 特有的色彩未被还原。

所以方案 B 只能解决 HDR10，解决不了杜比。**直接进方案 A。**

## 6. 方案 A：原生 SurfaceView 覆盖层（真杜比）

### 6.1 目标

视频画面由原生 `SurfaceView` 直出（保留 HDR / 杜比视界元数据，系统解码器直通），Flutter 只负责控件层。

### 6.2 层序（从下到上）

```
┌─────────────────────────────────────────┐
│  窗口 UI 层（View 树）                    │
│   ├─ Flutter 控件层（TextureView 渲染）   │  ← 播放控件、字幕、提示
│   └─ 透明占位（视频区域留空）              │
├─────────────────────────────────────────┤
│  media overlay 层                        │
│   └─ 原生 SurfaceView（HDR 直出）          │  ← setZOrderMediaOverlay(true)
├─────────────────────────────────────────┤
│  media 层（默认 SurfaceView 位置）         │
└─────────────────────────────────────────┘
```

### 6.3 关键前提：Flutter 必须用 TextureView 渲染

Flutter 默认用 `FlutterSurfaceView`，自身内容也落在 media 层。这会导致两种冲突：

- 原生 SurfaceView 用 `setZOrderMediaOverlay(true)` → 在 media 层之上 → 遮挡 Flutter 控件；
- 原生 SurfaceView 用默认层 → 被 Flutter 的 Surface 遮挡 → 看不到视频。

唯一正解：**Flutter 走 `FlutterFragment.RenderMode.texture`**，内容进 View 树（UI 层），原生 SurfaceView 放 media overlay 层，两层互不遮挡。

```kotlin
// MainActivity 由 FlutterActivity 改为 FragmentActivity + FlutterFragment
val fragment = FlutterFragment.withNewEngine()
    .renderMode(FlutterFragment.RenderMode.texture)   // ← 内容进 View 层
    .build()
supportFragmentManager.beginTransaction().add(R.id.host, fragment).commit()
```

代价：现有 `configureFlutterEngine` 里的全部 MethodChannel 注册（backup / download / update / display / tv_media3）需要迁移到自定义 `FlutterEngine` 的 `PluginRegistry` 或 `FlutterFragment` 的 engine 回调。

### 6.4 实现要点

1. **原生播放视图**：`TvMedia3Session` 的 `PlayerView` 不挂在 PlatformView 里，改为挂到 Activity 的 `FrameLayout`：
   ```kotlin
   val host = findViewById<FrameLayout>(android.R.id.content)
   host.addView(playerView, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
   (playerView.videoSurfaceView as? SurfaceView)?.setZOrderMediaOverlay(true)
   ```
2. **Flutter 侧**：视频区域用透明占位（`SizedBox.expand()`），控件层保持半透明黑。
3. **通道接口**（`com.colanas.os/surface_host`）：
   | 方法 | 作用 |
   | --- | --- |
   | `attach` | 创建/显示原生播放视图并置顶到 media overlay 层 |
   | `detach` | 移除原生视图，恢复 Flutter 独占 |
   | `setBounds(x,y,w,h)` | 非全屏时限定视频区域（全屏时整屏） |
4. **事件**：复用现有 `TvMedia3PlayerController` 的 EventChannel，只是视图挂载方式改变。
5. **生命周期**：`onPause` / 路由退出 / 转屏 必须 `detach`，否则原生视图会残留在其他页面。

### 6.5 风险

- `RenderMode.texture` 性能略低于 `surface`（多一次合成），需实测 4K 是否掉帧；
- 改造 Activity 结构影响全 App，任何 Channel 注册遗漏都会导致对应功能失效（备份、下载、更新、显示、播放器）；
- 透明背景下，Flutter 侧任何不透明背景色都会遮住视频，需逐个页面排查；
- 系统返回手势、状态栏颜色、沉浸模式需要重新对齐。

## 7. 方案 C：服务端 tone map（保底）

播放设置里开「HDR 色调映射」→ 服务端 GPU 管线 `apply_dovi` 把 DV 转 SDR/HDR10。

- 已验证可用：颜色正确、有声音
- 代价：4K 走 CPU 重编码（`缺硬件滤镜=无`），一小时片子耗时以十分钟计
- 定位：B、A 都不可行时的兜底，或者用户对画质要求不高时的快速通道

## 8. 实施计划

| 阶段 | 内容 | 产出 | 预估 |
| --- | --- | --- | --- |
| P1 | `MainActivity` 改为 `FragmentActivity + FlutterFragment(RenderMode.texture)`，迁移全部 MethodChannel 注册 | 全 App 可正常启动、原有功能不丢 | 1.5 h |
| P2 | 原生播放视图挂到 media overlay 层（`attach` / `detach` / `setBounds`） | 视频直出，控件不被遮挡 | 1 h |
| P3 | Dart 侧：视频区域透明占位、生命周期挂载/卸载、转屏与全屏对齐 | APK | 1 h |
| P4 | 回归：TV 端、SDR 片、音频合并、直连探测 6 秒问题 | 验收清单 | 0.5 h |

顺序不能颠倒：P1 单独验证「App 还能正常跑」，再动播放器，否则出问题分不清是新架构还是播放器。

## 9. 验收清单

- [ ] 杜比 Profile 5：有画面、颜色正确、有声音
- [ ] 普通 HDR10 / HDR10+：有画面、颜色正确
- [ ] SDR 4K：仍走 libmpv，起播时间不退化
- [ ] 直连探测不再固定等 6 秒（有画布后首帧提前到达）
- [ ] 拖动进度条：音画同步，无黑屏闪烁
- [ ] 退出播放页 / 切后台 / 转屏：无原生视图残留、无黑块
- [ ] TV 端回归：Media3 + 隧道模式行为不变

## 10. 回退策略

任一阶段失败，回退到「libmpv + 服务端 tone map」的既有组合，保证用户始终能看片：

- 客户端：`_androidNativeHdrEligible` 加回 `_tvMode` 限制（手机不走 Media3）
- 服务端：不变（tone map 已具备）
