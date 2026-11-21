#!/usr/bin/env python
"""生成 GitCode / GitHub Release 的正文（Markdown），供 PATCH body 使用。

版面约定（用户 2026-11-21 定）：
  1. 最上面是「下载」表 —— 只有用户真正要装的全量包，按平台分行，点名字直接下；
  2. 本版改动写清楚，但别铺太长；
  3. 增量 / 清单 / 签名这些「客户端自己用」的东西，以及排障信息，
     全部塞进 `<details>` 折叠块，默认收起。

平台限制（实测）：Release 的附件区（assets）**不能排序、不能折叠、不支持自定义
链接资产**（v5 API 的 release 结构里没有 links 字段），顺序由平台决定。
所以「全量包放最上面」只能靠正文里的这张表，不要试图去调附件区。

用法：
    python make_release_notes.py --version 1.3.19 \
        --summary "修复装完 1.3.17/1.3.18 服务端起不来" \
        --changes-file .devdata/changes.md \
        --no-delta --min-shell 1.3.19 \
        --dist dist_installer > body.md

不传 --changes-file 时用 --changes 直接给多行文本。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO_URL = "https://gitcode.com/cocacola23/ColaNasOs/releases/download"

# (键, 显示名, 文件名模板)；文件名里 {v} 替换成版本号
PRODUCTS = [
    ("server", "**Windows 服务端**（NAS 主机，必装）", "ColaNasOs-Server-{v}-Setup.exe"),
    ("client_pc_setup", "**PC 客户端**（Windows 桌面，安装版）", "ColaNasOs-Client-{v}-Setup.exe"),
    ("client_pc_zip", "**PC 客户端**（便携 zip，免安装）", "ColaNasOs-Client-{v}-windows-x64.zip"),
    ("client_apk", "**安卓手机**", "ColaNasOs-Client-{v}-android-arm64.apk"),
    ("client_apk_tv", "**安卓 TV**", "ColaNasOs-Client-{v}-android-arm64-tv.apk"),
]


def human(n: int) -> str:
    return f"{n / 1048576:.1f} MB"


def find_asset(dist: Path, pattern: str, version: str) -> tuple[str, int] | None:
    name = pattern.format(v=version)
    p = dist / name
    if not p.exists():
        # 允许带 -v2 / 其它后缀的历史命名，按前缀找最长匹配
        stem = re.sub(r"\.(exe|zip|apk)$", "", name)
        cands = sorted(dist.glob(stem + "*"))
        if not cands:
            return None
        p = cands[0]
    return p.name, p.stat().st_size


def build(args: argparse.Namespace) -> str:
    dist = Path(args.dist)
    v, tag = args.version, args.tag or f"v{args.version}"
    base = f"{REPO_URL}/{tag}/"

    rows = []
    for _key, label, pattern in PRODUCTS:
        got = find_asset(dist, pattern, v)
        if not got:
            continue
        name, size = got
        rows.append(f"| {label} | [{name}]({base}{name}) | {human(size)} |")

    if args.changes_file:
        changes = Path(args.changes_file).read_text(encoding="utf-8").strip()
    else:
        changes = (args.changes or "").strip()

    delta_note = (
        "本次是 `--no-delta`（只发全量），所以没有 `smallfiles-*.brb` / "
        "`*-main.dart.js.br` 这类增量资产。"
        if args.no_delta
        else "本次含服务的增量资产（`smallfiles-*.brb` / `*-main.dart.js.br`），大小见上表之外的附件。"
    )

    min_shell = ""
    if args.min_shell:
        min_shell = (
            "> ⚠️ 这条修复在**外壳**里（编进 `app.asar`），增量包换不掉 —— "
            "**必须下载全量安装包**。"
            f"清单已把 `minShell` 提到 {args.min_shell}，旧外壳会被强制走全量。"
        )

    parts = [f"## ColaNasOs {v}"]
    if args.summary:
        parts += ["", args.summary.strip()]
    parts += [
        "",
        "---",
        "",
        "## ⬇️ 下载",
        "",
        "| 装在哪 | 下载 | 大小 |",
        "| --- | --- | --- |",
        *rows,
    ]
    if args.download_note:
        parts += ["", f"> {args.download_note.strip()}"]
    if changes:
        parts += ["", "---", "", "## 本版改动", "", changes]
    if min_shell:
        parts += ["", min_shell]

    parts += [
        "",
        "<details>",
        "<summary>🔧 自动更新资产（增量 / 清单 / 签名，普通用户不用管）</summary>",
        "",
        "下面这些是客户端「检查更新」自动用的，不需要手动下载：",
        "",
        "| 文件 | 用途 |",
        "| --- | --- |",
        "| `update.json` + `.sig` / `.sig.json` | 更新清单与 Ed25519 签名，客户端据此判断有没有新版 |",
        "| `manifest-D*.json` + `.sig` | 版本目录文件清单与签名，装完校验完整性 |",
        "",
        delta_note,
        "",
        "</details>",
        "",
        "<details>",
        "<summary>🧰 装完怎么验 / 出问题看哪</summary>",
        "",
        "- 服务端探活：`http://127.0.0.1:7788/health` 返回 200",
        "- 外壳日志（依赖摊平 / 版本播种 / 回滚）：`%APPDATA%\\colanas_os_server\\logs\\shell.log`",
        "- 内核日志：同目录 `kernel.log`、`kernel-console.log`",
        "- 安卓提示「应用未安装」：同 `applicationId`（`com.colanas.os`），先卸旧版再装",
        "- 托盘退出再启动，可让改动生效",
        "",
        "</details>",
    ]
    return "\n".join(parts).rstrip() + "\n"


def main() -> None:
    ap = argparse.ArgumentParser(description="生成 Release 正文（下载表 + 折叠资产说明）")
    ap.add_argument("--version", required=True, help="版本号，例如 1.3.19")
    ap.add_argument("--tag", default="", help="标签，默认 v<version>")
    ap.add_argument("--summary", default="", help="一句话摘要，放在最上面")
    ap.add_argument("--changes", default="", help="本版改动（多行）")
    ap.add_argument("--changes-file", default="", help="本版改动从文件读")
    ap.add_argument("--download-note", default="", help="下载表下面的一句提示")
    ap.add_argument("--no-delta", action="store_true", help="本次只发全量，折叠块里会写明")
    ap.add_argument("--min-shell", default="", help="清单 minShell，给了会加一句强制全量的提醒")
    ap.add_argument("--dist", default="dist_installer", help="产物目录")
    ap.add_argument("--out", default="", help="写到文件；默认 stdout")
    args = ap.parse_args()

    text = build(args)
    if args.out:
        Path(args.out).write_text(text, encoding="utf-8")
        print(f"[ok] 已写入 {args.out}（{len(text)} 字符）", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    import sys

    main()
