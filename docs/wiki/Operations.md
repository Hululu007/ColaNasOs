# 运维手册

> 面向装好 ColaNasOs 之后要维护它的人。细节见仓库 `docs/ops/运维手册.md`。

## 运行形态

| 形态 | 端口 | 用途 |
| --- | --- | --- |
| 正式服务端 | **7788** | 托盘常驻，内核 + Web 界面 + sidecar |
| 开发内核 | **7888** | `dev.bat` 启动，改代码自动重启，开 CORS |

两者互不干扰。`dev.bat` 会探活 7788，发现正式版在跑就**只保留界面与接口、跳过全部后台任务**，避免两套实例抢同一个库。

## 数据目录

根目录：Windows `%APPDATA%\colanas_os_server`（可用 `COLANAS_DATA_DIR` 覆盖）。

| 内容 | 位置 |
| --- | --- |
| 数据库 | `<dataDir>/colanas.sqlite`（含迁移版本表，启动时自动前滚） |
| 文件根 | 由 `files` 模块的根目录配置决定；所有「相对路径」都相对它，越界一律 400 |
| 备份 | `<dataDir>/backup`（含逐文件 sha256 清单） |
| 缩略图缓存 | `<dataDir>/thumbs`（可整目录删除，会自动重建） |
| 版本目录 | `<dataDir>/versions/D<NNN>` + `current.json` 指针 |
| 日志 | `<dataDir>/logs/kernel.log` |
| 进程号 | `<dataDir>/kernel.pid` |

> **用户文件与元数据不可重建**；索引、缩略图、AI 结果可以重建。

## 健康检查与观测

| 用途 | 入口 |
| --- | --- |
| 存活 | `GET http://127.0.0.1:7788/health`（返回体含 `"ok":true`） |
| 就绪 | `GET /ready`（`background` 字段说明后台任务有没有被跳过） |
| 资源 | `GET /api/v1/system/monitor`：CPU（两次采样）、内存、磁盘、负载、运行时长 |
| 进程 | `GET /api/v1/system/processes`；`POST /api/v1/system/processes/kill`（拒绝 pid ≤ 4 与自身） |
| 客户端 | 客户端「监控」页 |

**日志**：应用日志保留 30 天、审计日志 180 天；请求日志里的 `token=` 已脱敏（媒体直链路由除外）。

### 客户端日志

客户端（含播放器）的日志会 POST 到服务端 `/api/v1/system/client-log`，落到 `<dataDir>/logs/kernel.log`，路由形如：

```
full/windows:player.seek/<sessionId>
full/windows:player.stall/<sessionId>
```

排查「卡住 / 不动 / 没声音」这类问题时，**先在这里找**，比看界面提示有用得多。

## 备份与恢复

1. 客户端「安全」页 → 立即备份：填来源目录（相对文件根）+ 可选名称；
2. 备份产物是「文件副本 + sha256 清单」，恢复前**逐文件校验清单**，篡改直接 400 `corrupted`；
3. 恢复到新目录时同名文件**拒绝覆盖**（先改名或换目标目录）；
4. 升级数据库前会自动打 DB 快照；**跨大版本升级前先做一次完整备份**。

> 加密空间（`/vault/*`）是另一条链路：scrypt 派生密钥 + AES-256-GCM，密码不落库、不落日志，**忘记密码即无法恢复**（设计如此）。

## 更新与回滚

更新器只接受「新版本目录 + 签名匹配的 manifest」，**默认禁止降级**（除非显式 `--force-downgrade`）。回滚就是把指针切回上一版：

```
versions/D001 ← 旧
versions/D002 ← 当前（current.json 指向）
rollback() → current.json 改回 D001
```

发布后 24 小时内保留上一版本目录。

## 安全基线

- 默认**只监听 127.0.0.1**；对外暴露必须自己加反向代理 + TLS。
- 首次启动**必须**改掉初始管理员口令；敏感账号开 TOTP 两步验证。
- 子账号按 scope 授权，不要给无关账号 `*`。
- IP 黑名单支持精确 IP 与 IPv4 CIDR，生效于鉴权**前**。
- Webhook 投递带 `x-colanas-signature: sha256=<hex>`，接收方必须验签。
- 出站代理（`kernel/https-proxy.ts`）开启时代理地址会打印到日志，便于归因。

## 常见故障

| 现象 | 原因 / 处理 |
| --- | --- |
| 启动即报 `ERR_DLOPEN_FAILED` / ABI 不匹配 | 原生模块未按 Electron ABI 重建：`npm run rebuild`；纯 `node` 加载 `dist/` 也会触发 |
| 影视 / 音乐无封面、探测全失败 | 服务端没装 ffmpeg：`npm run ffmpeg:fetch` 后 `npm run ffmpeg:check`。**不要**依赖系统 PATH 上的 ffmpeg（可能是别的软件附带的，没有 ffprobe） |
| 相册格子全是占位图（`/files/thumb` 503） | 同上缺 ffmpeg。缩略图由 media sidecar 生成，缓存目录 `<dataDir>/thumbs`，可整目录删除后自动重建 |
| rclone 类挂载一律 501 | 没装 rclone：设置 `COLANAS_RCLONE` 或让 `rclone` 进 PATH |
| 端口被占用 | 内核端口默认 7788，用 `PORT` 覆盖；客户端会提示 |
| 播放器 401 | 直链令牌 5 分钟过期：回列表重新取一次播放地址 |
| 笔记 / 相册条目消失 | 先确认不是登录了另一个子账号（数据按 JWT `sub` 隔离） |
| 更新后打不开 | 检查 `current.json` 指针与 `versions/` 完整性，执行回滚 |
| 画面不动 / 跳了没反应 | 客户端日志里搜 `player.stall/`：看门狗会自动续转 + 重新定位；连续告警说明服务端转码跟不上 |

## 性能基线

| 项 | 目标 |
| --- | --- |
| 冷启动 → `/health` | 约 1.2 s |
| 内核重启 | 1 s 内（开发模式自动） |
| 相册格子 | 走缩略图缓存，首访问按需生成 |
| 大目录 | 记忆列表每页 10 条；日志真分页倒读 |

## 相关页面

- [常见问题](FAQ)
- [功能模块](Modules)
- [发版与交付](Release)
