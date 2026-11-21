---
name: colanas-promote
description: 用于 ColaNasOs「把预发布版转成正式版」：同一个 tag 原地转正（补正式通道 update.json、补全量包、Release 状态改 latest），以及列出/清理历史遗留的预发布 Release。当用户说「发正式版」「转正」「promote」「把预发布转成正式」「清理旧预发布」「Release 太多了」时使用。GitCode 不支持删除 Release（DELETE 返 405），所以清理只能网页手工做，本 Skill 负责生成要删的清单。其他 AI 编程工具可直接把本目录当作 playbook，脚本仅依赖 Python 3 标准库。
agent_created: true
---

# ColaNasOs 正式版转正与旧预发布清理

## Overview

开发期一律发**预发布**（`release_status=pre`、清单 `release/update-pre.json`）。本 Skill 管两件事：

1. **转正**：把某个已发布的预发布版本变成正式版 —— 同一个 tag、同一个 Release，补上正式通道清单与全量包，状态从 `pre` 改成 `latest`。**不新建 Release**。
2. **清理**：列出所有仍是预发布状态的 Release，标出哪些可以删，交用户在网页上手工删（API 删不了）。

发预发布本身不在这里，走 `colanas-release` Skill 的 `--pre` 流程。

## When to use

- 用户说「发正式版 / 转正 / promote / 这个版本可以发了」
- 用户说「清理旧预发布 / Release 太多了 / 把测试版删掉」
- 用户问「哪些 Release 还是预发布」

## Non-negotiable guardrails

1. **同一个 tag，不新建 Release**：预发布阶段已经建过 `vX.Y.Z` 的 Release，转正就改它，不要建 `vX.Y.Z-final` 之类的新条目 —— 那正是「Release 堆积」的来源。
2. **GitCode 不能删 Release**：`DELETE /repos/{repo}/releases/{tag}` 返 **405 METHOD_NOT_ALLOWED**。脚本里不要写自动删除逻辑，也不要指望 `gitcode-cli release delete`（同样是坏的）。删除只能在网页上做。
3. **不 force push tag**：转正不改 tag 指向。GitCode 在创建 Release 时会自动打 tag，本地再 push 同名 tag 会被拒 —— 这是正常的，不要 `-f`。
4. **正式清单是所有人的默认**：`release/update.json` 一旦变更，所有没勾「接收预发布」的设备都会看到这版。转正前必须确认产物齐全（服务端全量 + 该版本要发的客户端）。
5. **增量先于清单上传**：先传安装包与增量资产，`update.json` 三件套最后传，避免「清单先到、包没传完」的 404。
6. **转正后立刻回读**：GitCode contents API 取 `release/update.json` 与 `.sig.json`，确认匿名可解码、`channel` 是 `stable`、`semver` 是本次版本。

## 前置检查

```bash
# 1) 这次要转正的版本
node -e "console.log(require('./package.json').version)"     # 例如 1.3.20

# 2) 确认 Release 当前是预发布
python .workbuddy/skills/colanas-promote/scripts/list_prereleases.py --repo cocacola23/ColaNasOs

# 3) 产物齐不齐（服务端全量包必须有；客户端按本轮是否重打决定）
ls -l dist_installer/ | grep -E "1\.3\.20"
```

## Phase 1：生成正式通道清单

和预发布唯一的区别就是**不带 `--pre`**（清单写 `release/update.json`，`channel: "stable"`）：

```bash
node tool/release/release.js \
  --out=dist_release --tag=v<version> \
  --url-base=https://gitcode.com/cocacola23/ColaNasOs/releases/download/v<version> \
  --setup=dist_installer/ColaNasOs-Server-<version>-Setup.exe \
  --notes-zh="<正式版说明>" --manifest-out=release
```

- 不传 `--from` 会自动拿 `dist_release` 里最新旧版本目录做增量基线；找不到基线会直接失败（要只发全量就显式 `--no-delta`，并在提交信息里写明原因）。
- 预发布阶段如果已经用同一个 `dist_release` 生成过版本目录，这里会复用同一个 `D<NNN>`（内容相同）。
- **补客户端组件**：只发服务端时会话会把 `components.client_pc` / `client_android` 整个抹掉，
  必须从上一版清单回填并重新签名（脚本见 `colanas-release/references/incremental-release.md` 的
  「只发服务端时回填客户端组件」一段）。

## Phase 2：上传到同一个 Release

```bash
PY=C:/Users/cola/.workbuddy/binaries/python/versions/3.13.12/python.exe
S=.workbuddy/skills/colanas-release/scripts/gitcode_release.py

# 全量包（若预发布阶段已传过且字节未变，脚本会跳过）
$PY $S --repo cocacola23/ColaNasOs --tag v<version> --dist dist_installer \
  --files "ColaNasOs-Server-<version>-Setup.exe" --proxy ""

# 增量资产（有 delta 时）
$PY $S --repo cocacola23/ColaNasOs --tag v<version> --dist dist_release/assets \
  --files "$(ls dist_release/assets | tr '\n' ',' | sed 's/,$//')" --proxy ""

# 正式清单最后传
$PY $S --repo cocacola23/ColaNasOs --tag v<version> --dist dist_release \
  --files "update.json,update.json.sig,update.json.sig.json" --proxy ""
```

⚠️ **同名附件不能直接覆盖**：Release 上已有同名文件时先按 API 删附件再传：

```bash
DELETE /repos/{repo}/releases/{tag}/attach_files/{id}
```

id 从 `release_info()` 的 `assets` 里取（`scripts/gitcode_release.py --verify-only` 打印）。

## Phase 3：状态转正 + 改正文

```bash
$PY .workbuddy/skills/colanas-release/scripts/make_release_notes.py \
  --version <version> --summary "<正式版一句话>" --changes-file changes.md \
  --min-shell <version> --out body.md

$PY .workbuddy/skills/colanas-release/scripts/patch_release.py \
  --tag v<version> --name "ColaNasOs <version>" --body-file body.md --latest
```

`--latest` 会把 `release_status` 从 `pre` 改成 `latest`，页面上的「预发布」标记随之消失 —— 这就是「转正」，没有任何删除动作。

## Phase 4：提交与推送

```bash
git add release/update.json release/update.json.sig release/update.json.sig.json
git commit -m "release: <version> 转正式版（update.json + latest）"
git push gitcode main        # 默认只推 GitCode
```

## Phase 5：清理旧预发布

**先列清单**（默认把「有正式版在用同名 tag」的条目也标出来，避免误删）：

```bash
$PY .workbuddy/skills/colanas-promote/scripts/list_prereleases.py \
  --repo cocacola23/ColaNasOs --mark-superseded
```

输出三列：`tag / 附件数 / 建议`：

- `KEEP` —— 当前 latest 或与正式清单同版本，不能删
- `SUPERSEDED` —— 版本低于当前正式版、且状态仍是 pre：**可以删**
- `ORPHAN` —— 没有附件、也不在清单里：可以删

**删除只能在网页做**（API 405）：`https://gitcode.com/cocacola23/ColaNasOs/releases` → 找到 tag → 右上角「编辑」→ 底部「删除」。删的时候注意：

- 只删 Release，**不要删 tag**（tag 可能被清单或历史引用）
- 顺序上从旧到新删，避免误删当前版
- 网页删完后回到 `list_prereleases.py` 复跑确认数量下降

## 附：转正后的自检清单

- [ ] `release/update.json` 的 `channel` 是 `stable`，`components.server.semver` 是本次版本
- [ ] `components.client_pc` / `client_android` 还在（没被抹掉）
- [ ] GitCode Release 状态是 `latest`（`patch_release.py` 输出的 `status=latest`）
- [ ] 所有 `urls[]` 用 `curl -r 0-15` 返回 206
- [ ] contents API 的 `update.json` 与 `.sig.json` 匿名可解码
- [ ] 服务端（或客户端）设置里的「接收预发布版」关掉后，检查更新拿到的是这版

## Scripts

| 脚本 | 用途 |
| --- | --- |
| `scripts/list_prereleases.py` | 列出所有预发布 Release，标注 KEEP / SUPERSEDED / ORPHAN |
| `../colanas-release/scripts/gitcode_release.py` | 上传附件、复用 Release、size/digest 强校验（`--verify-only` 只校验） |
| `../colanas-release/scripts/make_release_notes.py` | 生成正式版正文（下载表 + 折叠资产说明） |
| `../colanas-release/scripts/patch_release.py` | 改标题 / 正文 / `release_status=latest`（转正那一步） |
