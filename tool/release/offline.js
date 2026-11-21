#!/usr/bin/env node
'use strict';
/**
 * 生成离线更新包目录（给「内网 NAS 不给出网」的场景）。
 *
 *   node tool/release/offline.js --dir=dist_release
 *   → dist_release/colanas-offline-1.3.14/
 *       update.json  update.json.sig
 *       files/                                 整个版本目录（自带 manifest + .sig）
 *       README.txt                             给人看的说明
 *
 * 用法：整个目录拷到 U 盘 → 放到 `<数据目录>\update\inbox\` → 设置 → 更新 → 从本地导入。
 * 导入走与在线完全相同的验签 + 组装 + 切换路径。
 */
const fs = require('node:fs');
const path = require('node:path');
const L = require('./lib');

const dir = path.resolve(L.root, String(L.arg('dir', 'dist_release')));
const updatePath = path.join(dir, 'update.json');
if (!fs.existsSync(updatePath)) L.fail(`缺 ${updatePath}（先跑 release.js）`);

const update = L.readJson(updatePath);
const server = update.components?.server;
if (!server) L.fail('update.json 里没有服务端组件');

const id = L.versionId(server.version);
const versionDir = path.join(dir, id);
if (!fs.existsSync(path.join(versionDir, 'manifest.json'))) {
  L.fail(`缺版本目录 ${id}（先跑 release.js）`);
}

const out = path.join(dir, `colanas-offline-${server.semver}`);
fs.rmSync(out, { recursive: true, force: true });
fs.mkdirSync(path.join(out, 'files'), { recursive: true });

fs.copyFileSync(updatePath, path.join(out, 'update.json'));
fs.copyFileSync(`${updatePath}.sig`, path.join(out, 'update.json.sig'));
const copied = L.copyTree(versionDir, path.join(out, 'files'));

const bytes = L.dirBytes(path.join(out, 'files'));
fs.writeFileSync(
  path.join(out, 'README.txt'),
  [
    `ColaNasOs 离线更新包 ${server.semver}（${id}）`,
    '',
    '用法：',
    '  1. 把整个目录拷到 U 盘；',
    '  2. 放到服务端数据目录下的 update\\inbox\\ 里（设置 → 更新 页面会显示完整路径）；',
    '  3. 在「设置 → 更新」点「从本地导入」，导入后点「重启生效」。',
    '',
    `文件数：${copied}，解压后约 ${(bytes / 1048576).toFixed(1)} MB`,
    '包内所有文件都有 sha256 + ed25519 签名，导入时会逐个校验。',
    '',
  ].join('\r\n'),
  'utf8',
);

console.log(
  `[offline] ${path.relative(L.root, out)}（${copied} 个文件 / ${(bytes / 1048576).toFixed(1)} MB）`,
);
