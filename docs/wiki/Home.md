# ColaNasOs Wiki

> 在一台 Windows 主机上自托管的 NAS OS：相册、影视、音乐、文件、下载、同步与本地 AI 收进同一个服务端；桌面 / 手机 / Web / Android TV / Apple TV / 鸿蒙共用一套 Flutter 界面。数据只留在本机。

**当前版本：[v1.3.3](https://github.com/colaKot/ColaNasOs/releases/tag/v1.3.3)**　·　[官网](https://cola.gexuan.net/)　·　[源码](https://github.com/colaKot/ColaNasOs)　·　许可 GPL-3.0

---

## 这是什么

ColaNasOs 把「一台常开的 Windows 电脑」变成一台 NAS：

- **服务端** = Electron 外壳 + `utilityProcess` 内核 + 一堆 sidecar。Fastify + SQLite 直接读写本机目录，不依赖云账号，也不需要额外的数据库服务或 Docker。
- **客户端** = 一份 Flutter 代码，编译出 Windows / macOS / Linux / Android / iOS / Web / Android TV / 鸿蒙各端；导航、权限域、页面栈完全一致。
- **数据不出本机**：人脸、场景、语义检索、OCR、翻译、TTS 全部由 ONNX Runtime / llama.cpp 在本机推理，图片不上传。

## 快速开始

1. 下载并安装 **服务端**（`ColaNasOs-Server-1.3.3-Setup.exe`）→ 装完右下角只有一个托盘图标。
2. 在「设置」里登记**相册库 / 影视库 / 音乐库**（都是「文件」根下的子目录）。
3. 想在别的电脑上用，装 **客户端**（Windows / Android / Android TV 各一个包），填服务端地址登录。

→ 详见 [快速开始](Getting-Started)

## 最新变化（v1.3.3 之后的主干，尚未发版）

当前公开安装包仍是 v1.3.3。下面这些已在主干，需等下一个安装包才会在设备上生效：

- **Android TV 遥控器**：↑/↓ 一次走一行，到页面最顶才回 tab；返回先回当前栏目 tab，在 tab 上再按一次才退出。播放器里 ↓ 唤出操作栏、← → 跳时间、OK 暂停/继续、返回退出播放页。
- **大屏密度**：TV 版面按视口等比缩放（不再有 0.85 下限），网格列数按屏宽自适应，4K 电视一屏能看到更多行。
- **原片直连**：电视按屏幕 HDR 能力决定 DV / HDR10+ 是否直连，支持时不转码，硬解走 MediaCodec；原画档会话只换容器不重编码，元数据原样保留。播放器设置里可关闭这一策略。
- **响度归一**：库级开关通过 `compat.audioNormalize` 下发，直连时由播放器套 `dynaudnorm`；转码与离线下载在服务端做。
- **相册人物**：支持批量隐藏 / 并组 / 解散，单个人物右键可直接隐藏。

## Wiki 导航

| 页面 | 内容 |
| --- | --- |
| [快速开始](Getting-Started) | 安装、连服务端、首次配置 |
| [架构总览](Architecture) | 进程模型、技术栈、目录结构 |
| [服务端内核](Server-Kernel) | 模块注册、迁移、任务队列、鉴权、Sidecar |
| [客户端](Client) | 六端一套代码、目录、播放器要点 |
| [契约与 API](Contracts-API) | 单一真源、代码生成链、错误契约、文件传输协议 |
| [功能模块](Modules) | 14 个应用 / 15 个服务端域分别做什么 |
| [本地 AI 与模型](Local-AI) | 人脸、场景、语义检索、OCR、翻译、TTS |
| [开发指南](Development) | 环境、常用命令、工程红线 |
| [发版与交付](Release) | 版本号、打包、产物验收 |
| [运维手册](Operations) | 数据目录、健康检查、备份、更新回滚、安全基线 |
| [常见问题](FAQ) | 用户侧与运维侧的故障排查 |
| [路线图与状态](Roadmap) | 当前进度、阶段划分、DoD |
| [贡献与许可](Contributing) | 怎么参与、PR 规范、第三方组件许可 |

## 一分钟看懂架构

```
┌──────────────────────────────────────────────────────────┐
│ Electron 外壳：安装 / 单实例 / 托盘 / 更新器 / 自动启动      │
├──────────────────────────────────────────────────────────┤
│ Kernel 内核（TypeScript）                                │
│ ModuleRegistry │ Router(Fastify) │ Auth │ Db+Migration    │
│ TaskQueue │ EventBus │ ContractRegistry │ SidecarSupervisor│
├──────────────────────────────────────────────────────────┤
│ Domain Modules（src/modules/<domain>，目录即模块）          │
│ photo │ video │ music │ files │ discover │ sync │ blog …   │
├──────────────────────────────────────────────────────────┤
│ Sidecars（独立进程，NDJSON over named pipe）               │
│ ai-infer(ONNX) │ media(ffmpeg) │ indexer │ photo-ai │ mcp  │
├──────────────────────────────────────────────────────────┤
│ Flutter 单栈客户端（Windows / Android / Web / TV / 鸿蒙）    │
│ packages/nas_core · nas_ui · nas_media                    │
├──────────────────────────────────────────────────────────┤
│ 存储：SQLite(better-sqlite3) + sqlite-vec  +  本机文件系统   │
└──────────────────────────────────────────────────────────┘
```

三条主线：**内核只做通用能力**（认证、权限、DB、迁移、队列、事件、i18n、契约、进程守护）；
**域功能一律进域模块**；**重活一律下放 sidecar**。

## 仓库里的文档

Wiki 是给「想用、想改、想知道为什么」的人看的。仓库 `docs/` 里是更底层的施工与设计文档：

| 文档 | 内容 |
| --- | --- |
| `docs/00-索引.md` | 总索引与版本历史 |
| `docs/01-架构总览.md` | 架构蓝图（唯一施工依据） |
| `docs/02-服务端内核.md` | 内核、模块、数据层、Sidecar、队列规范 |
| `docs/03-契约与接口.md` | 契约单一真源、生成链、REST 规范 |
| `docs/04-客户端.md` | 客户端方案与设计系统 |
| `docs/05-工程与交付.md` | 阶段任务卡、工程红线、CI 门禁 |
| `docs/06-产品与运维.md` | 部署形态、术语表、第三方许可清单 |
| `docs/09-任务清单.md` / `docs/10-DoD.md` | 待办与完成定义 |
| `docs/api/api-reference.md` | 426 条路径 / 454 个操作的完整参考 |
| `docs/user/用户手册.md` / `docs/ops/运维手册.md` | 用户与运维视角的精简版 |

> 本 Wiki 的源文件在仓库 `docs/wiki/` 下，改完用 `node tool/sync-wiki.js` 推送。
