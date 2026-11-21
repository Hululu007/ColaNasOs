#!/usr/bin/env python3
"""创建/复用 GitCode Release，上传附件并强制验证 size/digest。

默认用 GitCode 官方「预签名 URL 两步上传」：
  1. GET  /api/v5/repos/{owner}/{repo}/releases/{tag}/upload_url?file_name=...
  2. PUT  上一步返回的 url，带返回的 headers

两个已踩过的坑：
  1. Release 里若已有同名 0 字节附件，同名重传会被当成「更新」而失败，文件仍是 0 字节。
     默认改用 -v2 新文件名；显式 --clean-empty 可先删掉空附件再传原名。
  2. gitcode-cli 的 `release upload` 只看 PUT 状态码 <400 就报 ✓，203 + 回调失败也当成功。
     因此无论用哪种上传方式，最后都必须查 API 的 size / digest。

用法：
  export GITCODE_TOKEN=<PAT>
  python gitcode_release.py --repo cocacola23/ColaNasOs --tag v1.3.14 \
      --dist dist_installer --files "file1.exe,file2.apk" \
      [--notes "发行说明" | --notes-file RELEASE.md] [--suffix=-v2] [--clean-empty] \
      [--uploader presigned|cli|none] [--verify-only] [--proxy http://127.0.0.1:21578]
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.gitcode.com/api/v5"
EMPTY_SHA = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


class ApiError(RuntimeError):
    pass


def load_token():
    """优先读环境变量；否则读仓库 .workbuddy/.env（不打印 token）。"""
    token = os.environ.get("GITCODE_TOKEN", "")
    if token:
        return token
    env_path = Path(__file__).resolve().parents[4] / ".workbuddy" / ".env"
    if not env_path.exists():
        return ""
    for line in env_path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        if key.strip() == "GITCODE_TOKEN":
            return value.strip().strip('"').strip("'")
    return ""


def build_opener(proxy):
    handler = urllib.request.ProxyHandler({"http": proxy, "https": proxy}) if proxy else urllib.request.ProxyHandler({})
    return urllib.request.build_opener(handler)


def api(opener, token, method, path, body=None, allow_404=False):
    """调用 GitCode v5 API。token 只放 query 和请求头，不出现在日志里。"""
    display = path
    joiner = "&" if "?" in path else "?"
    path = f"{path}{joiner}access_token={urllib.parse.quote(token)}"
    headers = {
        "Accept": "application/json",
        "User-Agent": "colanas-release",
        "Authorization": "Bearer " + token,
    }
    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json; charset=utf-8"
    req = urllib.request.Request(API + path, data=data, method=method, headers=headers)
    try:
        with opener.open(req, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        if allow_404 and e.code == 404:
            return None
        detail = e.read().decode("utf-8", "replace")[:300]
        raise ApiError(f"{method} {display} -> HTTP {e.code}: {detail}") from e


def release_info(opener, token, repo, tag, allow_404=True):
    return api(
        opener, token, "GET",
        f"/repos/{repo}/releases/tags/{urllib.parse.quote(tag, safe='')}",
        allow_404=allow_404,
    )


def ensure_release(opener, token, repo, tag, notes, prerelease):
    info = release_info(opener, token, repo, tag)
    if info:
        print("[i] 复用已有 Release:", info.get("tag_name", tag), flush=True)
        return info
    body = {
        "tag_name": tag,
        "name": tag,
        "body": notes or f"Release {tag}",
        "release_status": "pre" if prerelease else "latest",
    }
    info = api(opener, token, "POST", f"/repos/{repo}/releases", body=body)
    print("[i] Release 已创建:", info.get("tag_name", tag), flush=True)
    return info


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def asset_map(info):
    return {a["name"]: a for a in (info or {}).get("assets", []) if a.get("name")}


def is_empty_asset(a):
    digest = (a.get("digest") or a.get("sha256") or "").removeprefix("sha256:")
    size = a.get("size")
    # 源码包等自动资产可能没有 size 字段，不能当成 0 字节附件。
    if size is None and not digest:
        return False
    return (size or 0) == 0 or digest == EMPTY_SHA


def suffix_name(name, suffix):
    stem, ext = os.path.splitext(name)
    return f"{stem}{suffix}{ext}"


def delete_empty_assets(opener, token, repo, tag, assets, names):
    for name in names:
        a = assets.get(name)
        if not a or not is_empty_asset(a):
            continue
        attach_id = a.get("id") or a.get("attach_file_id") or a.get("attachment_id")
        if not attach_id:
            print(f"[WARN] {name} 是空附件但 API 未返回 id，需在网页手工删除", flush=True)
            continue
        api(
            opener, token, "DELETE",
            f"/repos/{repo}/releases/{urllib.parse.quote(tag, safe='')}/attach_files/"
            f"{urllib.parse.quote(str(attach_id), safe='')}",
        )
        print(f"[DEL] 已删除空附件 {name}", flush=True)


def presigned_upload(opener, token, repo, tag, name, path):
    """官方两步上传。返回是否至少拿到了 2xx；最终成功仍以 verify() 为准。"""
    qs = urllib.parse.urlencode({"file_name": name})
    info = api(
        opener, token, "GET",
        f"/repos/{repo}/releases/{urllib.parse.quote(tag, safe='')}/upload_url?{qs}",
    )
    url = info.get("url")
    if not url:
        raise ApiError("upload_url 响应缺少 url")
    headers = {str(k): str(v) for k, v in (info.get("headers") or {}).items()}
    headers["Content-Length"] = str(os.path.getsize(path))
    print(f"[PUT] {name} ({os.path.getsize(path) / 1048576:.1f} MB)", flush=True)
    with open(path, "rb") as f:
        req = urllib.request.Request(url, data=f, method="PUT", headers=headers)
        try:
            with opener.open(req, timeout=900) as r:
                body = r.read(300).decode("utf-8", "replace").strip()
                print(f"[PUT] {name} HTTP {r.status} {body[:160]}", flush=True)
                return True
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")[:200]
            print(f"[ERR] PUT {name} HTTP {e.code}: {body}", flush=True)
            return False


def run_cli_upload(repo, tag, paths):
    cmd = ["npx", "-y", "gitcode-cli@latest", "release", "upload", tag] + paths + ["-R", repo]
    print("[cli]", " ".join(cmd), flush=True)
    r = subprocess_run(cmd)
    if r != 0:
        print(f"[WARN] gitcode-cli 退出码 {r}（仍以 API 验证为准）", flush=True)


def subprocess_run(cmd):
    import subprocess
    return subprocess.run(cmd, timeout=900).returncode


def verify(opener, token, repo, tag, expected):
    """expected: 附件名 -> (本地路径, 本地 sha256)。"""
    assets = asset_map(release_info(opener, token, repo, tag))
    ok = True
    for name, (local_path, want_sha) in expected.items():
        a = assets.get(name)
        if not a:
            print(f"[FAIL] 未找到附件 {name}", flush=True)
            ok = False
            continue
        size_ok = (a.get("size") or 0) == os.path.getsize(local_path)
        digest = (a.get("digest") or a.get("sha256") or "").removeprefix("sha256:")
        if digest:
            sha_ok = digest == want_sha
            sha_text = "match" if sha_ok else digest[:16]
        else:
            sha_ok = True
            sha_text = "unverified"
        flag = "OK" if size_ok and sha_ok else "FAIL"
        print(f"[{flag}] {name}\tsize={a.get('size')}\tsha={sha_text}", flush=True)
        if flag == "FAIL":
            ok = False
    return ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, help="owner/repo，如 cocacola23/ColaNasOs")
    ap.add_argument("--tag", required=True, help="如 v1.3.14")
    ap.add_argument("--dist", default="dist_installer")
    ap.add_argument("--files", required=True, help="逗号分隔的原始文件名")
    ap.add_argument("--notes", default="")
    ap.add_argument("--notes-file", default="", help="从文件读取发行说明（覆盖 --notes）")
    ap.add_argument("--pre", action="store_true", help="创建 Release 时标记为预发布")
    ap.add_argument("--suffix", default="-v2", help="同名空附件时插入到扩展名前的后缀")
    ap.add_argument("--clean-empty", action="store_true", help="先删除同名 0 字节附件，再用原文件名上传")
    ap.add_argument("--uploader", choices=["presigned", "cli", "none"], default="presigned")
    ap.add_argument("--verify-only", action="store_true")
    ap.add_argument("--proxy", default="http://127.0.0.1:21578", help="传空字符串可禁用代理")
    args = ap.parse_args()

    notes = args.notes
    if args.notes_file:
        with open(args.notes_file, "r", encoding="utf-8") as f:
            notes = f.read()

    token = load_token()
    if not token:
        sys.exit("需要 GITCODE_TOKEN 环境变量，或仓库 .workbuddy/.env 中的 GITCODE_TOKEN")

    names = [f.strip() for f in args.files.split(",") if f.strip()]
    opener = build_opener(args.proxy)

    if args.verify_only:
        expected = {}
        for name in names:
            local = os.path.join(args.dist, name)
            if os.path.exists(local):
                expected[name] = (local, sha256(local))
        ok = verify(opener, token, args.repo, args.tag, expected)
        print("[RESULT]", "全部通过" if ok else "存在失败，检查上方 FAIL 项", flush=True)
        sys.exit(0 if ok else 1)

    ensure_release(opener, token, args.repo, args.tag, notes, args.pre)
    assets = asset_map(release_info(opener, token, args.repo, args.tag))
    empty_names = {n for n, a in assets.items() if is_empty_asset(a)}
    print("[i] 已有空附件:", sorted(empty_names), flush=True)

    if args.clean_empty:
        delete_empty_assets(opener, token, args.repo, args.tag, assets, names)
        assets = asset_map(release_info(opener, token, args.repo, args.tag))
        empty_names = {n for n, a in assets.items() if is_empty_asset(a)}

    expected = {}
    uploads = []
    for name in names:
        local = os.path.join(args.dist, name)
        if not os.path.exists(local):
            print(f"[SKIP] 本地不存在 {name}", flush=True)
            continue
        want_sha = sha256(local)
        a = assets.get(name)
        if a and not is_empty_asset(a):
            print(f"[SKIP] 已存在非空附件 {name}", flush=True)
            expected[name] = (local, want_sha)
            continue
        target_name = suffix_name(name, args.suffix) if name in empty_names else name
        staged = local
        if target_name != name:
            staged = os.path.join(args.dist, target_name)
            shutil.copyfile(local, staged)
            print(f"[i] 同名空占位存在，改用 {target_name}", flush=True)
        expected[target_name] = (local, want_sha)
        uploads.append((target_name, staged))

    if uploads:
        if args.uploader == "presigned":
            for target_name, staged in uploads:
                try:
                    presigned_upload(opener, token, args.repo, args.tag, target_name, staged)
                except Exception as e:
                    print(f"[ERR] {target_name}: {str(e)[:300]}", flush=True)
        elif args.uploader == "cli":
            run_cli_upload(args.repo, args.tag, [p for _, p in uploads])

    ok = verify(opener, token, args.repo, args.tag, expected)
    print("[RESULT]", "全部通过" if ok else "存在失败，检查上方 FAIL 项", flush=True)
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
