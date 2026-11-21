# 1.3.14 发版实战 playbook

本文件记录一条已经跑通的发版路径。SKILL.md 只保留流程骨架，这里放命令细节和踩坑证据。

## 1. 版本与同步

```bash
node tool/version.js --set=1.3.14
npm run version:check
npm run sbom
npm run sbom.check
```

`tool/version.js --set` 曾有一个坑：pubspec build 号 +1，但 `app_version.dart#kAppVersionCode` 写旧值，导致 `version:check` 报 `app_version.code=34≠35`。修复后 `--set` 内部使用 `setArg ? clientPub.pub.build + 1 : clientPub.pub.build`。遇到同类错误先检查这一行，不要手工把构建号再 +1。

## 2. 构建顺序

```bash
build-web.bat

export HTTP_PROXY=http://127.0.0.1:21578 HTTPS_PROXY=http://127.0.0.1:21578
export NO_PROXY=127.0.0.1,localhost
npm run dist
node tool/build-client-installer.js

# 安卓：不要直接跑 .bat（里面有 pause），用等价命令
cd apps/colanas_os
flutter build apk --release --target-platform android-arm64
cp build/app/outputs/flutter-apk/app-release.apk ../../dist_installer/ColaNasOs-Client-1.3.14-android-arm64.apk
flutter build apk --release --target-platform android-arm64 --target lib/main_tv.dart --dart-define=COLANAS_TV=1
cp build/app/outputs/flutter-apk/app-release.apk ../../dist_installer/ColaNasOs-Client-1.3.14-android-arm64-tv.apk
cd ../..

unset HTTP_PROXY HTTPS_PROXY http_proxy https_proxy
```

electron-builder 直连 GitHub 拉 Electron zip 会 `ETIMEDOUT 20.205.243.166:443`；必须先挂代理。跑完构建再 unset，避免后续 test / verify 走代理。

## 3. 验收

```bash
flutter analyze lib
npm run installer.check
npm run version:check
npm run sbom.check
```

1.3.14 实测 `installer.check` 35/35 通过。内容级验收：

- 服务端 asar：`dist/src/modules/auth`、`dist/electron/main.js`、`package.json` 版本 `1.3.14`。
- PC 客户端：Windows 目录里 `data/app.so` 存在；`ColaNasOs.exe` 只有约 196 KB，是启动壳。
- APK：`lib/arm64-v8a/libapp.so` 存在。手机包和 TV 包体积可能一样，必须比较 `libapp.so` 哈希。
- 中文串在 dart2js / AOT 产物里会被转义，不要用中文 grep 判断；用 route 串、仓库 URL 这类 ASCII 指纹。

## 4. 本地提交与默认只推 GitCode

按功能拆 commit，每次只显式 `git add` 该功能路径。不要用 `git add -A`：工作树长期有数百个在途文件。

```bash
git status --short
git add -- package.json apps/colanas_os/pubspec.yaml apps/colanas_os/lib/core/app_version.dart ...
git commit -F RELEASE_COMMIT_MSG.txt

git push gitcode main
git tag -a v1.3.14 -m "ColaNasOs 1.3.14"
git push gitcode v1.3.14
```

⛔ 用户没明确说「推 GitHub」时，不要执行 `git push origin main` 或 `git push origin v1.3.14`。`origin` 只是 GitHub 远端记录，不要替换。

`contracts/apps.json`、`contracts/messages/*.json` 常有用户未提交编辑，禁止 `git checkout --`。需要找回历史版本时可从 `apps/colanas_os/build/web/assets/assets/i18n/*.json` 这类历史快照对照，再逐行改回。

## 5. GitHub 附件上传（仅显式要求时）

13 分钟只上传了 550 MB 服务端附件，后续文件卡死；加 `http://127.0.0.1:21578` 后剩余 4 个附件 54 秒完成。脚本已默认使用该代理。默认发版不走这一节。

```bash
FILES="ColaNasOs-Server-1.3.14-Setup.exe,ColaNasOs-Client-1.3.14-Setup.exe,ColaNasOs-Client-1.3.14-windows-x64.zip,ColaNasOs-Client-1.3.14-android-arm64.apk,ColaNasOs-Client-1.3.14-android-arm64-tv.apk"

python .workbuddy/skills/colanas-release/scripts/github_release.py \
  --repo colaKot/ColaNasOs --tag v1.3.14 --dist dist_installer \
  --files "$FILES" --proxy http://127.0.0.1:21578 \
  --notes-file RELEASE_NOTES.md
```

脚本从 git credential manager 读 PAT。若其他工具环境读不到，设置 `GITHUB_TOKEN` 即可。

## 6. GitCode 附件上传

最终成功的附件名：

```text
ColaNasOs-Client-1.3.14-Setup-v2.exe
ColaNasOs-Server-1.3.14-Setup-v2.exe
ColaNasOs-Client-1.3.14-android-arm64-v2.apk
```

根因是 Release 里已经有同名 0 字节附件，后续同名 PUT 被当成「更新」，GitCode 回调失败，文件保持 0 字节。换新文件名后 `size` 和 `sha256` 与本地完全一致，下载返回正确 `Content-Length` 和 `MZ` 文件头。

```bash
# 本机已在 .workbuddy/.env 里保存 GITCODE_TOKEN，脚本会自动读取；没有时才需要手动 export
python .workbuddy/skills/colanas-release/scripts/gitcode_release.py \
  --repo cocacola23/ColaNasOs --tag v1.3.14 --dist dist_installer \
  --files "$FILES" --suffix -v2
```

脚本最终用 API 的 `size` / `digest` 判定成功；`gitcode-cli` 的 `✓`、`Done.` 都不是成功证据。曾出现 CLI 输出成功但 API 仍为 `size=0` 的情况。

## 7. 仍未自动完成的收尾

1.3.14 发布时遗留：

- GitCode Release 上旧的 5 个 0 字节附件需要网页手工删除。
- 临时 Release `v1.3.14-uploadtest` 需要网页手工删除。

新脚本提供 `--clean-empty`，可在用户明确确认后通过 API 删除空附件；默认仍使用 `-v2` 新文件名，避免误删。

## 8. 1.3.17 服务端全量 + 增量实战

客户端代码自 1.3.16 起没有改动，这版只发服务端；清单里保留 PC 1.3.15 与安卓/TV 1.3.16。

```bash
node tool/version.js --set=1.3.17
npm run version:check && npm run sbom && npm run sbom.check
build-web.bat
npm run dist                      # 挂 http://127.0.0.1:21578，非沙箱
flutter analyze lib
npm run verify:fast
npm run installer.check && npm run version:check && npm run sbom.check
node tool/release/release.js \
  --out=dist_release --tag=v1.3.17 \
  --url-base=https://gitcode.com/cocacola23/ColaNasOs/releases/download/v1.3.17 \
  --setup=dist_installer/ColaNasOs-Server-1.3.17-Setup.exe \
  --notes-zh="服务端全量与 1.3.16→1.3.17 增量" --manifest-out=release
git push gitcode main
git tag -a v1.3.17 -m "ColaNasOs 1.3.17" && git push gitcode v1.3.17
# 上传：全量 exe → dist_release/assets/* → update.json*（最后）
npm run smoke:update
```

结果：自动基线 `D10316`，变化 6 个文件，增量资产 5 个 / 1.30 MB，全量 577,569,173 B（SHA256 `421b4df2…18dd`）。`verify:fast` 26/26、`installer.check` 35/35、`smoke:update` 28/28；Release 9 个自有资产 size/digest 全匹配，下载直链 206，contents API 清单与签名可解码。

发完发现清单源 `@@` 拼接少一个斜杠会 404，补修后重建服务端、隔离目录重算增量与清单，删掉 Release 上旧资产后重传；最终包名未变，哈希以上面为准。

中途修了两条发版工具 lint：`no-useless-assignment`（基线探测初始值）与 `buildDelta` 的未使用 `id` 参数；都单独按功能提交。
