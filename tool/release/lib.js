'use strict';
/**
 * 发布侧共用工具（签名 / 摘要 / 目录 / 小文件包）。
 *
 * 刻意复用 `dist/kernel/**` 里的编译产物：客户端怎么校验，发布侧就怎么生成，
 * 两边永远用同一份 `canonicalPayload`，不会出现「签发和验签口径不一致」。
 */
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');

const root = path.join(__dirname, '..', '..');

function loadKernelModule(rel) {
  return require(path.join(root, 'dist', 'kernel', rel));
}

const { signManifest, listFiles, sha256File, canonicalPayload, versionId } = loadKernelModule('updater.js');
const { packBundle } = loadKernelModule(path.join('update', 'bundle.js'));

function fail(msg) {
  console.error(`[release] ${msg}`);
  process.exit(1);
}

function arg(name, fallback) {
  const hit = process.argv.slice(2).find((a) => a === `--${name}` || a.startsWith(`--${name}=`));
  if (!hit) return fallback;
  const eq = hit.indexOf('=');
  return eq === -1 ? true : hit.slice(eq + 1);
}

function args(name) {
  return process.argv
    .slice(2)
    .filter((a) => a.startsWith(`--${name}=`))
    .map((a) => a.slice(a.indexOf('=') + 1));
}

/** 私钥：环境变量 → 用户目录 → 仓库 `.keys/`（三者都不在版本库里） */
function loadPrivateKey() {
  const candidates = [
    process.env.COLANAS_SIGN_KEY,
    path.join(os.homedir(), '.colanas', 'deploy.pem'),
    path.join(root, '.keys', 'update-signing.pem'),
  ].filter(Boolean);
  for (const p of candidates) {
    try {
      if (fs.existsSync(p)) return { pem: fs.readFileSync(p, 'utf8'), file: p };
    } catch {
      /* 下一个 */
    }
  }
  fail('找不到签名私钥（COLANAS_SIGN_KEY / ~/.colanas/deploy.pem / .keys/update-signing.pem）');
}

function sha256FileHex(file) {
  return sha256File(file);
}

function sha256Hex(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function brotli(buf, quality = 11) {
  return zlib.brotliCompressSync(buf, {
    params: { [zlib.constants.BROTLI_PARAM_QUALITY]: quality, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: buf.length },
  });
}

function writeJson(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`, 'utf8');
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

/** 递归复制（跳过 `.map` / `.br` 之类不需要进版本目录的副产物） */
function copyTree(src, dest, filter) {
  if (!fs.existsSync(src)) return 0;
  let n = 0;
  const walk = (from, to) => {
    ensureDir(to);
    for (const e of fs.readdirSync(from, { withFileTypes: true })) {
      // sidecars 里有 node_modules（几百 MB）：它按 Electron ABI 装在安装目录，
      // 绝不进版本目录
      if (e.name === 'node_modules' || e.name === '.cache') continue;
      const a = path.join(from, e.name);
      const b = path.join(to, e.name);
      if (e.isDirectory()) walk(a, b);
      else if (e.isFile()) {
        if (filter && !filter(a, e.name)) continue;
        fs.copyFileSync(a, b);
        n += 1;
      }
    }
  };
  walk(src, dest);
  return n;
}

function dirBytes(dir) {
  let total = 0;
  for (const rel of listFiles(dir)) total += fs.statSync(path.join(dir, rel)).size;
  return total;
}

/**
 * 版本目录 → manifest.json（含文件 sha256）+ manifest.json.sig。
 *
 * 两份签名是同一个 ed25519 签名：`manifest.signature` 供 `Updater.verify` 用，
 * `.sig` 文件供「整体签名」用。两者都基于 `canonicalPayload(version, files)`。
 */
function writeManifest(versionDir, version, privatePem) {
  const manifest = signManifest(version, versionDir, privatePem);
  const manifestPath = path.join(versionDir, 'manifest.json');
  writeJson(manifestPath, manifest);
  fs.writeFileSync(`${manifestPath}.sig`, manifest.signature, 'utf8');
  return manifest;
}

/** 版本号真源 */
function productVersion() {
  const pkg = readJson(path.join(root, 'package.json'));
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(pkg.version || '');
  if (!m) fail(`package.json version 不合法: ${pkg.version}`);
  const [major, minor, patch] = [Number(m[1]), Number(m[2]), Number(m[3])];
  return { semver: pkg.version, version: major * 10000 + minor * 100 + patch };
}

module.exports = {
  root,
  arg,
  args,
  fail,
  loadPrivateKey,
  sha256Hex,
  sha256FileHex,
  brotli,
  writeJson,
  readJson,
  ensureDir,
  copyTree,
  dirBytes,
  writeManifest,
  productVersion,
  packBundle,
  listFiles,
  canonicalPayload,
  versionId,
  loadKernelModule,
};
