# 贡献与许可

## 怎么参与

- **提 Issue**：描述现象时附上**版本号**（客户端「关于」页 / 托盘右键第一行）与**复现步骤**。
- **报 Bug**：播放器相关的问题请附客户端日志（`<dataDir>/logs/kernel.log` 里搜 `player.`），这比截图有用得多。
- **提 PR**：从 `main` 切分支，一次只做一件事，提交信息写清改动点。
- **翻译**：见 `docs/i18n/翻译工作流.md`。

## 贡献前请确认

1. **不复制外部源码、资源或译文**（工程红线 12）。第三方库只能从**上游**引入。
2. **AGPL-3.0 组件默认禁止**。确需引入必须同时满足五个条件：① 独立进程运行、仅经 CLI/API 调用；② 不修改其源码；③ 不静态链接、不并入同一二进制；④ 法务书面确认；⑤ SBOM 显式标注。缺一即阻断。
3. **GPL 组件**（如 FFmpeg）同样只能以独立进程调用；随包分发须提供源码获取方式。
4. **契约生成物禁止手写**。改 schema → 跑生成链 → 提交生成物。
5. **原生模块**（`better-sqlite3` / `node-pty` / `node-datachannel`）改动后跑 `npm run smoke:abi`。
6. **ONNX 版本不要动**（继续 1.20，显式排除 `webgpu`）。

## 许可

- **本项目：GPL-3.0**。
- 因为项目本身是 GPL-3.0，**引入 GPL 组件不增加额外负担**（只是解释成本）；AGPL 才是需要额外评估的那一类。
- 随包分发的第三方二进制与模型的版权归各自作者，按各自许可证使用。完整清单见仓库 `docs/06-产品与运维.md` 的「第三方上游与许可清单」与 `docs/sbom/`。

### 随包分发的第三方二进制

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| `vendor/transmission-win/` | 内置下载器的 `transmission-daemon.exe` 与依赖 DLL（取自官方 `transmission-4.1.4-x64.msi`，原样提取未修改） | GPL-3.0 |
| `vendor/transmission-web/` | 官方 Web 界面静态文件（3.00） | GPL-3.0 |
| `vendor/transmission-web-control/` | 中文 Web UI（v1.6.1） | MIT |
| `vendor/ffmpeg/` | 转码、抽帧、缩略图（Jellyfin 定制构建，含 x264/x265） | GPL-2.0+ |
| `vendor/llama/` | `llama-server` / `llama-tts`，本地 GGUF 推理 | MIT |
| `vendor/geo/`、`vendor/voices/` | 地名库、内置参考音色 | 见目录内说明 |

> 「内置下载器」用的是官方 Transmission Web UI 3.00（整页英文）加中文前端，缺失时回退官方包。

## 安全问题

发现安全问题**请先私信维护者**，不要直接开公开 Issue。修复发布后会在 release 说明里致谢。

## 相关页面

- [开发指南](Development) —— 命令、红线、提交约定
- [发版与交付](Release)
- [本地 AI 与模型](Local-AI) —— 模型许可
