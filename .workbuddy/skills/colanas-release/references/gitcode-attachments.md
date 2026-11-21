# GitCode Release 附件上传细节

## 官方两步上传（推荐）

API Host 可用 `https://api.gitcode.com`，路径统一以 `/api/v5` 开头。

### 第一步：获取预签名地址

```http
GET /api/v5/repos/{owner}/{repo}/releases/{tag}/upload_url
    ?access_token=<PAT>&file_name=<附件名>
Accept: application/json
```

响应：

```json
{
  "url": "https://.../upload/...",
  "headers": {
    "x-obs-meta-project-id": "...",
    "x-obs-acl": "public-read",
    "x-obs-callback": "...",
    "Content-Type": "application/octet-stream"
  }
}
```

### 第二步：PUT 文件

把第一步返回的 `headers` 原样带上，`Content-Length` 用本地文件大小：

```http
PUT <url>
x-obs-meta-project-id: ...
x-obs-acl: ...
x-obs-callback: ...
Content-Type: application/octet-stream
Content-Length: <size>

<binary>
```

HTTP 2xx 只代表 OBS 收到对象，不代表 GitCode 已把附件登记成功。实测成功/失败都要再看 Release API。

## 创建 Release

```http
POST /api/v5/repos/{owner}/{repo}/releases?access_token=<PAT>
Content-Type: application/json

{
  "tag_name": "v1.3.14",
  "name": "v1.3.14",
  "body": "发行说明",
  "release_status": "latest"
}
```

`release_status` 取 `latest` 或 `pre`。`target_commitish` 可选；不传则默认分支最新提交。发布前应先确保 tag 已推到远端。

## 查询与验证

```http
GET /api/v5/repos/{owner}/{repo}/releases/tags/{tag}?access_token=<PAT>
```

检查 `assets` 中目标文件名：

- `size` 必须等于本地文件大小。
- `digest`（可能带 `sha256:` 前缀）必须等于本地 sha256。
- 空文件特征是 `size=0`，`digest=sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`。

## 删除空附件

```http
DELETE /api/v5/repos/{owner}/{repo}/releases/{tag}/attach_files/{attach_file_id}?access_token=<PAT>
```

成功返回 `204 No Content`。脚本的 `--clean-empty` 会先从 Release 详情里取附件 id 再调用该接口；取不到 id 时会提示网页手工删除。

## 0 字节根因（1.3.14 实测）

现象：

```text
size=0
digest=sha256:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
```

PUT 返回 `HTTP=203`，`size_upload` 与本地大小一致，但响应体报：

```text
CallBack.0002 / Fail to read response body ... obs_callback ... code:400, err:EOF
```

排查过 `PRIVATE-TOKEN` / `Bearer`、`gitcode.com` / `api.gitcode.com` / `api.atomgit.com`、curl / Python urllib、bytes 整体上传、代理 / 直连、手动模拟 `obs_callback`、CDN 域名、网页上传、`atomgit-powershell` skill，均不是根因。

真正根因：Release 里已有同名 0 字节附件占位，后续同名上传被当作「更新」，GitCode 更新 attachment 失败。换新文件名后立即成功，且下载校验通过。

因此脚本默认策略是：检测到同名空附件 → 复制成 `*-v2.ext` 新文件名上传。只有用户明确要求清理时才使用 `--clean-empty`。

## gitcode-cli 假成功

```bash
npx -y gitcode-cli@latest release upload v1.3.14 <files...> -R cocacola23/ColaNasOs
```

CLI 能走通上传链路，但它只看 PUT 状态码 `<400` 就输出 `✓` / `Done.`。`203 + 回调失败` 也满足这个条件，所以 API 查询仍是 `size=0`。

脚本即使使用 `--uploader cli`，也会在最后执行强校验；失败时返回非零退出码。不要把 CLI 输出当作成功证据。

## 网页端仍需人工处理的情况

- 旧 0 字节附件没有可解析的 id 时，API 删除会失败，需要网页手工删。
- 临时 Release（如 `v1.3.14-uploadtest`）若 API 不支持删除 Release，也要网页手工删。
- 这些清理不影响新版本 v2 附件下载，但会让 Release 页面显得混乱。
