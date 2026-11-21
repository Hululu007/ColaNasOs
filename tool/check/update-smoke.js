#!/usr/bin/env node
'use strict';
/**
 * 增量更新端到端验收（不联网、不起内核）：
 *
 *   1. 造两个版本目录（D101 / D102），签名出 manifest 与 update.json
 *   2. 只发布「变化文件」的增量资产（大文件 .br / 小文件包 .brb）
 *   3. 起一个本地 HTTP 源（支持 Range），当作 GitCode
 *   4. 用真实的 `kernel/update/service.ts` 走完 check → 下载 → 校验 → 组装 → 切指针
 *   5. 校验：只下了变化文件、未变化文件是硬链接、切完指针能读到新内容
 *   6. 负向：篡改资产摘要 → 必须失败且**不动**当前指针
 *   7. boot.json：连续 3 次不健康 → rollback
 *
 * 用法：node tool/check/update-smoke.js
 */
const crypto = require('node:crypto');
const fs = require('node:fs');
const http = require('node:http');
const os = require('node:os');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');
const L = require(path.join(root, 'tool', 'release', 'lib.js'));
const { UpdateService } = require(path.join(root, 'dist', 'kernel', 'update', 'service.js'));
const { evaluateBoot, readBoot, MAX_BOOT_ATTEMPTS } = require(path.join(root, 'dist', 'kernel', 'update', 'boot.js'));
const { packBundle } = require(path.join(root, 'dist', 'kernel', 'update', 'bundle.js'));

// 本机代理会让 localhost 请求走代理，验收必须直连
for (const k of ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy', 'NO_PROXY', 'no_proxy']) {
  delete process.env[k];
}

const results = [];
const check = (name, ok, detail) => {
  results.push({ name, ok: !!ok, detail: detail || '' });
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` — ${detail}` : ''}`);
};

const work = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-update-'));
const { privateKey, publicKey } = crypto.generateKeyPairSync('ed25519');
const privPem = privateKey.export({ type: 'pkcs8', format: 'pem' }).toString();
const pubPem = publicKey.export({ type: 'spki', format: 'pem' }).toString();
const KEY_ID = 'k2026a';

function write(file, data) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, data);
}

/** 造一个版本目录：小文件 + 一个大文件（走 .br）+ 一个不参与变化的文件 */
function makeBuild(name, opts) {
  const dir = path.join(work, name);
  write(path.join(dir, 'kernel', 'index.js'), `// ${name} kernel v${opts.version}\nmodule.exports = ${opts.version};\n`);
  write(path.join(dir, 'kernel', 'modules', 'photo.js'), `// photo v${opts.version}\n`);
  // 内核的模块实现（编译后是 require("../src/modules/…")）：版本目录少了它起不来，
  // 2026-11-21 复查就是栽在这里，所以冒烟必须覆盖到
  write(path.join(dir, 'src', 'modules', 'system', 'index.js'), `// system module v${opts.version}\n`);
  write(path.join(dir, 'web', 'index.html'), '<html><body>colanas</body></html>');
  // 大文件：随机内容 + 少量固定前缀，保证 brotli 有效果且每次发版都变
  const big = Buffer.concat([Buffer.from('/* main.dart.js */\n'.repeat(50)), crypto.randomBytes(400 * 1024)]);
  write(path.join(dir, 'web', 'main.dart.js'), big);
  // 永远不变的文件（验收「硬链接复用」）
  write(path.join(dir, 'contracts', 'locales.json'), '[{"id":"zh-CN"}]\n');
  write(path.join(dir, 'electron', 'kernel-host.js'), '// host\n');
  write(
    path.join(dir, 'version.json'),
    JSON.stringify({ semver: opts.semver, version: opts.version, versionCode: opts.version }),
  );
  const manifest = L.writeManifest(dir, opts.version, privPem);
  return { dir, version: opts.version, semver: opts.semver, manifest, big };
}

function signUpdate(update) {
  const text = `${JSON.stringify(update, null, 2)}\n`;
  const sig = crypto.sign(null, Buffer.from(text, 'utf8'), privPem).toString('base64');
  return { text, sig };
}

/** 极简静态源：支持 HEAD / GET / Range，够验收下载器用 */
function serve(dir) {
  const server = http.createServer((req, res) => {
    const urlPath = decodeURIComponent((req.url || '/').split('?')[0]);
    const file = path.join(dir, urlPath.replace(/^\/+/, ''));
    if (!file.startsWith(dir) || !fs.existsSync(file) || !fs.statSync(file).isFile()) {
      res.writeHead(404).end('not found');
      return;
    }
    const size = fs.statSync(file).size;
    const range = req.headers.range;
    if (req.method === 'HEAD') {
      res.writeHead(200, { 'content-length': String(size) }).end();
      return;
    }
    if (range) {
      const m = /^bytes=(\d+)-(\d*)$/.exec(range);
      if (m) {
        const start = Number(m[1]);
        if (start >= size) {
          res.writeHead(416, { 'content-range': `bytes */${size}` }).end();
          return;
        }
        const end = m[2] ? Math.min(Number(m[2]), size - 1) : size - 1;
        res.writeHead(206, {
          'content-length': String(end - start + 1),
          'content-range': `bytes ${start}-${end}/${size}`,
        });
        fs.createReadStream(file, { start, end }).pipe(res);
        return;
      }
    }
    res.writeHead(200, { 'content-length': String(size) });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve({ server, port: server.address().port }));
  });
}

async function waitJob(svc, timeoutMs = 60_000) {
  const started = Date.now();
  for (;;) {
    const job = svc.jobStatus();
    if (['ready', 'failed', 'cancelled', 'idle'].includes(job.phase)) return job;
    if (Date.now() - started > timeoutMs) return job;
    await new Promise((r) => setTimeout(r, 150));
  }
}

(async () => {
  const old = makeBuild('build-101', { version: 101, semver: '0.1.1' });
  const next = makeBuild('build-102', { version: 102, semver: '0.1.2' });

  // ---- 伪造发布产物：只有变化文件的资产 --------------------------------
  const release = path.join(work, 'release');
  const assetsDir = path.join(release, 'assets');
  fs.mkdirSync(assetsDir, { recursive: true });

  const changed = [];
  for (const [rel, digest] of Object.entries(next.manifest.files)) {
    if (old.manifest.files[rel] !== digest) changed.push(rel);
  }
  check('只列出变化的文件', changed.length === 5, `changed=${changed.join(',')}`);

  const files = [];
  const small = [];
  let seq = 0;
  for (const rel of changed) {
    const abs = path.join(next.dir, rel);
    const raw = fs.readFileSync(abs);
    if (raw.length < 256 * 1024) {
      small.push({ path: rel, data: raw });
      continue;
    }
    const br = L.brotli(raw);
    const assetName = `${seq++}-${path.basename(rel)}.br`;
    fs.writeFileSync(path.join(assetsDir, assetName), br);
    files.push({
      path: rel,
      size: raw.length,
      sha256: L.sha256Hex(raw),
      br: { size: br.length, sha256: L.sha256Hex(br) },
      urls: [], // 下面拿到端口再补
    });
  }
  const packed = packBundle(small);
  fs.writeFileSync(path.join(assetsDir, 'smallfiles.brb'), packed);
  const bundles = [
    { name: 'smallfiles.brb', size: packed.length, sha256: L.sha256Hex(packed), members: small.map((s) => s.path), urls: [] },
  ];
  fs.copyFileSync(path.join(next.dir, 'manifest.json'), path.join(assetsDir, 'manifest.json'));
  // 签名挂在 `.sig.json`（内容 {keyId, sig}）：GitCode 的 raw 直链拒绝预览 `.sig`
  // 这类未知扩展名。这里**故意不给** `manifest.json.sig`，逼客户端走新路径 ——
  // 只要它能装成功，就证明 `.sig.json` 真的被读到了。
  fs.writeFileSync(
    path.join(assetsDir, 'manifest.json.sig.json'),
    JSON.stringify({
      keyId: KEY_ID,
      sig: fs.readFileSync(path.join(next.dir, 'manifest.json.sig'), 'utf8').trim(),
    }),
    'utf8',
  );

  const { server, port } = await serve(release);
  const base = `http://127.0.0.1:${port}/assets`;
  for (const f of files) {
    const name = `${files.indexOf(f)}-${path.basename(f.path)}.br`;
    f.urls = [`${base}/${name}`];
  }
  bundles[0].urls = [`${base}/smallfiles.brb`];

  const update = {
    schema: 1,
    channel: 'stable',
    releasedAt: new Date().toISOString(),
    keyId: KEY_ID,
    notes: { zh: '验收用' },
    components: {
      server: {
        semver: '0.1.2',
        version: 102,
        delta: {
          from: ['0.1.1'],
          files,
          bundles,
          urlBase: [base],
          manifest: {
            size: fs.statSync(path.join(assetsDir, 'manifest.json')).size,
            sha256: L.sha256FileHex(path.join(assetsDir, 'manifest.json')),
            urls: [`${base}/manifest.json`],
          },
        },
      },
    },
  };
  const signed = signUpdate(update);
  fs.writeFileSync(path.join(release, 'update.json'), signed.text);
  // 网络源只提供 `.sig.json`：GitCode 的 raw 直链拿不到 `.sig`（403 暂不支持预览）。
  // 离线包那边仍用老格式 `.sig`，两条签名路径都覆盖到。
  fs.writeFileSync(
    path.join(release, 'update.json.sig.json'),
    JSON.stringify({ keyId: KEY_ID, sig: signed.sig }),
    'utf8',
  );

  // ---- 数据目录：已有 D101 且指针指向它 -------------------------------
  const dataDir = path.join(work, 'data');
  const versionsDir = path.join(dataDir, 'versions');
  fs.mkdirSync(versionsDir, { recursive: true });
  L.copyTree(old.dir, path.join(versionsDir, 'D101'));
  fs.writeFileSync(path.join(versionsDir, 'current.json'), JSON.stringify({ id: 'D101', at: Date.now() }));

  process.env.COLANAS_UPDATE_MANIFEST = `http://127.0.0.1:${port}/update.json`;
  process.env.COLANAS_UPDATE_PUBKEY = pubPem;

  const svc = new UpdateService({ dataDir });
  const cur = svc.current();
  check('当前版本识别为 D101', cur.id === 'D101' && cur.semver === '0.1.1', `${cur.id}/${cur.semver}`);

  const checked = await svc.checkServer({ force: true });
  check('检查到新版本', checked.hasUpdate && checked.latest?.semver === '0.1.2', JSON.stringify(checked.latest));
  check('增量模式可用', checked.mode === 'delta', `mode=${checked.mode}`);
  check('增量体积远小于全量', checked.deltaBytes > 0 && checked.deltaBytes < 900 * 1024, `${(checked.deltaBytes / 1024).toFixed(0)} KB`);

  await svc.install({ force: true });
  const job = await waitJob(svc);
  check('安装完成', job.phase === 'ready', `${job.phase} ${job.error}`);

  const after = svc.current();
  check('指针切到 D102', after.id === 'D102' && after.semver === '0.1.2', `${after.id}/${after.semver}`);
  check(
    '新内核内容生效',
    fs.readFileSync(path.join(versionsDir, 'D102', 'kernel', 'index.js'), 'utf8').includes('v102'),
    '',
  );
  check(
    '新 Web 产物字节一致',
    L.sha256FileHex(path.join(versionsDir, 'D102', 'web', 'main.dart.js')) === next.manifest.files['web/main.dart.js'],
    '',
  );
  check(
    '版本目录带 src/（拆壳后可独立启动）',
    fs.existsSync(path.join(versionsDir, 'D102', 'src', 'modules', 'system', 'index.js')),
    '',
  );
  const unchanged = path.join(versionsDir, 'D102', 'contracts', 'locales.json');
  const stat = fs.statSync(unchanged);
  check('未变化文件是硬链接（不占空间）', stat.nlink >= 2, `nlink=${stat.nlink}`);
  check('整个目录逐文件校验通过', (() => {
    const v = require(path.join(root, 'dist', 'kernel', 'update', 'assemble.js')).verifyTree(
      path.join(versionsDir, 'D102'),
      next.manifest.files,
    );
    return v.ok;
  })(), '');
  check('没有残留 staging 目录', !fs.readdirSync(versionsDir).some((n) => n.startsWith('.staging-')), '');

  // ---- 负向：篡改资产摘要 → 必须失败，指针不动 ------------------------
  const badData = path.join(work, 'data-bad');
  fs.mkdirSync(badData, { recursive: true });
  L.copyTree(path.join(old.dir), path.join(badData, 'versions', 'D101'));
  fs.writeFileSync(path.join(badData, 'versions', 'current.json'), JSON.stringify({ id: 'D101' }));
  const badUpdate = JSON.parse(JSON.stringify(update));
  badUpdate.components.server.version = 103;
  badUpdate.components.server.semver = '0.1.3';
  badUpdate.components.server.delta.files[0].sha256 = 'f'.repeat(64);
  const badSigned = signUpdate(badUpdate);
  fs.writeFileSync(path.join(release, 'update-bad.json'), badSigned.text);
  fs.writeFileSync(path.join(release, 'update-bad.json.sig'), badSigned.sig);
  process.env.COLANAS_UPDATE_MANIFEST = `http://127.0.0.1:${port}/update-bad.json`;
  const badSvc = new UpdateService({ dataDir: badData });
  await badSvc.install({ force: true });
  const badJob = await waitJob(badSvc);
  check('摘要被篡改时安装失败', badJob.phase === 'failed', badJob.error.slice(0, 80));
  const badPtr = JSON.parse(fs.readFileSync(path.join(badData, 'versions', 'current.json'), 'utf8'));
  check('失败后指针仍是 D101', badPtr.id === 'D101', badPtr.id);
  check('失败后没有留下半个版本目录', !fs.existsSync(path.join(badData, 'versions', 'D103')), '');

  // ---- 增量失败 → 自动降级全量 --------------------------------------
  // 场景：基线被用户改过 / 包坏了。增量必然失败，但有全量包就该继续，
  // 而不是把「更新失败」丢给用户（方案 §9.6）。
  const setupBytes = Buffer.concat([Buffer.from('MZ-fake-setup\n'), crypto.randomBytes(2048)]);
  fs.writeFileSync(path.join(release, 'setup.exe'), setupBytes);
  const fullUpdate = JSON.parse(JSON.stringify(update));
  fullUpdate.components.server.version = 104;
  fullUpdate.components.server.semver = '0.1.4';
  // 故意写错摘要：增量一定校验不过
  fullUpdate.components.server.delta.files[0].sha256 = 'f'.repeat(64);
  fullUpdate.components.server.full = {
    size: setupBytes.length,
    sha256: L.sha256Hex(setupBytes),
    urls: [`http://127.0.0.1:${port}/setup.exe`],
  };
  const fullSigned = signUpdate(fullUpdate);
  fs.writeFileSync(path.join(release, 'update-full.json'), fullSigned.text);
  fs.writeFileSync(path.join(release, 'update-full.json.sig'), fullSigned.sig);

  process.env.COLANAS_UPDATE_MANIFEST = `http://127.0.0.1:${port}/update-full.json`;
  const fbData = path.join(work, 'data-fallback');
  fs.mkdirSync(fbData, { recursive: true });
  L.copyTree(path.join(old.dir), path.join(fbData, 'versions', 'D101'));
  fs.writeFileSync(path.join(fbData, 'versions', 'current.json'), JSON.stringify({ id: 'D101' }));
  const fbSvc = new UpdateService({ dataDir: fbData });
  await fbSvc.install({ force: true });
  const fbJob = await waitJob(fbSvc);
  check('增量失败自动降级全量', fbJob.phase === 'ready' && fbJob.mode === 'full', `${fbJob.phase}/${fbJob.mode}`);
  check(
    '全量包已下载并校验',
    Boolean(fbJob.hint) && fs.existsSync(fbJob.hint) && L.sha256FileHex(fbJob.hint) === L.sha256Hex(setupBytes),
    fbJob.hint ? path.basename(fbJob.hint) : '(无路径)',
  );
  const fbPtr = JSON.parse(fs.readFileSync(path.join(fbData, 'versions', 'current.json'), 'utf8'));
  check('降级全量时不动指针', fbPtr.id === 'D101', fbPtr.id);

  // ---- boot.json 自愈 --------------------------------------------------
  const bootDir = path.join(work, 'boot');
  fs.mkdirSync(bootDir, { recursive: true });
  const b1 = evaluateBoot(null, 'D101');
  check('首次启动：正常', b1.action === 'ok' && b1.state.attempts === 0, b1.action);
  const b2 = evaluateBoot({ id: 'D101', attempts: 0, firstBootAt: 0, healthyAt: null }, 'D101');
  check('未健康：累计尝试', b2.action === 'retry' && b2.state.attempts === 1, b2.action);
  const b3 = evaluateBoot({ id: 'D101', attempts: MAX_BOOT_ATTEMPTS, firstBootAt: 0, healthyAt: null }, 'D101');
  check('连续 3 次不健康：回滚', b3.action === 'rollback', b3.action);
  const b4 = evaluateBoot({ id: 'D101', attempts: 2, firstBootAt: 0, healthyAt: Date.now() }, 'D101');
  check('已健康过：正常启动且清零', b4.action === 'ok' && b4.state.attempts === 0, b4.action);
  const b5 = evaluateBoot({ id: 'D101', attempts: 2, firstBootAt: 0, healthyAt: null }, 'D102');
  check('指针变了：重新计数', b5.action === 'reset' && b5.state.id === 'D102', b5.action);

  // ---- 回滚 ------------------------------------------------------------
  const back = svc.rollback();
  check('回滚到 D101', back.id === 'D101' && svc.current().id === 'D101', back.id);
  const boot = readBoot(dataDir);
  check('回滚后 boot.json 重置', boot?.id === 'D101' && boot.healthyAt === null, JSON.stringify(boot));

  // ---- 离线包（目录形态）----------------------------------------------
  const offlineDir = path.join(dataDir, 'update', 'inbox', 'colanas-offline-0.1.2');
  fs.mkdirSync(offlineDir, { recursive: true });
  fs.writeFileSync(path.join(offlineDir, 'update.json'), signed.text);
  fs.writeFileSync(path.join(offlineDir, 'update.json.sig'), signed.sig);
  L.copyTree(next.dir, path.join(offlineDir, 'files'));
  const imported = await svc.importOffline('colanas-offline-0.1.2');
  check('离线包导入成功', imported.targetId === 'D102' && svc.current().id === 'D102', imported.targetId);
  check(
    '离线包目录被识别',
    svc.listOffline().some((o) => o.name === 'colanas-offline-0.1.2'),
    '',
  );

  server.close();
  const failed = results.filter((r) => !r.ok);
  console.log(`\n[update-smoke] ${results.length - failed.length}/${results.length} 通过`);
  if (failed.length) {
    console.log('失败项：');
    for (const f of failed) console.log(`  - ${f.name} ${f.detail}`);
    process.exitCode = 1;
  } else {
    fs.rmSync(work, { recursive: true, force: true });
  }
})().catch((err) => {
  console.error('[update-smoke] fatal', err);
  process.exitCode = 1;
});
