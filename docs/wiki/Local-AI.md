# 本地 AI 与模型

> ColaNasOs 的 AI 能力**全部在用户本机推理**，图片不上传、不出网。
> 模型随安装包分发在 `vendor/models/`（不入库），也可以在应用内按需下载。

## 能力一览

| 能力 | 实现 | 入口 |
| --- | --- | --- |
| 人脸检测与对齐 | ONNX Runtime | 相册 → 智能相册（人脸） |
| 人脸聚类与人物关系 | ONNX Runtime + 端侧聚类 | 同上 |
| 场景识别（365 类） | ONNX Runtime | 相册 → 智能相册（场景） |
| 语义检索（以图搜图 / 以文搜图） | CLIP（视觉塔 + 文本嵌入） | 相册 → 搜索 |
| 文字识别（OCR） | ONNX Runtime | 相册 → 图片文字 |
| 活动 / 事件识别 | 零样本视觉编码器 | 相册 → 智能相册 |
| 短文本翻译 | llama.cpp `llama-server` | 客户端翻译功能 |
| 语音合成（TTS） | llama.cpp `llama-tts` | AI 播客朗读 |

## 随包分发的模型

| 模型 / 目录 | 用途 | 运行时 |
| --- | --- | --- |
| `faces/faceLandMark` | 人脸检测与 106 点关键点、人脸对齐 | ONNX Runtime |
| `faces/edgeface` | 512 维人脸特征向量（聚类 / 检索） | ONNX Runtime |
| `places365`（ResNet50） | 365 类场景分类 | ONNX Runtime |
| `clip`（视觉塔 + 文本嵌入） | 语义检索、场景打分与图像特征 | ONNX Runtime |
| `ppocrv6`（det / cls / rec） | 图片文字识别 | ONNX Runtime |
| `activity`（零样本视觉编码器 + 候选标签文本嵌入） | 活动 / 事件识别 | ONNX Runtime |
| `mt`（Qwen3-1.7B GGUF） | 本地短文本翻译 | llama.cpp `llama-server` |
| `qwen3-tts`（Qwen3-TTS-12Hz-1.7B GGUF） | 语音合成（配合内置音色） | llama.cpp `llama-tts` |

> 翻译与 TTS 权重合计约 1.4 GB，**不随安装包分发**，在应用内按需下载。
> 模型版权归各自作者所有，按各自许可证使用（见 `docs/06-产品与运维.md` 的第三方清单）。

## 为什么不用云 API

| 收益 | 说明 |
| --- | --- |
| 隐私 | 照片是全家最敏感的数据，不出本机就没有泄露面 |
| 成本 | 没有按次计费，没有 API Key 过期问题，离线可用 |
| 可用性 | 断网、墙内外网不稳定都不影响相册功能 |
| 合规 | 家庭照片不过第三方服务器，省掉一堆数据出境说明 |

## 两个踩过坑的地方

### 1. ONNX 版本不能随便升

实测 `onnxruntime-node` **1.30 在 Windows + DML 上硬回归**：`webgpu` 与 `dml` 互斥导致会话全废、CLIP 直接崩进程、DETR/SigLIP 慢约 90%。

**结论：继续用 1.20**，且 `getBestExecutionProviders()` 必须**显式排除 `webgpu`**。

### 2. 没有 GPU 也能跑

ONNX 走 CPU（DML）也能工作，只是慢。应用里会先探测硬件能力（`sidecars/gpu/gpu-probe.ps1`），按结果选执行提供程序。

> 相关：`kernel/gpu-probe.ts` 是**硬件编码器**探测（转码用），和 AI 推理探测是两回事。前者的探测结果会落盘缓存，第二次启动不再重复试编——这就是「冷启动 8 秒、第二次 0.3 秒」的来源。

## 相关页面

- [服务端内核](Server-Kernel) —— sidecar 怎么被拉起与监管
- [功能模块](Modules) —— 相册与 AI 播客
- [贡献与许可](Contributing) —— 第三方组件与许可口径
