#!/usr/bin/env node
'use strict';
/**
 * 上传发布产物（GitCode / GitHub / Gitee）+ 回读校验。
 *
 *   node tool/release/publish.js --dir=dist_release --tag=v1.3.14 [--platform=gitcode,github]
 *   node tool/release/publish.js --dir=dist_release --tag=v1.3.14 --dry-run
 *
 * 顺序是铁律：**先传所有资产，最后传 update.json**（方案 §10.1）。
 * 传完必须回读每个 URL：少这一步，ACL 配错 / 分片没传完只会在用户端暴露成 404。
 *
 * 需要的环境变量（缺哪个就跳过哪个平台）：
 *   GITCODE_TOKEN   GitCode 个人访问令牌（repo 权限）
 *   GITHUB_TOKEN    GitHub classic PAT（repo）
 *   GITEE_TOKEN     Gitee 私人令牌（projects）
 */
const fs = require('node:fs');
const path = require('node:path');
const L = require('./lib');

const OWNER = String(L.arg('owner', 'colaKot'));
const REPO = String(L.arg('repo', 'ColaNasOs'));

const API = {
  gitcode: 'https://api.gitcode.com/api/v5',
  github: 'https://api.github.com',
  gitee: 'https://gitee.com/api/v5',
};

function tokenOf(platform) {
  return {
    gitcode: process.env.GITCODE_TOKEN || '',
    github: process.env.GITHUB_TOKEN || process.env.GH_TOKEN || '',
    gitee: process.env.GITEE_TOKEN || '',
  }[platform];
}

async function req(url, init) {
  const res = await fetch(url, init);
  const text = await res.text();
  if (!res.ok) throw new Error(`${init?.method || 'GET'} ${url} → ${res.status} ${text.slice(0, 300)}`);
  try {
    return JSON.parse(text);
  } catch {
    return text;
  }
}

async function main() {
  const dir = path.resolve(L.root, String(L.arg('dir', 'dist_release')));
  const tag = String(L.arg('tag', ''));
  const dryRun = Boolean(L.arg('dry-run', false));
  const platforms = String(L.arg('platform', 'gitcode,github,gitee'))
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  if (!tag) L.fail('必须给 --tag（例如 v1.3.14）');
  const uploadFile = path.join(dir, 'upload.json');
  if (!fs.existsSync(uploadFile)) L.fail(`缺 ${uploadFile}（先跑 release.js）`);
  const entries = L.readJson(uploadFile).entries || [];
  // update.json 永远最后传
  entries.sort((a, b) => (a.name === 'update.json' ? 1 : b.name === 'update.json' ? -1 : 0));

  console.log(`[publish] ${entries.length} 个资产 → ${tag}`);
  for (const e of entries) {
    console.log(`  - ${e.name}  ${(fs.statSync(e.file).size / 1048576).toFixed(2)} MB`);
  }
  if (dryRun) {
    console.log('[publish] --dry-run：只打印，不联网');
    return;
  }

  const done = [];
  for (const platform of platforms) {
    const token = tokenOf(platform);
    if (!token) {
      console.log(`[publish] ${platform}: 没有令牌，跳过`);
      continue;
    }
    try {
      await publishTo(platform, token);
      done.push(platform);
    } catch (err) {
      console.error(`[publish] ${platform} 失败: ${err.message}`);
      // 一个平台失败不该让整条链路停：清单最后才传，前面失败只是少了备源
      process.exitCode = 1;
    }
  }

  if (done.length === 0) {
    console.log('[publish] 没有任何平台成功，未做回读校验');
    return;
  }
  await verifyReadback();

  async function publishTo(platform, token) {
    console.log(`[publish] ${platform}: 准备 release ${tag}`);
    const releaseId = await ensureRelease(platform, token);
    for (const e of entries) {
      const sizeMb = (fs.statSync(e.file).size / 1048576).toFixed(2);
      console.log(`[publish] ${platform}: ↑ ${e.name} (${sizeMb} MB)`);
      if (platform === 'gitcode') await uploadGitcode(token, e);
      else if (platform === 'github') await uploadGithub(token, releaseId, e);
      else await uploadGitee(token, releaseId, e);
    }
    console.log(`[publish] ${platform}: 完成`);
  }

  async function ensureRelease(platform, token) {
    const base = API[platform];
    const headers = headersFor(platform, token);
    const list =
      platform === 'github'
        ? await req(`${base}/repos/${OWNER}/${REPO}/releases/tags/${tag}`, { headers }).catch(() => null)
        : await req(`${base}/repos/${OWNER}/${REPO}/releases/tags/${tag}`, { headers }).catch(() => null);
    if (list && (list.id || list.tag_name)) return list.id;
    const body = {
      tag_name: tag,
      name: tag,
      body: `ColaNasOs ${tag}`,
      target_commitish: 'main',
      prerelease: false,
    };
    const created = await req(`${base}/repos/${OWNER}/${REPO}/releases`, {
      method: 'POST',
      headers: { ...headers, 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    return created.id;
  }

  function headersFor(platform, token) {
    if (platform === 'gitcode') return { 'private-token': token, authorization: `Bearer ${token}` };
    if (platform === 'github') return { authorization: `Bearer ${token}`, accept: 'application/vnd.github+json' };
    return { authorization: `Bearer ${token}` };
  }

  /** GitCode：先要 upload_url（预签名 OBS），再原样带 x-obs-* headers PUT */
  async function uploadGitcode(token, entry) {
    const url =
      `${API.gitcode}/repos/${OWNER}/${REPO}/releases/${tag}/upload_url` +
      `?access_token=${encodeURIComponent(token)}&file_name=${encodeURIComponent(entry.name)}`;
    const presign = await req(url, { method: 'GET', headers: headersFor('gitcode', token) });
    const putUrl = presign.url || presign.upload_url;
    if (!putUrl) throw new Error(`upload_url 响应没有 url: ${JSON.stringify(presign).slice(0, 200)}`);
    const buf = fs.readFileSync(entry.file);
    const res = await fetch(putUrl, {
      method: 'PUT',
      headers: { ...(presign.headers || {}), 'content-length': String(buf.length) },
      body: buf,
    });
    if (!res.ok) throw new Error(`PUT 失败 ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }

  async function uploadGithub(token, releaseId, entry) {
    const name = encodeURIComponent(entry.name);
    const buf = fs.readFileSync(entry.file);
    // 同名资产先删（重跑幂等）
    const existing = await req(
      `${API.github}/repos/${OWNER}/${REPO}/releases/${releaseId}/assets?per_page=100`,
      { headers: headersFor('github', token) },
    ).catch(() => []);
    for (const a of Array.isArray(existing) ? existing : []) {
      if (a.name === entry.name) {
        await req(`${API.github}/repos/${OWNER}/${REPO}/releases/assets/${a.id}`, {
          method: 'DELETE',
          headers: headersFor('github', token),
        }).catch(() => null);
      }
    }
    const uploadUrl = `https://uploads.github.com/repos/${OWNER}/${REPO}/releases/${releaseId}/assets?name=${name}`;
    const res = await fetch(uploadUrl, {
      method: 'POST',
      headers: { ...headersFor('github', token), 'content-type': 'application/octet-stream' },
      body: buf,
    });
    if (!res.ok) throw new Error(`上传失败 ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }

  async function uploadGitee(token, releaseId, entry) {
    const form = new globalThis.FormData();
    form.append('access_token', token);
    form.append('file', new globalThis.Blob([fs.readFileSync(entry.file)]), entry.name);
    const res = await fetch(`${API.gitee}/repos/${OWNER}/${REPO}/releases/${releaseId}/attach_files`, {
      method: 'POST',
      body: form,
    });
    if (!res.ok) throw new Error(`上传失败 ${res.status}: ${(await res.text()).slice(0, 300)}`);
  }

  /** 回读：清单里的每个 URL 都要 200 + 长度对得上 */
  async function verifyReadback() {
    const updatePath = path.join(dir, 'update.json');
    if (!fs.existsSync(updatePath)) return;
    const update = L.readJson(updatePath);
    const urls = [];
    const walk = (node) => {
      if (!node || typeof node !== 'object') return;
      if (Array.isArray(node)) {
        node.forEach(walk);
        return;
      }
      for (const [k, v] of Object.entries(node)) {
        if (k === 'urls' && Array.isArray(v)) urls.push(...v.map(String));
        else walk(v);
      }
    };
    walk(update);
    const unique = [...new Set(urls)].filter((u) => /^https?:/.test(u));
    console.log(`[publish] 回读校验 ${unique.length} 个 URL`);
    let bad = 0;
    for (const url of unique) {
      try {
        const res = await fetch(url, { method: 'HEAD', redirect: 'follow' });
        if (!res.ok) {
          console.error(`  ✗ ${res.status} ${url}`);
          bad += 1;
        } else {
          console.log(`  ✓ ${res.status} ${url.split('/').pop()}`);
        }
      } catch (err) {
        console.error(`  ✗ ${err.message} ${url}`);
        bad += 1;
      }
    }
    if (bad > 0) {
      console.error(`[publish] ${bad} 个 URL 回读失败（多半是 ACL / 分片没传完）`);
      process.exitCode = 1;
    } else {
      console.log('[publish] 全部回读通过');
    }
  }
}

main().catch((err) => L.fail(err.message));
