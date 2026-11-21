#!/usr/bin/env node
'use strict';
/**
 * 一次发版的全部产物：版本目录 + 版本清单 + 增量包 + update.json。
 *
 *   node tool/release/release.js --out=dist_release --tag=v1.3.14 \
 *        --from=dist_release/D10313 \
 *        --url-base=https://gitcode.com/colaKot/ColaNasOs/releases/download/v1.3.14,\
https://github.com/colaKot/ColaNasOs/releases/download/v1.3.14 \
 *        --pc-setup=dist_installer/ColaNasOs-Client-1.3.14-Setup.exe \
 *        --apk=dist_installer/ColaNasOs-Client-1.3.14-android-arm64.apk \
 *        --notes-zh="修复…"
 *
 * 产物（全部可以原样上传到 Release，**扁平**资产名）：
 *   dist_release/update.json / update.json.sig
 *   dist_release/D10314/            完整版本目录（内含 manifest.json / .sig）
 *   dist_release/assets/            增量资产：*.br、smallfiles-*.brb、manifest-D10314.json
 *
 * 铁律：**清单最后上传**（方案 §10.1）。本工具只负责生成；上传由 publish.js 收尾。
 */
const fs = require('node:fs');
const path = require('node:path');
const L = require('./lib');

const SMALL_FILE_LIMIT = 256 * 1024;

function main() {
  const product = L.productVersion();
  const out = path.resolve(L.root, String(L.arg('out', 'dist_release')));
  const tag = String(L.arg('tag', `v${product.semver}`));
  const channels = String(L.arg('channel', 'stable'));
  const fromDirs = L.args('from').map((p) => path.resolve(L.root, p));
  const urlBases = String(L.arg('url-base', ''))
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  const id = L.versionId(product.version);
  /** 需要上传的「扁平资产名 → 本地文件」，最后写成 upload.json 给 publish.js */
  const uploads = [];

  console.log(`[release] ${product.semver} → ${id}，输出 ${path.relative(L.root, out)}`);

  // ---- 1. 版本目录 -------------------------------------------------------
  const versionDir = path.join(out, id);
  fs.rmSync(versionDir, { recursive: true, force: true });
  const copied = buildVersionDir(versionDir, product);
  L.writeJson(path.join(versionDir, 'version.json'), {
    semver: product.semver,
    version: product.version,
    buildNumber: product.version % 100,
    versionCode: product.version,
  });

  // ---- 2. 版本清单（整体签名）--------------------------------------------
  const { pem } = L.loadPrivateKey();
  const manifest = L.writeManifest(versionDir, product.version, pem);
  const fileCount = Object.keys(manifest.files).length;
  const versionBytes = L.dirBytes(versionDir);
  console.log(`[release] 版本目录 ${fileCount} 个文件 / ${(versionBytes / 1048576).toFixed(1)} MB`);

  // ---- 3. 增量包 ---------------------------------------------------------
  const assetsDir = path.join(out, 'assets');
  fs.rmSync(assetsDir, { recursive: true, force: true });
  L.ensureDir(assetsDir);

  // 清单资产（扁平名），客户端按 urls 直接取
  const manifestName = `manifest-${id}.json`;
  const manifestSigName = `${manifestName}.sig`;
  fs.copyFileSync(path.join(versionDir, 'manifest.json'), path.join(assetsDir, manifestName));
  fs.copyFileSync(path.join(versionDir, 'manifest.json.sig'), path.join(assetsDir, manifestSigName));

  let delta = null;
  if (fromDirs.length > 0) {
    delta = buildDelta({ versionDir, assetsDir, manifest, baselines: fromDirs, urlBases, id });
  } else {
    console.log('[release] 未指定 --from，本次不发增量（只发全量 / 清单）');
  }

  // ---- 4. update.json ----------------------------------------------------
  const serverFull = packageAsset('setup');
  const update = {
    schema: 1,
    channel: channels,
    releasedAt: new Date().toISOString(),
    keyId: String(L.arg('key-id', 'k2026a')),
    ...(L.arg('min-shell') ? { minShell: String(L.arg('min-shell')) } : {}),
    notes: notes(),
    components: {
      server: {
        semver: product.semver,
        version: product.version,
        ...(delta ? { delta } : {}),
        ...(serverFull ? { full: serverFull } : {}),
      },
    },
  };
  const pc = clientComponent('client_pc');
  if (pc) update.components.client_pc = pc;
  const android = clientComponent('client_android');
  if (android) update.components.client_android = android;

  const updatePath = path.join(out, 'update.json');
  const text = `${JSON.stringify(update, null, 2)}\n`;
  fs.writeFileSync(updatePath, text, 'utf8');
  const sig = require('node:crypto').sign(null, Buffer.from(text, 'utf8'), pem).toString('base64');
  fs.writeFileSync(`${updatePath}.sig`, sig, 'utf8');

  for (const name of fs.readdirSync(assetsDir)) {
    uploads.push({ name, file: path.join(assetsDir, name) });
  }
  uploads.push({ name: 'update.json', file: updatePath });
  uploads.push({ name: 'update.json.sig', file: `${updatePath}.sig` });
  flushUploads();

  // ---- 5. 汇总 -----------------------------------------------------------
  const assetFiles = fs.readdirSync(assetsDir);
  const assetBytes = assetFiles.reduce((s, n) => s + fs.statSync(path.join(assetsDir, n)).size, 0);
  console.log(
    `[release] 增量资产 ${assetFiles.length} 个 / ${(assetBytes / 1048576).toFixed(2)} MB` +
      (delta ? `（基线 ${delta.from.join(', ')}）` : ''),
  );
  console.log(`[release] 清单 ${updatePath}（${(fs.statSync(updatePath).size / 1024).toFixed(1)} KB）+ .sig`);
  if (!urlBases.length) {
    console.log('[release] ⚠ 未给 --url-base，update.json 里的 URL 是相对占位，上传前必须补');
  }
  console.log(`[release] 下一步：node tool/release/publish.js --dir=${path.relative(L.root, out)} --tag=${tag}`);
  console.log(`[release] 本次共处理 ${copied} 个源文件`);

  function notes() {
    const zh = String(L.arg('notes-zh', L.arg('notes', '')));
    const en = String(L.arg('notes-en', ''));
    const out = {};
    if (zh) out.zh = zh;
    if (en) out.en = en;
    return out;
  }

  /** 整包资产（安装包 / APK）：给了路径就带上，同时登记到 upload.json */
  function packageAsset(flag) {
    const p = L.arg(flag);
    if (!p) return null;
    const file = path.resolve(L.root, String(p));
    if (!fs.existsSync(file)) L.fail(`找不到 --${flag}: ${p}`);
    const name = path.basename(file);
    uploads.push({ name, file });
    return {
      size: fs.statSync(file).size,
      sha256: L.sha256FileHex(file),
      urls: urlBases.map((b) => `${b.replace(/\/+$/, '')}/${encodeURIComponent(name)}`),
    };
  }

  function clientComponent(id) {
    const map = {
      client_pc: [
        ['setup', 'pc-setup'],
        ['portable', 'pc-portable'],
      ],
      client_android: [
        ['apk', 'apk'],
        ['apk_tv', 'apk-tv'],
      ],
    }[id];
    const assets = {};
    for (const [kind, flag] of map) {
      const asset = packageAsset(flag);
      if (asset) assets[kind] = asset;
    }
    if (Object.keys(assets).length === 0) return null;
    return {
      semver: product.semver,
      version: product.version,
      versionCode: buildNumber(),
      assets,
    };
  }

  /** 安卓 versionCode = pubspec 的 `+B`（Flutter 打包时直接用这个） */
  function buildNumber() {
    const explicit = L.arg('version-code');
    if (explicit) return Number(explicit);
    try {
      const pub = fs.readFileSync(
        path.join(L.root, 'apps', 'colanas_os', 'pubspec.yaml'),
        'utf8',
      );
      const m = /^version:\s*\d+\.\d+\.\d+\+(\d+)/m.exec(pub);
      if (m) return Number(m[1]);
    } catch {
      /* 兜底用 patch */
    }
    return product.version % 100;
  }

  function flushUploads() {
    // 上传清单：让 publish.js 知道「哪些名字对应哪个本地文件」，
    // 551 MB 的整包不用在 dist_release 里再复制一份
    L.writeJson(path.join(out, 'upload.json'), { tag, entries: uploads });
  }
}

function buildVersionDir(versionDir, product) {
  const skip = (p) => !p.endsWith('.map') && !p.endsWith('.br');
  let n = 0;
  n += L.copyTree(path.join(L.root, 'dist', 'kernel'), path.join(versionDir, 'kernel'), skip);
  // 内核的模块实现：`dist/kernel/modules.js` 里是 `require("../src/modules/…")`，
  // 少了这一份，版本目录里的内核一启动就 MODULE_NOT_FOUND（2026-11-21 复查发现）
  const srcDir = path.join(L.root, 'dist', 'src');
  if (!fs.existsSync(path.join(srcDir, 'modules', 'system', 'index.js'))) {
    L.fail('缺少 dist/src（先 npm run build）——版本目录必须带 src/，否则内核起不来');
  }
  n += L.copyTree(srcDir, path.join(versionDir, 'src'), skip);
  // electron 内核宿主：单个文件
  const host = path.join(L.root, 'dist', 'electron', 'kernel-host.js');
  if (!fs.existsSync(host)) L.fail('缺少 dist/electron/kernel-host.js（先 npm run build）');
  L.ensureDir(path.join(versionDir, 'electron'));
  fs.copyFileSync(host, path.join(versionDir, 'electron', 'kernel-host.js'));
  n += 1;

  const web = path.join(L.root, 'apps', 'colanas_os', 'build', 'web');
  if (!fs.existsSync(path.join(web, 'index.html'))) {
    L.fail('缺少 Web 产物（先 build-web.bat）');
  }
  n += L.copyTree(web, path.join(versionDir, 'web'), skip);

  // 契约：内核只读 locales.json，但 apps.json / errors.json 在部分路径也会查
  const contracts = path.join(L.root, 'contracts');
  L.ensureDir(path.join(versionDir, 'contracts'));
  for (const name of fs.readdirSync(contracts)) {
    if (!name.endsWith('.json') || name === 'openapi.json') continue;
    fs.copyFileSync(path.join(contracts, name), path.join(versionDir, 'contracts', name));
    n += 1;
  }

  n += L.copyTree(path.join(L.root, 'sidecars'), path.join(versionDir, 'sidecars'), skip);
  void product;
  return n;
}

/**
 * 增量：所有基线**变化文件的并集**。
 *
 * 为什么是并集：清单里 `from: [1.3.12, 1.3.13]` 只有一份文件列表。若某文件
 * 相对 1.3.12 变了、相对 1.3.13 没变，它仍然必须出现在列表里 —— 否则从 1.3.12
 * 升上来的用户会漏文件。对 1.3.13 的用户多下一份同样的文件，只是浪费几 KB。
 */
function buildDelta({ versionDir, assetsDir, manifest, baselines, urlBases, id }) {
  const baseMaps = baselines.map((dir) => {
    const mf = path.join(dir, 'manifest.json');
    if (!fs.existsSync(mf)) {
      L.fail(`基线目录缺 manifest.json: ${path.relative(L.root, dir)}`);
    }
    return L.readJson(mf).files || {};
  });
  const baseNames = baselines.map((dir) => {
    const vj = path.join(dir, 'version.json');
    if (fs.existsSync(vj)) return L.readJson(vj).semver;
    return path.basename(dir);
  });

  const changed = [];
  for (const [rel, digest] of Object.entries(manifest.files)) {
    const differs = baseMaps.some((files) => files[rel] !== digest);
    if (differs) changed.push(rel);
  }

  const files = [];
  const small = [];
  let seq = 0;
  for (const rel of changed) {
    const abs = path.join(versionDir, rel);
    const size = fs.statSync(abs).size;
    if (size < SMALL_FILE_LIMIT) {
      small.push({ path: rel, data: fs.readFileSync(abs) });
      continue;
    }
    const raw = fs.readFileSync(abs);
    const br = L.brotli(raw);
    const assetName = `${seq++}-${path.basename(rel)}.br`;
    fs.writeFileSync(path.join(assetsDir, assetName), br);
    files.push({
      path: rel,
      size: raw.length,
      sha256: L.sha256Hex(raw),
      br: { size: br.length, sha256: L.sha256Hex(br) },
      urls: urlBases.map((b) => `${b.replace(/\/+$/, '')}/${encodeURIComponent(assetName)}`),
    });
  }

  const bundles = [];
  if (small.length > 0) {
    const packed = L.packBundle(small);
    const bundleName = `smallfiles-${L.sha256Hex(packed).slice(0, 12)}.brb`;
    fs.writeFileSync(path.join(assetsDir, bundleName), packed);
    bundles.push({
      name: bundleName,
      size: packed.length,
      sha256: L.sha256Hex(packed),
      members: small.map((s) => s.path),
      urls: urlBases.map((b) => `${b.replace(/\/+$/, '')}/${bundleName}`),
    });
  }

  const manifestName = `manifest-${id}.json`;
  const manifestAsset = {
    size: fs.statSync(path.join(assetsDir, manifestName)).size,
    sha256: L.sha256FileHex(path.join(assetsDir, manifestName)),
    urls: urlBases.map((b) => `${b.replace(/\/+$/, '')}/${manifestName}`),
  };

  console.log(
    `[release] 增量：变 ${changed.length} 个（大文件 ${files.length} / 小文件包 ${small.length}）`,
  );
  return {
    from: [...baseNames],
    files,
    bundles,
    urlBase: urlBases.map((b) => b.replace(/\/+$/, '')),
    manifest: manifestAsset,
  };
}

main();
