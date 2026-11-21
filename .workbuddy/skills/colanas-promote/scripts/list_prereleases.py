#!/usr/bin/env python
"""列出 ColaNasOs 的 Release，标出哪些预发布可以清理。

GitCode 的 `DELETE /repos/{repo}/releases/{tag}` 返 405（平台不支持删 Release），
所以清理只能网页手工做。这个脚本负责把「该删哪些」算清楚，避免误删。

分类规则：
  KEEP        当前正式清单里的版本，或标记为 latest —— 不能删
  SUPERSEDED  版本号低于当前正式版，且状态仍是 pre —— 可以删
  ORPHAN      没有附件、也不在正式清单里 —— 可以删
  CURRENT     本次要转正的那个 tag（正常流程里它会被 KEEP 覆盖）

用法：
    python list_prereleases.py --repo cocacola23/ColaNasOs
    python list_prereleases.py --repo cocacola23/ColaNasOs --mark-superseded
    python list_prereleases.py --repo cocacola23/ColaNasOs --json
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "colanas-release" / "scripts"))
import gitcode_release as G  # noqa: E402


def parse_semver(tag: str) -> tuple[int, int, int] | None:
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", tag or "")
    if not m:
        return None
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


# tag 里带这些词的基本都是发版自检 / 试上传留下的
TEST_TAG = re.compile(r"(test|tmp|probe|check|try|demo|draft)", re.I)


def list_releases(opener, token: str, repo: str) -> list[dict]:
    out: list[dict] = []
    page = 1
    while page <= 10:
        batch = G.api(opener, token, "GET", f"/repos/{repo}/releases?per_page=100&page={page}")
        if not isinstance(batch, list) or not batch:
            break
        out.extend(batch)
        if len(batch) < 100:
            break
        page += 1
    return out


def stable_semver() -> tuple[int, int, int] | None:
    """本地 release/update.json 里的服务端版本（没有就返回 None）。"""
    p = Path("release/update.json")
    if not p.exists():
        return None
    try:
        j = json.loads(p.read_text(encoding="utf-8"))
        return parse_semver(str(j.get("components", {}).get("server", {}).get("semver", "")))
    except Exception:
        return None


def main() -> None:
    ap = argparse.ArgumentParser(description="列出预发布 Release 并标注清理建议")
    ap.add_argument("--repo", default="cocacola23/ColaNasOs")
    ap.add_argument("--proxy", default="", help="HTTP 代理，留空直连")
    ap.add_argument("--json", action="store_true", help="输出 JSON")
    ap.add_argument("--mark-superseded", action="store_true", help="额外标出低于当前正式版但仍为 pre 的条目")
    ap.add_argument(
        "--older-than-stable",
        action="store_true",
        help="连历史正式版一起标为可删（OLD）：只在你确定不再需要回退下载旧版时用",
    )
    args = ap.parse_args()

    token = G.load_token()
    if not token:
        raise SystemExit("没有 GITCODE_TOKEN（环境变量或 .workbuddy/.env）")

    opener = G.build_opener(args.proxy)
    releases = list_releases(opener, token, args.repo)
    stable = stable_semver()

    rows = []
    for r in releases:
        tag = str(r.get("tag_name") or "")
        status = str(r.get("release_status") or "none")
        assets = r.get("assets") or []
        sized = [a for a in assets if a.get("size")]
        ver = parse_semver(tag)

        if TEST_TAG.search(tag):
            verdict, why = "ORPHAN", "tag 名像发版自检 / 试上传"
        elif status == "latest":
            verdict, why = "KEEP", "状态是 latest"
        elif stable and ver and ver == stable:
            verdict, why = "KEEP", "与正式清单同版本"
        elif not sized:
            verdict, why = "ORPHAN", "没有附件"
        elif args.mark_superseded and status == "pre" and stable and ver and ver < stable:
            verdict, why = "SUPERSEDED", f"低于正式版 {'.'.join(map(str, stable))}"
        elif status == "pre":
            verdict, why = "PRE", "预发布（未转正）"
        elif args.older_than_stable and stable and ver and ver < stable:
            verdict, why = "OLD", f"历史正式版（低于 {'.'.join(map(str, stable))}）"
        else:
            verdict, why = "KEEP", f"历史正式版（状态 {status}）"

        rows.append(
            {
                "tag": tag,
                "status": status,
                "assets": len(sized),
                "bytes": sum(int(a.get("size") or 0) for a in sized),
                "verdict": verdict,
                "why": why,
            }
        )

    rows.sort(key=lambda x: (parse_semver(x["tag"]) or (0, 0, 0)), reverse=True)

    if args.json:
        print(json.dumps({"stable": stable, "releases": rows}, ensure_ascii=False, indent=2))
        return

    print(f"仓库 {args.repo}｜正式清单版本 {'.'.join(map(str, stable)) if stable else '未知'}｜共 {len(rows)} 个 Release")
    print(f"{'tag':<22}{'状态':<10}{'附件':>4}{'大小':>10}  建议")
    for r in rows:
        size = f"{r['bytes'] / 1048576:.1f} MB" if r["bytes"] else "-"
        print(f"{r['tag']:<22}{r['status']:<10}{r['assets']:>4}{size:>10}  {r['verdict']}  {r['why']}")

    deletable = [r["tag"] for r in rows if r["verdict"] in ("SUPERSEDED", "ORPHAN", "OLD")]
    print()
    if deletable:
        print("可清理（只能网页手工删）：")
        for t in deletable:
            print(f"  - {t}")
        print("  → https://gitcode.com/cocacola23/ColaNasOs/releases 找到 tag → 编辑 → 删除")
    else:
        print("没有需要清理的 Release。")


if __name__ == "__main__":
    main()
