# 服务端全量 + 增量发布

适用：服务端发新版。客户端代码没变时只发服务端，PC / 安卓 / TV 沿用已发布版本。

设计依据：`docs/design/增量更新与自动更新方案-2026-11-21.md` §10.1 / §18.4 / §19。

## 产物矩阵

| 产物 | 是否必发 | 说明 |
| --- | --- | --- |
| 服务端全量 `ColaNasOs-Server-<ver>-Setup.exe` | 是 | 首次安装与跨版本兜底，不能因为发了增量就撤掉 |
| 服务端增量资产 | 是 | 默认自动取上一版 `D<NNN>` 作基线 |
| `D<NNN>/` 版本目录 | 是 | 容器内版本，内核/模块/Web/契约/sidecars 一套 |
| `update.json` + `.sig` + `.sig.json` | 是 | 稳定源是 GitCode contents API，不是 raw 直链 |
| PC / 安卓 / TV 安装包 | 仅客户端代码有改动时 | 否则在清单里保留上一版组件 |

## 生成命令

```bash
node tool/release/release.js \
  --out=dist_release --tag=v<version> \
  --url-base=https://gitcode.com/cocacola23/ColaNasOs/releases/download/v<version> \
  --setup=dist_installer/ColaNasOs-Server-<version>-Setup.exe \
  --notes-zh="<说明>" --manifest-out=release
```

- 不传 `--from`：自动挑输出目录里最高的旧 `D<NNN>`；没有基线直接失败，不会静默只发全量。
- 多个候选基线：显式 `--from=dist_release/D<NNN>`。
- 补发已发布版本：`--reuse-version-dir`，复用那一版的版本目录，避免把发版后的在途改动混进去。
- 真要只发全量：`--no-delta`，且必须在提交信息写明原因。

## 资产命名

增量资产名带内容摘要，不复用固定名：

- `0-<sha12>-main.dart.js.br`
- `smallfiles-<sha12>.brb`
- `manifest-D<NNN>-<sha12>.json` 及 `.sig` / `.sig.json`

`dist_release/upload.json` 是权威上传列表。`update.json` 永远最后上传。

## 增量管不到外壳（最容易误判的一条）

版本目录里只有 `electron/kernel-host.js`。`electron/main.ts`（托盘、内核重启、
自愈回滚、stdout/stderr 落盘、更新器安装与切指针）编进 **asar**，增量永远碰不到。

- 改了 `electron/**`：必须发全量包，并在 Release 说明里单列「这条修复增量包不带」。
- 想强制所有人重装：清单加 `--min-shell=<version>`。`checkServer` 会比对
  `COLONAS_SHELL_VERSION`（外壳产品版本，不是 Electron 版本），低于要求就把
  `mode` 压成 `full` 并置 `needsReshell`。
- 判断一版到底改了什么：看 `dist_release/assets` 里 bundle 的 `members`。
  它是版本目录内的路径清单，出现 `electron/main.js` 就说明打包口径错了。

## 清单源与签名

- GitCode raw 直链匿名访问返回 403「暂不支持预览」，不要在 `?inline=false` 上反复试。
- 清单稳定源：`https://api.gitcode.com/api/v5/repos/cocacola23/ColaNasOs/contents/release/update.json`，匿名 200，正文是 `content` 字段的 base64。
- 签名源：`contents/release/update.json.sig.json`，内容 `{"keyId":"k2026a","sig":"..."}`；`.sig` 只在取不到 `.sig.json` 时回落，取到了但验签失败必须报错。
- `manifest.json.sig` 必须排除在 `listFiles()` 之外，否则签名自引用、清单永不收敛。
- 只发服务端时，从上一版清单复制 `client_pc` / `client_android` 到新清单再重新签名三件套，避免把客户端更新入口抹掉。

## 上传顺序与回读

1. 服务端全量包。
2. `dist_release/assets/*` 全部增量资产。
3. `update.json` / `update.json.sig` / `update.json.sig.json` 最后。
4. 每个 URL 用 `curl -r 0-15` 验 206；用 contents API 取清单与签名，base64 解码确认是真 JSON。
5. `npm run smoke:update` 跑 28 项端到端冒烟（篡改失败、自动降级全量、回滚、离线导入）。

## 1.3.18 实战数字

- 基线：`D10317`（1.3.17），变化 6 个文件（`web/main.dart.js` + 5 个小文件），资产 5 个 / 1.30 MB。
- 全量服务端：577,570,344 B，SHA256 `7274115bb9d4564c7dd15216cb7361530f2ef16e7bfb76ac54e4ad837f432b1a`。
- 版本目录 `D10318`：507 个文件 / 55.3 MB；清单资产 `manifest-D10318-c33bbcd08945.json`（65,455 B）。
- 线上端到端 13 项：清单 3813 B 验签、版本清单 507 文件验签且摘要一致、全量与全部增量资产 Range 206。
- 这一版的两条启动修复（日志落盘、失败回滚）都在 `electron/main.ts`，**增量不带**，
  必须全量安装才生效；增量只带内核侧的 contents API 修复。

## 1.3.17 实战数字

- 基线：`D10316`（1.3.16），变化 6 个文件，增量资产 5 个 / 1.30 MB。
- 全量服务端：577,569,173 B，SHA256 `421b4df272bb2602ef5ec6284f52f7c783192c8ecc497373e133b4b2661d18dd`。
- Release `v1.3.17`：9 个自有资产 + 4 个源码包；下载直链与 contents API 回读全通过。
- 发完发现 contents API 路径少一个斜杠（`contentsrelease/...`），修掉后重建服务端并重算增量/清单，Release 上旧资产按 API 删除后重传。
- 冒烟：`smoke:update` 28/28。

## 坑位

- electron-builder 下载偶尔被代理中断（`server aborted pending request` / 600s request timeout），重试即可；走 `http://127.0.0.1:21578`，验收前 unset 代理。
- 同一工作树里有并发发版时，`dist_release/` 会被互相覆盖；用隔离 `--out=` 目录，必要时 `--reuse-version-dir`。
- GitCode 同名附件不能覆盖；资产名带内容摘要就是为了避开这个问题。需要换掉同名资产时先按 API 删除再上传。
- 清单源 `<API 根>@@<仓库内路径>` 的 `@@` 两侧都要归一化斜杠，否则拼成 `contentsrelease/update.json`，平台返 404，客户端只看到「全部更新源失败」。
- 硬链接不能原地写；`version.json` 不能在发布后重写，否则切指针前全量校验对不上。
- **验签口径别搞混**：`update.json` 的签名覆盖**文件原始字节**；版本清单
  `manifest.json` 的签名覆盖 `canonicalPayload(version, files)`（键排序后的
  `{"version","files"}` 序列化），**不是**文件字节。用 `crypto.verify(null, 文件字节, …)`
  去验版本清单一定 FAIL，别据此判定发布坏了。正确做法是调
  `dist/kernel/update/verify.js#verifyVersionManifest(text, sig, 'k2026a')`。
- GitCode API 的令牌走 **query 参数** `?access_token=…`，`Authorization: Bearer`
  在部分接口上不生效（PATCH Release 描述就是其一）。
- Release 直链会 **302 跳转**，验可达性要跟随重定向（`curl -L`；Node 要自己处理，
  否则拿到 302 就误判成「资产不可达」）。
