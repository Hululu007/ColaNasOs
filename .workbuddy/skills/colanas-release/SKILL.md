---
name: colanas-release
description: 用于 ColaNasOs 发版、本地 Git 功能提交、GitCode 默认推送、Release 创建与附件上传校验。仅当用户明确要求时才推 GitHub；否则绝不主动 push origin。当需要发布新版本、按新的增量更新方式打服务端全量+增量包、上传安装包/APK/增量资产到 Release，或处理 GitCode 附件 0 字节/同名上传失败时使用。其他 AI 编程工具可直接把本目录当作发版 playbook，脚本仅依赖 Python 3 标准库。
agent_created: true
---

# ColaNasOs 发版与双平台发布

## Overview

把一次 ColaNasOs 发版固化为可复现流程：版本号同步 → 只构建本轮有改动的产物 → 服务端版本目录/全量包/增量包/清单生成 → 验收 → 本地按功能提交 → **默认只 push GitCode + tag** → GitCode Release → 资产按序上传与强校验。服务端现在一律同时发全量包和增量包；GitHub 属于显式例外，只有用户明确说「推 GitHub」时才执行。脚本只依赖 Python 3 标准库，WorkBuddy、Claude Code、Cursor、Copilot 等能读仓库文件的工具都可使用。

## When to use

- 用户说「发版 / 发布版本 / Release / 上传附件 / 提交到 GitCode」。
- 用户明确说「也推 GitHub / GitHub 也发」时，才额外执行 GitHub 步骤。
- 需要复用 1.3.14 那套服务端、PC 客户端、安卓手机 APK、安卓 TV APK 的发布方式。
- 只发服务端：用户要「全量 + 增量都打出来」或「服务端发新版，客户端沿用」，走 Phase 4A。
- GitCode Release 附件出现 `size=0`、空 sha256、`gitcode-cli` 显示成功但下载为空。
- 只需要验证已有 Release 的附件，不需要重新上传。

## Non-negotiable guardrails

1. **版本单一真源**：`package.json#version`。使用 `node tool/version.js --set=X.Y.Z` 同步全部位置；每轮补丁位 +1。
2. **只按功能显式提交**：使用 `git add -- <path>...`，禁止 `git add -A`。工作树长期有在途文件。
3. **契约文件保护**：`contracts/apps.json`、`contracts/messages/*.json` 可能有用户未提交编辑；禁止 `git checkout --` 这些文件。撤销自己的改动要逐行改或先备份。
4. **平台固定为 Windows**：不给 Linux / macOS / Docker 分支。
5. **不跑全量门禁、不等 CI**：交付前只跑 `flutter analyze lib`、`npm run installer.check`、`npm run version:check`、`npm run sbom.check`。`verify:full` / CI 不作为本 Skill 的必经步骤。
6. **构建与验证的代理相反**：electron-builder 下载 Electron/依赖要挂 `http://127.0.0.1:21578`；跑 test / verify 前要 unset 代理。
7. **dev.bat 在跑时禁止构建 Web**：5173 走热重载，不要为了 7888 重建 `build/web`。
8. **凭据不进版本库**：GitHub 用 `GITHUB_TOKEN` 或 git credential；GitCode 用环境变量或仓库 `.workbuddy/.env`（已 gitignore，脚本自动读取）。不要写进被提交的文件、日志或临时脚本。
9. **附件必须强校验**：`gitcode-cli` 的 `✓` 不可信；最终以 API 返回的 `size` 和 `digest` 为准。
10. **默认只推 GitCode**：不主动 `git push origin`，不主动创建 GitHub Release。只有用户明确要求时才推 GitHub；用户没说就当没要求。
11. **服务端一律全量 + 增量**：`release.js` 自动取上一版 `D<NNN>` 作基线，不传 `--from` 也不静默退化成只发全量；真要只发全量必须 `--no-delta` 并在提交信息写明原因。全量包是首次安装和跨版本兜底，不能撤。
12. **清单最后上传**：资产全部就位后再传 `update.json` / `.sig` / `.sig.json`；传完必须回读 URL（或 GitCode contents API）确认能拿到真 JSON。
13. **GitCode raw 不可用**：`raw.gitcode.com` 匿名访问返 403「暂不支持预览」；清单源走公开仓库 contents API，签名优先 `.sig.json`（`.sig` 只在取不到时回落）。`<API 根>@@<仓库内路径>` 两侧斜杠必须归一化，否则拼成 `contentsrelease/...` 直接 404。
14. **外壳改动不进增量**：版本目录只有 `electron/kernel-host.js`，`electron/main.ts`（托盘、重启、自愈、日志落盘、更新器安装逻辑）住在 asar 里，**只能随全量包替换**。改了 `electron/**` 就必须发全量包，并在 Release 说明里写明「这条修复增量包不带」；需要强制所有人重装时给清单加 `--min-shell=<version>`，`checkServer` 会把 `mode` 直接压成 `full`。
15. **`npm run dist` 之后重生成清单**：安装包字节一变，`full.sha256` 就变。顺序永远是「构建 → installer.check → release.js → 并客户端组件 → 重签 → 上传」，不要先出清单再补构建。
16. **从 asar 里抽二进制必须用 `original-fs`**：Electron 给 `fs` 打了 asar 补丁，路径以 `.asar` 结尾时按「asar 内部条目」解析，`fs.openSync('<resources>/app.asar')` 直接抛 `ENOENT, not found in ...\resources\app.asar`。纯 Node 下能读、打包后必失败（摊平 `node_modules` 就踩过这条，异常还被 catch 吞掉，表现成「修复完全没生效」）。写法：`require('original-fs')`，纯 Node 环境 catch 回落普通 `fs`；失败信息必须落到 `<dataDir>/logs/shell.log`，GUI 外壳没有控制台，`console.error` 等于没写。
17. **默认发预发布，除非用户说「发正式版」**（用户 2026-11-21 定）：开发期的版本一律 `--pre` —— 清单写 `release/update-pre.json`（`channel: "pre"`），Release 标 `release_status=pre`。只有用户明确要求正式版时才发 `release/update.json` + `latest`。正式版清单决定了所有没勾「接收预发布」的设备看到什么，别拿它当日常测试通道。
18. **转正用同一个 tag 原地改，不要新建 Release**：GitCode 的 `DELETE /repos/{repo}/releases/{tag}` 返 **405 METHOD_NOT_ALLOWED**（平台不支持删除 Release），所以「发正式版时自动删掉旧预发布」做不到脚本化。正确流程：同一个 tag 重跑 `release.js`（不带 `--pre`）→ 补 `update.json` 三件套 + 全量包 → `scripts/patch_release.py --tag=... --latest` 把状态转正、正文改掉。历史遗留的预发布 Release 只能网页手工删，脚本里不要写自动删逻辑。

## Workflow decision tree

| 场景 | 执行 |
| --- | --- |
| 完整发版（默认） | Phase 0 → 1 → 2 → 3 → 4 → 6 → 7 |
| 只发服务端全量 + 增量 | Phase 0 → 1 → 2 → 3（仅服务端） → 4 → 4A → 6 → 7 |
| 代码已提交，只发 Release | Phase 0 → 4 → 6 → 7 |
| 只上传/修复附件 | Phase 0 → 6 → 7 |
| 只验证附件 | `gitcode_release.py --verify-only` |
| 用户明确要求推 GitHub | 先完成默认流程，再额外执行 Phase 5 + `git push origin main` + `git push origin v<version>` |

## Phase 0：确认输入

收集以下值；用户没给时按项目约定自行定并在最终报告中写明：

- 版本号：从 `package.json` 读当前值，补丁位 +1，例如 `1.3.14` → `1.3.15`。
- tag：`v<version>`。
- 默认远端：`gitcode` = `git@gitcode.com:cocacola23/ColaNasOs.git`。`origin` = `https://github.com/colaKot/ColaNasOs.git` 只作记录，用户没明确要求时不动。
- 产物目录：`dist_installer`。
- 附件集合：以 `dist_installer` 中带本次版本号的真实文件为准；典型为：
  - `ColaNasOs-Server-<ver>-Setup.exe`
  - `ColaNasOs-Client-<ver>-Setup.exe`
  - `ColaNasOs-Client-<ver>-windows-x64.zip`
  - `ColaNasOs-Client-<ver>-android-arm64.apk`
  - `ColaNasOs-Client-<ver>-android-arm64-tv.apk`（历史包也可能叫 `-androidtv-arm64.apk`，用实际文件名）
- 说明：用户没给 release notes 时，按「新增 / 修复 / 运维 / 升级说明 / 校验」生成简短说明。

「客户端」和「PC 端」是同一个产物，不重复发。

## Phase 1：发版前检查

```bash
git remote -v
git status --short
git tag --list 'v*' | tail -20
node -p "require('./package.json').version"
```

发现 `contracts/**` 有未提交改动时先停下，问清楚是否属于本次发版；不要覆盖用户编辑。

## Phase 2：版本 bump 与同步

```bash
node tool/version.js --set=<version>
npm run version:check
npm run sbom
npm run sbom.check
```

`tool/version.js --set` 会同步 `package.json`、四个 pubspec 的 `X.Y.Z+B`、鸿蒙 `versionCode`、`apps/colanas_os/lib/core/app_version.dart`。改完版本号必须跑 `npm run sbom`，否则 `sbom.check` 会红。

不要重复跑 `node tool/version.js` 做「补同步」：`--set` 已包含构建号 +1 的正确写入。

## Phase 3：构建本轮需要的产物

先对比 `git diff <上一版 tag>..HEAD -- apps packages contracts`：客户端代码没变就不要重建 PC / APK，清单里保留它们上一版的组件即可。
服务端只要有改动（含发布工具改动），服务端全量包必须重建。按顺序执行；每步失败就停，不要带着半成品继续。

```bash
# 1) 正式 Web（dev.bat 在跑时不要执行）
build-web.bat

# 2) 服务端 tsc + 安装包（electron-builder 需要代理）
export HTTP_PROXY=http://127.0.0.1:21578 HTTPS_PROXY=http://127.0.0.1:21578
export NO_PROXY=127.0.0.1,localhost
npm run dist

# 3) PC 客户端安装版 + 便携包
node tool/build-client-installer.js

# 4) 安卓手机 APK
build-android.bat

# 5) 安卓 TV APK
build-android-tv.bat

# 6) 构建后把代理去掉，再做验收
unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
```

`.bat` 脚本里有 `pause`，非交互环境不要直接调用；改跑它们内部同样的命令并自行复制产物：

```bash
cd apps/colanas_os
flutter build apk --release --target-platform android-arm64
cp -f build/app/outputs/flutter-apk/app-release.apk ../dist_installer/ColaNasOs-Client-<ver>-android-arm64.apk
flutter build apk --release --target-platform android-arm64 --target lib/main_tv.dart --dart-define=COLANAS_TV=1
cp -f build/app/outputs/flutter-apk/app-release.apk ../dist_installer/ColaNasOs-Client-<ver>-android-arm64-tv.apk
cd ../..
```

两次构建共用 `app-release.apk` 输出路径：**每次构建完必须立刻复制**，否则 TV 包会覆盖手机包。
两个 APK 的 zip 条目基本一致，只有 `lib/arm64-v8a/libapp.so` 不同，这是 TV define 生效的正常表现。

## Phase 4：验收、提交、推送

验收：

```bash
flutter analyze lib
npm run installer.check
npm run version:check
npm run sbom.check
```

内容级验收不能只看大小：

- 服务端：asar 内 `dist/src/modules/*`、`dist/electron/main.js`，`package.json` 版本正确。
- PC 客户端：解压/展开后 `data/app.so` 存在（exe 只是启动壳）。
- APK：`lib/arm64-v8a/libapp.so` 存在；手机包和 TV 包用 `libapp.so` 哈希区分，不用体积区分。
- 中文串在 AOT / dart2js 产物里会被转义，用 ASCII 指纹验证。

提交与推送：

```bash
git status --short
git add -- package.json apps/colanas_os/pubspec.yaml apps/colanas_os/lib/core/app_version.dart <其他本次改动>
git commit -m "chore(release): 发布 v<version>"
git push gitcode main
git tag -a v<version> -m "ColaNasOs <version>"
git push gitcode v<version>
```

⛔ 不要写 `git push origin main` / `git push origin v<version>`，除非用户明确说「推 GitHub」。

按功能拆分提交时，每个 commit 只 `git add` 该功能相关路径。禁止把 `contracts/**` 的用户在途编辑卷进来。

## Phase 4A：服务端全量 + 增量（新版打法）

设计依据：`docs/design/增量更新与自动更新方案-2026-11-21.md` §10.1 / §18.4 / §19。现行工具比文档示例更新：**自动选基线**、**资产名带内容摘要**、**清单走 GitCode contents API**。

```bash
node tool/release/release.js \
  --out=dist_release --tag=v<version> \
  --url-base=https://gitcode.com/cocacola23/ColaNasOs/releases/download/v<version> \
  --setup=dist_installer/ColaNasOs-Server-<version>-Setup.exe \
  --notes-zh="<说明>" --manifest-out=release
```

- 不传 `--from`：工具自动取输出目录里最高的旧 `D<NNN>` 作基线；找不到基线直接失败，不会退化成只发全量。多个候选版本时用 `--from` 显式指定。发版中途失败会留下半成品 `D<NNN>`，下次自动基线会挑到它，先删掉再重跑。
- **加 `--pre` 就是预发布通道**：清单写成 `release/update-pre.json`（`channel: "pre"`），后面的 `gitcode_release.py` 也要带 `--pre`，Release 才是「预发布」。不加 `--pre` 走正式通道 `update.json`。
- 两条通道各有一份完整清单（含签名），服务端设置 `channel=pre` 时读 `update-pre.json`，读不到会自动回落 `update.json`（还没发过预发布时不至于报错）。客户端与服务的勾选见 `update.preChannel`。
- 补发已发布版本时加 `--reuse-version-dir`：复用那版已有的版本目录，不从当前 `dist/` 重建，避免把发版后的在途代码混进去。
- 补发还要显式给版本号：`--semver=<X.Y.Z> --version-code=<原 B 值>`。发版成功后 `package.json` 已经 bump 到下一版，不带这两个参数会把新版本号写进旧清单。
- ⛔ **不传 `--pc-setup` / `--apk` 等客户端参数时，`components.client_pc` 与 `components.client_android` 会被整个抹掉**（不是保留上一版），客户端从此收不到更新。只发服务端时必须按下面的脚本并回上一版组件。
- 产物：`dist_release/D<NNN>/`（版本目录）、`dist_release/assets/*`（增量资产）、`dist_release/update.json(.sig/.sig.json)`。资产名内容寻址，例如 `0-<sha12>-main.dart.js.br`、`manifest-D<NNN>-<sha12>.json(.sig/.sig.json)`；不要沿用固定文件名。
- `dist_release/upload.json` 是权威上传列表，逐项上传，不要凭记忆拼文件名。

只发服务端时，客户端组件仍要保留在清单里：从上一版 `update.json` 复制 `client_pc` / `client_android`，然后重新签名三件套。

```bash
node -e '
const fs=require("node:fs"), cp=require("node:child_process"), crypto=require("node:crypto");
const L=require("./tool/release/lib.js");
const j=JSON.parse(fs.readFileSync("release/update.json","utf8"));
const prev=JSON.parse(cp.execFileSync("git",["show","<上一版清单提交>:release/update.json"],{encoding:"utf8"}));
for (const k of ["client_pc","client_android"]) if (prev.components[k]) j.components[k]=prev.components[k];
const text=JSON.stringify(j,null,2)+"\n";
const {pem}=L.loadPrivateKey();
const sig=crypto.sign(null,Buffer.from(text,"utf8"),pem).toString("base64");
for (const d of ["dist_release","release"]) {
  fs.writeFileSync(d+"/update.json",text,"utf8");
  fs.writeFileSync(d+"/update.json.sig",sig,"utf8");
  fs.writeFileSync(d+"/update.json.sig.json",JSON.stringify({keyId:j.keyId,sig},null,2)+"\n","utf8");
}
'
```

增量链路冒烟：`npm run smoke:update`（28 项，含篡改失败、自动降级全量、回滚、离线导入）。`installer.check` / `version:check` / `sbom.check` 照常跑。

上传顺序固定：**全量包 → 增量资产 → 清单三件套**（清单必须最后，否则客户端拿到清单去下还没传完的资产）。

```bash
PY=python   # 本机可用 C:/Users/cola/.workbuddy/binaries/python/versions/3.13.12/python.exe
S=.workbuddy/skills/colanas-release/scripts/gitcode_release.py

$PY $S --repo cocacola23/ColaNasOs --tag v<version> --dist dist_installer \
  --files "ColaNasOs-Server-<version>-Setup.exe" --proxy ""

$PY $S --repo cocacola23/ColaNasOs --tag v<version> --dist dist_release/assets \
  --files "$(ls dist_release/assets | tr '\n' ',' | sed 's/,$//')" --proxy ""

$PY $S --repo cocacola23/ColaNasOs --tag v<version> --dist dist_release \
  --files "update.json,update.json.sig,update.json.sig.json" --proxy ""
```

`--proxy ""` 表示直连；550 MB 全量包实测直连可传（走 `127.0.0.1:21578` 反而更慢）。脚本会逐项核对远端 `size` 与 sha256，任何一项不符就非零退出。

## Phase 5：GitHub Release（仅用户明确要求时执行）

默认跳过本阶段。只有用户明确说「也推 GitHub / GitHub 也发 Release」时才执行，并同时补 `git push origin main` 与 `git push origin v<version>`。

脚本路径：`scripts/github_release.py`。凭据来自 `GITHUB_TOKEN`，缺失时从 `git credential fill` 读取 GitHub PAT。默认代理 `http://127.0.0.1:21578`；直连传 `--proxy ""`。

```bash
python .workbuddy/skills/colanas-release/scripts/github_release.py \
  --repo colaKot/ColaNasOs --tag v<version> --dist dist_installer \
  --files "$FILES" \
  --proxy http://127.0.0.1:21578 \
  --notes-file RELEASE_NOTES.md
```

脚本行为：复用已有 Release；同名且大小一致的附件跳过；大附件走代理上传；最后逐个核对 `size` 和 `browser_download_url`。失败时非零退出。

只验证：

```bash
python .workbuddy/skills/colanas-release/scripts/github_release.py \
  --repo colaKot/ColaNasOs --tag v<version> --dist dist_installer \
  --files "$FILES" --verify-only
```

## Phase 6：GitCode Release

脚本路径：`scripts/gitcode_release.py`。脚本优先读环境变量 `GITCODE_TOKEN`，没有时自动读仓库 `.workbuddy/.env`。只有本机还没有令牌文件时才需要临时导出：

```bash
export GITCODE_TOKEN=<PAT>
```

创建/复用 Release，并用官方预签名 URL 两步上传：

```bash
python .workbuddy/skills/colanas-release/scripts/gitcode_release.py \
  --repo cocacola23/ColaNasOs --tag v<version> --dist dist_installer \
  --files "$FILES" --notes-file RELEASE_NOTES.md --suffix -v2
```

关键行为：

- Release 不存在时按 API 创建（`release_status=latest`，`--pre` 时为 `pre`）。
- 同名非空附件跳过，避免重复上传。
- 同名 0 字节附件存在时，默认复制成带 `-v2` 的新文件名上传；这是绕开 GitCode「同名更新失败」的标准做法。
- 显式 `--clean-empty` 会先删除同名 0 字节附件，再用原文件名上传（这是远程删除操作，只在用户确认清理时使用）。
- `--uploader cli` 可改用 `gitcode-cli`，但脚本仍会查 API 验证，不信任 `✓`。
- 上传后核对远端 `size` 与本地一致；有 `digest` 时核对 sha256。不一致即失败。
- Release 已存在时脚本只复用，不更新描述。要改描述用 `scripts/patch_release.py`（内部走
  `PATCH /api/v5/repos/{owner}/{repo}/releases/{tag}`，body 至少带 `name` 和 `body`，
  可选 `release_status=latest`）。追加产物后应同步改描述，避免说明与附件矛盾。
- **Release 页面排版（用户 2026-11-21 定）：附件区动不了，正文才是可编排的地方。**
  - 附件区（assets）**不能排序、不能折叠、不支持自定义链接资产** —— v5 API 的 release 结构里
    没有 `links` 字段，上游 GitLab 同样有「assets 顺序创建后不保留」的 issue。想突出全量包
    只能靠正文里的下载表，不要试图调附件顺序。
  - 正文用 `scripts/make_release_notes.py` 生成：**最上面是「⬇️ 下载」表**（服务端 / PC 安装版 /
    PC 便携 / 安卓手机 / 安卓 TV，点名即下、带大小），中间写本版改动，**增量 / 清单 / 签名说明
    和排障信息全部塞进 `<details>` 折叠块**。GitCode 的 Markdown 支持 `details` / `summary`
    （官方帮助文档有专节），块内 Markdown 要留空行才会渲染。
  - 落款流程：`make_release_notes.py --version ... --changes-file ... --no-delta --min-shell ... --out body.md`
    → `patch_release.py --tag v<version> --name "ColaNasOs <version>" --body-file body.md --latest`。
- 增量发布上传顺序：**服务端全量包 → `dist_release/assets/*` 增量资产 → `update.json` / `.sig` / `.sig.json` 最后**。顺序错了就是「清单先到、包没传完」的 404 地狱。
- 发布后回读：每个 `urls[]` 用 `curl -r 0-15` 验 206；再用 GitCode contents API 取 `release/update.json` 和 `release/update.json.sig.json`，确认匿名可取且 base64 解码出真 JSON。
- `tool/release/publish.js --dir=dist_release --tag=v<version> --platform=gitcode` 是仓库自带的一键上传+回读实现，需要 `GITCODE_TOKEN`；本 Skill 的 `gitcode_release.py` 走同样的预签名上传，但显式代理且强校验 size/digest。

只验证：

```bash
python .workbuddy/skills/colanas-release/scripts/gitcode_release.py \
  --repo cocacola23/ColaNasOs --tag v<version> --dist dist_installer \
  --files "$FILES" --verify-only
```

## Phase 7：最终报告

输出必须包含：

1. 本地 commit 列表与 GitCode 远端的最新 commit / tag；如用户明确要求推 GitHub，再补 GitHub 状态。
2. GitCode Release URL；如用户明确要求，再补 GitHub Release URL。
3. 每个附件的名称、大小、sha256 和验证结果；增量发布要单列基线版本、变化文件数、增量体积和 `smoke:update` 结果。
4. 上传后是否仍有旧的 0 字节附件；若有，列出名称和网页清理地址。
5. 任何未自动完成的步骤（网页删除、官网同步等）。

## Scripts

| 脚本 | 用途 |
| --- | --- |
| `scripts/github_release.py` | 仅显式要求 GitHub 时使用：Release 创建、附件上传、size 校验、verify-only |
| `scripts/gitcode_release.py` | 默认使用：GitCode Release 创建、官方预签名两步上传、空附件处理、size/digest 强校验 |
| `scripts/make_release_notes.py` | 生成 Release 正文：顶部下载表（全量包）+ 本版改动 + `<details>` 折叠的资产说明与排障 |
| `scripts/patch_release.py` | 更新已存在 Release 的标题 / 正文 / `release_status=latest` |

## References

- `references/release-playbook.md`：1.3.14 实战命令串、验收清单、提交拆分口径。
- `references/gitcode-attachments.md`：GitCode 预签名上传 API 细节、0 字节根因、`gitcode-cli` 假成功证据、清理接口。
- `references/incremental-release.md`：新版服务端全量+增量打法、自动基线、内容寻址资产名、contents API 清单源、混合客户端版本保留。
