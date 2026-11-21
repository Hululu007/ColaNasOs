#!/usr/bin/env python
"""更新已存在 Release 的标题 / 正文（Markdown）/ 最新标记。

附件上传走 gitcode_release.py；这个脚本只负责「页面上写什么」。
正文用 make_release_notes.py 生成后再喂进来：

    python make_release_notes.py --version 1.3.19 ... --out body.md
    python patch_release.py --tag v1.3.19 --name "ColaNasOs 1.3.19" --body-file body.md --latest

注意：正文（body）里的 `<details>` 折叠是 GitCode 支持的（官方 Markdown 文档有
Details and summary 一节）；但附件区（assets）无法排序 / 折叠 / 自定义链接，
顺序由平台决定 —— 想突出全量包只能靠正文的下载表。
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gitcode_release as G  # noqa: E402


def main() -> None:
    ap = argparse.ArgumentParser(description="更新 Release 标题与正文")
    ap.add_argument("--repo", default="cocacola23/ColaNasOs")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--name", default="", help="标题，留空则不改")
    ap.add_argument("--body-file", default="", help="正文 Markdown 文件")
    ap.add_argument("--latest", action="store_true", help="标记为最新版")
    ap.add_argument("--proxy", default="", help="HTTP 代理，留空直连")
    args = ap.parse_args()

    token = G.load_token()
    if not token:
        raise SystemExit("没有 GITCODE_TOKEN（环境变量或 .workbuddy/.env）")

    body = Path(args.body_file).read_text(encoding="utf-8") if args.body_file else ""
    payload: dict[str, object] = {"tag_name": args.tag}
    if args.name:
        payload["name"] = args.name
    if body:
        payload["body"] = body
    if args.latest:
        payload["release_status"] = "latest"

    opener = G.build_opener(args.proxy)
    info = G.api(
        opener, token, "PATCH", f"/repos/{args.repo}/releases/{args.tag}", payload
    )
    print(
        f"[ok] {args.tag} name={info.get('name')} status={info.get('release_status')} "
        f"body={len(info.get('body') or '')} 字符"
    )


if __name__ == "__main__":
    main()
