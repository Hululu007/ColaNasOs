#!/usr/bin/env python3
"""创建/复用 GitHub Release 并上传附件（凭据优先从 git credential 读取）。

用法：
  python github_release.py --repo colaKot/ColaNasOs --tag v1.3.14 \
      --dist dist_installer --files "ColaNasOs-Server-1.3.14-Setup.exe,..." \
      [--proxy http://127.0.0.1:21578] [--notes "发行说明"] [--notes-file RELEASE.md]

行为：
  - Release 已存在则复用；附件已存在且 size 正常则跳过（幂等）。
  - 大附件走本机代理（直连 GitHub 上传 500 MB 级文件会卡死）。
  - 上传后逐个核对 size / browser_download_url；失败时非零退出。
"""
import argparse
import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.github.com"


def get_token():
    """优先用环境变量；否则从 git credential manager 读 PAT（不落盘、不打印）。"""
    env = os.environ.get("GITHUB_TOKEN", "")
    if env:
        return env
    p = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True, timeout=15,
    )
    cred = dict(l.split("=", 1) for l in p.stdout.strip().splitlines() if "=" in l)
    token = cred.get("password", "")
    if not token:
        sys.exit("未找到 GitHub 凭据：设置 GITHUB_TOKEN，或先 git clone 一次 HTTPS 仓库")
    return token


def build_opener(proxy):
    handler = urllib.request.ProxyHandler({"http": proxy, "https": proxy}) if proxy else urllib.request.ProxyHandler({})
    return urllib.request.build_opener(handler)


def api(opener, token, method, path, body=None):
    headers = {
        "Authorization": "Bearer " + token,
        "User-Agent": "colanas-release",
        "Accept": "application/vnd.github+json",
    }
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    with opener.open(req, timeout=60) as r:
        raw = r.read()
        return json.loads(raw) if raw else None


def asset_map(opener, token, owner, repo, release_id):
    return {a["name"]: a for a in api(
        opener, token, "GET", f"/repos/{owner}/{repo}/releases/{release_id}/assets") or []}


def verify(opener, token, owner, repo, release_id, expected):
    """expected: 附件名 -> 本地路径。"""
    assets = asset_map(opener, token, owner, repo, release_id)
    ok = True
    for name, local in expected.items():
        a = assets.get(name)
        if not a:
            print(f"[FAIL] 未找到附件 {name}", flush=True)
            ok = False
            continue
        size_ok = a.get("size") == os.path.getsize(local)
        flag = "OK" if size_ok else "FAIL"
        print(f"[{flag}] {name}\tsize={a.get('size')}\t{a.get('browser_download_url', '')}", flush=True)
        if not size_ok:
            ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/repo，如 colaKot/ColaNasOs")
    ap.add_argument("--tag", required=True, help="如 v1.3.14")
    ap.add_argument("--dist", default="dist_installer")
    ap.add_argument("--files", required=True, help="逗号分隔的文件名列表")
    ap.add_argument("--proxy", default="http://127.0.0.1:21578", help="传空字符串可禁用代理")
    ap.add_argument("--notes", default="")
    ap.add_argument("--notes-file", default="")
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--pre", action="store_true")
    args = ap.parse_args()

    notes = args.notes
    if args.notes_file:
        with open(args.notes_file, "r", encoding="utf-8") as f:
            notes = f.read()

    token = get_token()
    opener = build_opener(args.proxy)
    owner, repo = args.repo.split("/", 1)

    releases = api(opener, token, "GET", f"/repos/{owner}/{repo}/releases") or []
    release = next((r for r in releases if r["tag_name"] == args.tag), None)
    if release is None and not args.verify_only:
        release = api(opener, token, "POST", f"/repos/{owner}/{repo}/releases", {
            "tag_name": args.tag,
            "name": args.tag,
            "body": notes or f"Release {args.tag}",
            "draft": False,
            "prerelease": args.pre,
        })
        print("[i] Release 已创建:", release["html_url"], flush=True)
    elif release:
        print("[i] 复用已有 Release:", release["html_url"], flush=True)
    else:
        sys.exit(f"[FAIL] Release {args.tag} 不存在（--verify-only 不会创建）")

    release_id = release["id"]
    existing = asset_map(opener, token, owner, repo, release_id)
    print("[i] 已有附件:", sorted(existing), flush=True)

    expected = {}
    for name in [f.strip() for f in args.files.split(",") if f.strip()]:
        path = os.path.join(args.dist, name)
        if not os.path.exists(path):
            print(f"[SKIP] 本地不存在 {name}", flush=True)
            continue
        expected[name] = path
        a = existing.get(name)
        if a and a.get("size") == os.path.getsize(path):
            print(f"[SKIP] 附件已存在且大小一致 {name}", flush=True)
            continue
        if a:
            print(f"[WARN] 同名附件大小不一致，将尝试重传 {name}", flush=True)
            continue
        size = os.path.getsize(path)
        url = (f"https://uploads.github.com/repos/{owner}/{repo}/releases/"
               f"{release_id}/assets?name={urllib.parse.quote(name)}")
        print(f"[UP] {name} ({size / 1048576:.1f} MB) ...", flush=True)
        with open(path, "rb") as f:
            req = urllib.request.Request(
                url, data=f, method="POST",
                headers={
                    "Authorization": "Bearer " + token,
                    "User-Agent": "colanas-release",
                    "Accept": "application/vnd.github+json",
                    "Content-Type": "application/octet-stream",
                    "Content-Length": str(size),
                },
            )
            try:
                with opener.open(req, timeout=900) as r:
                    d = json.loads(r.read() or b"{}")
                    print(f"[OK] {name} -> {d.get('browser_download_url')}", flush=True)
            except Exception as e:
                print(f"[ERR] {name}: {str(e)[:300]}", flush=True)

    if args.verify_only:
        for name in list(expected):
            local = expected[name]
            if os.path.exists(local):
                continue
            expected.pop(name, None)

    ok = verify(opener, token, owner, repo, release_id, expected)
    print("[RESULT]", "全部通过" if ok else "存在失败，检查上方 FAIL 项", flush=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
