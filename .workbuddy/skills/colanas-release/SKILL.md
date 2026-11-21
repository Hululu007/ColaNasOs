---
name: colanas-release
description: 用于 ColaNasOs 发版、本地 Git 功能提交、GitCode 默认推送、Release 创建与附件上传校验。仅当用户明确要求时才推 GitHub；否则绝不主动 push origin。当需要发布新版本、上传安装包/APK 到 Release、复用 1.3.14/1.3.15 发版流程，或处理 GitCode 附件 0 字节/同名上传失败时使用。其他 AI 编程工具可直接把本目录当作发版 playbook，脚本仅依赖 Python 3 标准库。
agent_created: true
---

# ColaNasOs 发版与双平台发布

## Overview

把一次 ColaNasOs 发版固化为可复现流程：版本号同步 → 产物构建与验收 → 本地按功能提交 → **默认只 push GitCode + tag** → GitCode Release → 附件上传与强校验。GitHub 属于显式例外，只有用户明确说「推 GitHub」时才执行。脚本只依赖 Python 3 标准库，WorkBuddy、Claude Code、Cursor、Copilot 等能读仓库文件的工具都可使用。

## When to use

- 用户说「发版 / 发布版本 / Release / 上传附件 / 提交到 GitCode」。
- 用户明确说「也推 GitHub / GitHub 也发」时，才额外执行 GitHub 步骤。
- 需要复用 1.3.14 那套服务端、PC 客户端、安卓手机 APK、安卓 TV APK 的发布方式。
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

## Workflow decision tree

| 场景 | 执行 |
| --- | --- |
| 完整发版（默认） | Phase 0 → 1 → 2 → 3 → 4 → 6 → 7 |
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

## Phase 3：构建四类产物

按顺序执行；每步失败就停，不要带着半成品继续。

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
- Release 已存在时脚本只复用，不更新描述。要改描述用
  `PATCH /api/v5/repos/{owner}/{repo}/releases/{tag}`，body 至少带 `name` 和 `body`
  （可选 `release_status=latest`）。追加产物后应同步改描述，避免说明与附件矛盾。

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
3. 每个附件的名称、大小、sha256 和验证结果。
4. 上传后是否仍有旧的 0 字节附件；若有，列出名称和网页清理地址。
5. 任何未自动完成的步骤（网页删除、官网同步等）。

## Scripts

| 脚本 | 用途 |
| --- | --- |
| `scripts/github_release.py` | 仅显式要求 GitHub 时使用：Release 创建、附件上传、size 校验、verify-only |
| `scripts/gitcode_release.py` | 默认使用：GitCode Release 创建、官方预签名两步上传、空附件处理、size/digest 强校验 |

## References

- `references/release-playbook.md`：1.3.14 实战命令串、验收清单、提交拆分口径。
- `references/gitcode-attachments.md`：GitCode 预签名上传 API 细节、0 字节根因、`gitcode-cli` 假成功证据、清理接口。
