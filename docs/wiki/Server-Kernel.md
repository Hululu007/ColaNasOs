# 服务端内核

> 内核（`kernel/`）是「通用能力层」：认证、权限、DB、迁移、队列、事件、契约、进程守护。
> 业务功能一律不在内核里，而是放在 `src/modules/<domain>/`。
> 细节见仓库 `docs/02-服务端内核.md`。

## 启动顺序（有个坑）

```
kernel/index.ts
  ├─ 216 行附近：跑 BASE_MIGRATIONS        ← 先于模块挂载
  ├─ 647 行附近：registry.mount() 收集各模块 migrations
  └─ 之后：跑模块迁移 → 挂路由 → 起队列 / sidecar
```

⚠️ **任何要读写模块表（`auth_users`、`auth_api_tokens` 等）的迁移，不能放进 `kernel/migrations/base.ts`** —— 基线迁移跑的时候模块表还没建，会直接 `no such table` 启动失败。正确做法是挂到对应模块的 `migrations` 数组末尾 + `MIGRATION_ORDER` 末尾追加，并在迁移里**先判断表是否存在**，表不在就跳过。

## 模块注册器

- 每个域模块是一个目录：`src/modules/<domain>/{routes,services,repo,migrations,i18n,index.ts}`。
- 模块自己声明路由与 schema，**内核只负责挂载**。
- 当前 15 个域：`auth` `photo` `video` `videoPlayer` `music` `discover` `rss` `pt` `files` `transfer` `sync` `blog` `media` `system` `integrations`。
- 拆分巨型模块有专用工具 `tool/split/split-module.js`，只做机械搬运；拆完必须过三道校验：
  `tsc --noEmit` → 该模块 smoke → `npm run gen.check`（契约 `paths` 数量与内容不能变）。

## 数据层

| 方面 | 做法 |
| --- | --- |
| 引擎 | `better-sqlite3`（**同步 API**，会阻塞事件循环） |
| 查询层 | Kysely（类型安全） |
| 迁移 | Kysely migration，启动时自动前滚 |
| 向量 | `sqlite-vec`（ANN），人脸 / 语义检索不用全量余弦 |
| 事务 | **单事务 ≤ 50 ms**；事务内**禁止** `await` / 文件 IO / 网络；大事务拆批 |
| 慢查询 | > 100 ms 必须记日志 |
| 变量上限 | SQLite 999 个变量 ⇒ 批量 `whereIn` 分片（400/批） |

> 主库选型结论是**不换库**：保持 SQLite，靠「写模型集中（只有主进程写主库）+ 调优参数 + 向量破百万再旁路」三条策略。索引、缩略图、AI 结果都可重建；**用户文件与元数据不可重建**。

## 任务队列

自建 SQLite 持久化队列，不引 Redis。能力：优先级、限流、暂停、进度上报、重试、撤销、去重。

- 任务进度通过事件流推给客户端（监控页、传输页都靠它）。
- 队列任务与 sidecar 进程解耦：sidecar 崩溃只影响该任务，可重投。

## 鉴权与权限

- **JWT**，密钥**持久化落盘**（`<dataDir>/jwt.secret`），优先级
  `COLANAS_JWT_SECRET` > `<dataDir>/jwt.secret` > 首次生成后落盘。
  ⚠️ 早期实现是随机生成，重启后所有客户端被踢回登录页 —— 现在不会了。
- **权限域（scope）**：`photo:read`、`video:read`、`transfer:write` 这种粒度，子账号按需分配；内核在鉴权层校验。
- **路径越界拦截**：所有路径都是「相对文件根」，`..` 越界一律 400。
- **IP 黑名单**：支持精确 IP 与 IPv4 CIDR，**在鉴权前**生效（命中直接 403）。
- 自动登录：客户端记住密码，token 过期后用记住的密码重新换发。

## Sidecar 体系

Sidecar 是**独立进程 + NDJSON over named pipe（Windows）**，由 `kernel/sidecar/supervisor.ts` 统一管理启动、心跳与崩溃重启。

| Sidecar | 职责 |
| --- | --- |
| `sidecars/media` | FFmpeg 转码、抽帧、缩略图、HLS 分片 |
| `sidecars/ai-infer` | ONNX 推理（人脸 / 场景 / CLIP / OCR / 活动识别） |
| `sidecars/photo-ai` | 相册域的 AI 编排（人脸聚类、场景融合、语义检索、OCR） |
| `sidecars/indexer` | 媒体库索引扫描 |
| `sidecars/mcp` | MCP 接入 |
| `sidecars/gpu` | GPU 能力探测（`gpu-probe.ps1`） |

协议要点：NDJSON 一行一个 JSON、有超时、心跳、崩溃自动重启；**sidecar 脚本必须以独立进程运行**（GPL 组件的合规要求，见[贡献与许可](Contributing)）。

## 事件流

Fastify WebSocket 推送：任务进度、库扫描状态、下载状态、转码会话状态。客户端据此更新 UI，不用轮询。

## 契约导出

`ContractRegistry` 从运行中的内核导出 OpenAPI 3.0.3（`/openapi.json`），这是全链路代码生成的源头。详见[契约与 API](Contracts-API)。

## 资源与配置

- `kernel/system-settings.ts`：系统级设置（持久化到 `<dataDir>`）。
- `kernel/https-proxy.ts` / `proxy-fetch.ts`：**出站代理**（境外源抓取、AI 模型下载、刮削都走这里）。开启时代理会在日志里打印，失败时才能归因。
- `kernel/secret-box.ts`：敏感值加密存储（2FA 密钥等），**明文只在开启时展示一次**。
- `kernel/gpu-probe.ts`：硬件编码器探测，结果落盘复用（冷启动那 8 秒就是它）。

## 监控与看门狗

- `kernel/watchdog.ts` + `watchdog-supervisor.ts`：sidecar / 内核异常自愈。
- `GET /health` 存活探针；`GET /ready` 就绪探针（含 `background` 字段说明后台任务有没有被跳过）。
- `GET /api/v1/system/monitor`：CPU（两次采样）、内存、磁盘、负载、运行时长。
- `GET /api/v1/system/processes` + `POST /api/v1/system/processes/kill`（拒绝 pid ≤ 4 与自身）。

## 相关页面

- [架构总览](Architecture)
- [运维手册](Operations) —— 数据目录、备份、故障排查
- [本地 AI 与模型](Local-AI)
