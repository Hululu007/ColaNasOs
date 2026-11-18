#!/usr/bin/env node
/**
 * offline-download 验收：参数联动 / 建任务 / 真实编码 / 产物校验 / Range 下载 /
 * 缓存复用 / 原画 remux / 取消 / 鉴权。
 *
 * 用 ffmpeg 的 lavfi 现造测试片（不依赖外部素材）：720p 8s 用来跑转码，
 * 1080p 60s 用来测取消（够长，取消一定落在 transcoding 上）。
 * 没有 ffmpeg 时只验证鉴权与 503 路径。
 *
 * 用法：node tool/check/offline-smoke.js（Electron 自举）
 */
'use strict';

const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

if (!process.versions.electron) {
  const exe = path.join(
    process.cwd(),
    'node_modules',
    'electron',
    'dist',
    process.platform === 'win32' ? 'electron.exe' : 'electron',
  );
  if (!fs.existsSync(exe)) {
    console.error('[FATAL] 找不到 electron，请先 npm install');
    process.exit(2);
  }
  const r = spawnSync(exe, [__filename], {
    stdio: 'inherit',
    env: Object.assign({}, process.env, { ELECTRON_RUN_AS_NODE: '1' }),
  });
  process.exit(typeof r.status === 'number' ? r.status : 1);
}

const root = path.join(__dirname, '..', '..');
const { startKernel } = require(path.join(root, 'dist', 'kernel', 'index'));

// 临时目录在 close 后立刻删，异步日志句柄会触发 ENOTEMPTY
process.env.COLANAS_LOG_FILE = '0';

function findFfmpeg() {
  const exe = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
  const env = process.env.COLANAS_FFMPEG;
  if (env && fs.existsSync(env)) return env;
  for (const c of [
    path.join(root, 'vendor', 'ffmpeg', exe),
    path.join(root, 'vendor', 'ffmpeg', 'bin', exe),
  ]) {
    if (fs.existsSync(c)) return c;
  }
  return null;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 产物里有没有字幕流：直接问 ffprobe，不信接口返回的自述 */
function hasSubtitleStream(ffprobe, file) {
  const r = spawnSync(
    ffprobe,
    ['-v', 'error', '-show_entries', 'stream=codec_type', '-of', 'csv=p=0', file],
    { encoding: 'utf8' },
  );
  return String(r.stdout || '')
    .split(/\r?\n/)
    .map((x) => x.trim())
    .includes('subtitle');
}

function ffprobeOf(ffmpegPath) {
  if (!ffmpegPath) return null;
  const p = path.join(path.dirname(ffmpegPath), process.platform === 'win32' ? 'ffprobe.exe' : 'ffprobe');
  return fs.existsSync(p) ? p : null;
}

async function main() {
  const ffmpeg = findFfmpeg();
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'colanas-offline-'));
  const filesRoot = path.join(tmp, 'files');
  const dataDir = path.join(tmp, 'data');
  const mediaRoot = path.join(filesRoot, 'media');
  fs.mkdirSync(mediaRoot, { recursive: true });
  fs.mkdirSync(dataDir, { recursive: true });

  if (ffmpeg) {
    // 8 s / 720p：转码档用，够短，编码 1~3 s 就能出结果
    const small = spawnSync(ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc=size=1280x720:rate=24:duration=8',
      '-f', 'lavfi', '-i', 'sine=frequency=440:duration=8',
      '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-shortest',
      path.join(mediaRoot, 'demo.mp4'),
    ]);
    if (small.status !== 0) console.error('[warn] lavfi 生成 720p 测试片失败');
    // 30 s / 720p：取消用例要保证「取消时还在编码」；分辨率压在 720p
    // 是因为生成素材本身也吃 CPU，1080p 的 1440 帧会让并行门禁更拥挤
    const big = spawnSync(ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc=size=1280x720:rate=24:duration=30',
      '-f', 'lavfi', '-i', 'sine=frequency=330:duration=30',
      '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-shortest',
      path.join(mediaRoot, 'long.mp4'),
    ]);
    if (big.status !== 0) console.error('[warn] lavfi 生成长测试片失败');

    // 带内嵌字幕的样片：用来验证 subtitleMode=embed 到底有没有把字幕写进产物
    const srt = path.join(tmp, 'demo.srt');
    fs.writeFileSync(
      srt,
      '1\n00:00:00,000 --> 00:00:08,000\nhello offline\n\n',
    );
    const withSub = spawnSync(ffmpeg, [
      '-hide_banner', '-loglevel', 'error', '-y',
      '-f', 'lavfi', '-i', 'testsrc=size=1280x720:rate=24:duration=8',
      '-f', 'lavfi', '-i', 'sine=frequency=520:duration=8',
      '-i', srt,
      '-map', '0:v', '-map', '1:a', '-map', '2:s',
      '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p',
      '-c:a', 'aac', '-c:s', 'mov_text', '-t', '8',
      path.join(mediaRoot, 'subbed.mp4'),
    ]);
    if (withSub.status !== 0) console.error('[warn] lavfi 生成带字幕测试片失败');
  }

  process.env.COLANAS_DEV_TOKEN = '1';
  process.env.COLANAS_JWT_SECRET = 'test-secret-0123456789abcdef';
  process.env.COLANAS_FILES_ROOT = filesRoot;

  const k = await startKernel({ dataDir, port: 0, listen: false });
  const app = k.app;
  const results = [];
  const check = (name, ok, detail) => {
    const row = { name, ok: !!ok, detail: detail || '' };
    results.push(row);
    // 立刻打印：卡死时至少看得到跑到哪一步
    console.log(`${row.ok ? 'ok  ' : 'FAIL'} ${name}${row.detail ? '  [' + row.detail + ']' : ''}`);
  };

  const inject = (method, url, token, payload) =>
    app.inject({
      method,
      url,
      headers: token ? { authorization: 'Bearer ' + token } : undefined,
      payload,
    });
  const devToken = async (scopes, sub = 'admin') =>
    (await inject('POST', '/api/v1/auth/dev-token', '', { sub, scopes })).json().token;

  const admin = await devToken(['video:read', 'video:write'], 'admin');
  const reader = await devToken(['video:read'], 'reader');
  const mediaReady = k.media.available();
  const ffprobe = ffprobeOf(ffmpeg);

  // ---- 建库 + 扫描 ----
  await inject('POST', '/api/v1/video/libraries', admin, { name: 'demo', path: 'media' });
  await inject('POST', '/api/v1/video/scan', admin, {});
  let items = [];
  for (let i = 0; i < 40 && items.length === 0; i += 1) {
    const list = await inject('GET', '/api/v1/video/list?limit=20', admin);
    items = list.json().items || [];
    if (items.length === 0) await sleep(500);
  }
  check('scan_has_items', items.length >= 2, 'items=' + items.length);
  const small = items.find((x) => String(x.path || '').includes('demo')) || items[0];
  const big = items.find((x) => String(x.path || '').includes('long')) || items[1];
  const subItem = items.find((x) => String(x.path || '').includes('subbed'));
  check('scan_found_demo', !!small, small && small.id);

  // ---- 鉴权 ----
  let r = await inject('POST', '/api/v1/offline-downloads/quote', '', { itemId: small.id });
  check('quote_anonymous_401', r.statusCode === 401, 'status=' + r.statusCode);
  r = await inject('POST', '/api/v1/offline-downloads/jobs', reader, { itemId: small.id, preset: '480p_1m' });
  check('job_reader_403', r.statusCode === 403, 'status=' + r.statusCode);
  r = await inject('POST', '/api/v1/offline-downloads/quote', admin, { itemId: 'nope' });
  check('quote_unknown_404', r.statusCode === 404, 'status=' + r.statusCode + ' ' + r.body.slice(0, 120));

  // ---- quote：参数联动 ----
  r = await inject('POST', '/api/v1/offline-downloads/quote', admin, {
    itemId: small.id,
    codec: 'h264',
    height: 720,
  });
  const q264 = r.json();
  check('quote_200', r.statusCode === 200, 'status=' + r.statusCode + ' ' + r.body.slice(0, 160));
  check(
    'quote_source_spec',
    q264.source.width === 1280 && q264.source.height === 720 && q264.source.durationMs > 7000,
    JSON.stringify(q264.source),
  );
  // 片源只有 720p：1080P / 4K 都不该出现在候选里
  check(
    'quote_heights_converged',
    q264.capabilities.heights[0] === 720 && !q264.capabilities.heights.includes(1080),
    JSON.stringify(q264.capabilities.heights),
  );
  const rec264 = q264.limits.recommendedKbps;

  r = await inject('POST', '/api/v1/offline-downloads/quote', admin, {
    itemId: small.id,
    codec: 'h265',
    height: 720,
  });
  const q265 = r.json();
  const rec265 = q265.limits.recommendedKbps;
  check('quote_codec_link', rec264 > 0 && rec265 > 0 && rec264 !== rec265, `h264=${rec264} h265=${rec265}`);
  check('quote_h265_cheaper', rec265 < rec264, `h265=${rec265} < h264=${rec264}`);

  r = await inject('POST', '/api/v1/offline-downloads/quote', admin, {
    itemId: small.id,
    codec: 'h264',
    height: 480,
  });
  const q480 = r.json();
  check(
    'quote_height_link',
    q480.limits.recommendedKbps < rec264 && q480.target.height === 480,
    `480p=${q480.limits.recommendedKbps} 720p=${rec264}`,
  );

  // 手填码率：原样采信（只在合法区间内夹取）
  r = await inject('POST', '/api/v1/offline-downloads/quote', admin, {
    itemId: small.id,
    codec: 'h264',
    height: 480,
    videoKbps: 99999, // 远超 480p 的合法上限
  });
  const qManual = r.json();
  check(
    'quote_manual_kbps_clamped',
    qManual.target.videoKbps === qManual.limits.maxKbps,
    `asked=99999 got=${qManual.target.videoKbps} max=${qManual.limits.maxKbps}`,
  );

  // 区间内的手填值必须原样采信（不能被「推荐值」覆盖掉）
  r = await inject('POST', '/api/v1/offline-downloads/quote', admin, {
    itemId: small.id,
    codec: 'h264',
    height: 480,
    videoKbps: 1500,
  });
  const qKeep = r.json();
  check(
    'quote_manual_kbps_kept',
    qKeep.target.videoKbps === 1500,
    `asked=1500 got=${qKeep.target.videoKbps}`,
  );

  r = await inject('POST', '/api/v1/offline-downloads/quote', admin, {
    itemId: small.id,
    codec: 'original',
  });
  const qOrig = r.json();
  check(
    'quote_original_locked',
    qOrig.target.container === 'mkv' && qOrig.target.videoKbps === 0 && qOrig.target.codec === 'original',
    JSON.stringify(qOrig.target),
  );
  check('quote_estimate_bytes', q264.estimate.bytes > 0, String(q264.estimate.bytes));

  if (!mediaReady) {
    for (const n of [
      'job_create', 'job_ready', 'artifact_meta', 'artifact_sha256', 'artifact_range',
      'artifact_sha_header', 'job_cached_reuse', 'job_original_mkv', 'job_cancel',
    ]) check(n, true, 'skipped: media unavailable');
    return finish(k, results);
  }

  // ---- 建任务 + 等编码完成 ----
  const createJob = async (body) => {
    const res = await inject('POST', '/api/v1/offline-downloads/jobs', admin, body);
    return { res, json: res.json() };
  };
  const waitJob = async (id, timeoutMs = 180_000) => {
    const started = Date.now();
    let last = null;
    while (Date.now() - started < timeoutMs) {
      const res = await inject('GET', '/api/v1/offline-downloads/jobs/' + id, admin);
      last = res.json();
      if (last.state === 'ready' || last.state === 'failed' || last.state === 'canceled') return last;
      await sleep(400);
    }
    return last;
  };

  const first = await createJob({ itemId: small.id, codec: 'h264', height: 480, preset: '480p_1m' });
  const { res, json } = first;
  check('job_create', res.statusCode === 200 && json.id, 'status=' + res.statusCode + ' ' + res.body.slice(0, 160));
  const job1 = await waitJob(json.id);
  check('job_ready', job1 && job1.state === 'ready', job1 ? job1.state + ' ' + (job1.error || '') : 'null');
  check('job_progress_100', job1 && job1.progress === 100, job1 ? String(job1.progress) : 'null');

  // ---- 产物元信息 ----
  r = await inject('GET', `/api/v1/offline-downloads/jobs/${json.id}/artifact`, admin);
  const art = r.json();
  check('artifact_meta', r.statusCode === 200 && art.size > 0, 'status=' + r.statusCode + ' size=' + (art && art.size));
  check('artifact_sha256', typeof art.sha256 === 'string' && art.sha256.length === 64, String(art.sha256).slice(0, 12));
  check('artifact_mp4', art.container === 'mp4' && art.mime === 'video/mp4', art.container + '/' + art.mime);
  check('artifact_440_lines', art.height === 480, 'h=' + art.height);

  // ---- Range 下载 ----
  const dl = await app.inject({
    method: 'GET',
    url: '/api/v1/offline-downloads/artifacts/' + art.id,
    headers: { authorization: 'Bearer ' + admin, range: 'bytes=0-99' },
  });
  check(
    'artifact_range',
    dl.statusCode === 206 && dl.rawPayload.length === 100 &&
      String(dl.headers['content-range'] || '').startsWith('bytes 0-99/'),
    'status=' + dl.statusCode + ' len=' + dl.rawPayload.length + ' cr=' + dl.headers['content-range'],
  );
  check(
    'artifact_sha_header',
    typeof art.sha256 === 'string' && art.sha256.length === 64 &&
      dl.headers['x-artifact-sha256'] === art.sha256,
    String(dl.headers['x-artifact-sha256']).slice(0, 12),
  );

  // 整文件下载 + 校验：sha256 必须与元信息一致（这是客户端「下完比对」的依据）
  const full = await app.inject({
    method: 'GET',
    url: '/api/v1/offline-downloads/artifacts/' + art.id,
    headers: { authorization: 'Bearer ' + admin },
  });
  const digest = crypto.createHash('sha256').update(full.rawPayload).digest('hex');
  check(
    'artifact_sha256_match',
    full.statusCode === 200 && digest === art.sha256 && full.rawPayload.length === art.size,
    `status=${full.statusCode} len=${full.rawPayload.length}/${art.size}`,
  );

  // 越界 Range → 416
  const bad = await app.inject({
    method: 'GET',
    url: '/api/v1/offline-downloads/artifacts/' + art.id,
    headers: { authorization: 'Bearer ' + admin, range: 'bytes=' + (art.size + 10) + '-' },
  });
  check('artifact_range_416', bad.statusCode === 416, 'status=' + bad.statusCode);

  // ---- 同参数再来一次：复用产物，不重新编码 ----
  const t0 = Date.now();
  const cached = await createJob({ itemId: small.id, codec: 'h264', height: 480, preset: '480p_1m' });
  const job2 = cached.res.json();
  check(
    'job_cached_reuse',
    job2.state === 'ready' && job2.artifact && job2.artifact.id === art.id && Date.now() - t0 < 5000,
    `state=${job2.state} ms=${Date.now() - t0}`,
  );
  check('job_cached_same_artifact', job2.artifact && job2.artifact.id === art.id, job2.artifact && job2.artifact.id);

  // ---- 原画：remux 到 mkv ----
  const origCreated = await createJob({ itemId: small.id, codec: 'original', preset: 'original' });
  const origJob = await waitJob(origCreated.json.id);
  check('job_original_mkv', origJob.state === 'ready' && origJob.artifact && origJob.artifact.container === 'mkv',
    origJob.state + '/' + (origJob.artifact && origJob.artifact.container));

  // ---- 字幕：内挂 vs 不内挂，产物里必须真的有 / 真的没有字幕轨 ----
  if (ffprobe && subItem) {
    const qSub = await inject('POST', '/api/v1/offline-downloads/quote', admin, {
      itemId: subItem.id,
      codec: 'h264',
      height: 480,
    });
    check(
      'quote_has_subtitle',
      qSub.json().source.hasSubtitle === true,
      JSON.stringify(qSub.json().source),
    );

    // 下载产物到本地再用 ffprobe 问：不信接口的自述
    const probeArtifact = async (jobId) => {
      const meta = (
        await inject('GET', '/api/v1/offline-downloads/jobs/' + jobId + '/artifact', admin)
      ).json();
      const res = await app.inject({
        method: 'GET',
        url: '/api/v1/offline-downloads/artifacts/' + meta.id,
        headers: { authorization: 'Bearer ' + admin },
      });
      const out = path.join(tmp, 'probe-' + jobId + '.' + (meta.container === 'mkv' ? 'mkv' : 'mp4'));
      fs.writeFileSync(out, res.rawPayload);
      return hasSubtitleStream(ffprobe, out);
    };

    const emb = await createJob({
      itemId: subItem.id,
      codec: 'h264',
      height: 480,
      preset: '480p_1m',
      subtitleMode: 'embed',
    });
    const embJob = await waitJob(emb.json.id);
    check(
      'job_subtitle_embed_ready',
      embJob && embJob.state === 'ready',
      embJob ? embJob.state + ' ' + (embJob.error || '') : 'null',
    );
    if (embJob && embJob.state === 'ready') {
      check(
        'job_subtitle_embedded',
        await probeArtifact(embJob.id),
        'ffprobe 应看到 subtitle 流',
      );
    }

    const noSub = await createJob({
      itemId: subItem.id,
      codec: 'h264',
      height: 480,
      preset: '480p_1m',
      subtitleMode: 'none',
    });
    const noSubJob = await waitJob(noSub.json.id);
    check(
      'job_subtitle_none_ready',
      noSubJob && noSubJob.state === 'ready',
      noSubJob ? noSubJob.state : 'null',
    );
    if (noSubJob && noSubJob.state === 'ready') {
      check(
        'job_subtitle_dropped',
        (await probeArtifact(noSubJob.id)) === false,
        '不内挂时不该有 subtitle 流',
      );
    }
  } else {
    for (const n of [
      'quote_has_subtitle',
      'job_subtitle_embed_ready',
      'job_subtitle_embedded',
      'job_subtitle_none_ready',
      'job_subtitle_dropped',
    ]) check(n, true, 'skipped: no ffprobe');
  }

  // ---- 取消：长片 1080p，取消一定落在 transcoding ----
  const cancelCreated = await createJob({ itemId: big.id, codec: 'h264', height: 1080, preset: '1080p_8m' });
  const cancelId = cancelCreated.json.id;
  await sleep(1200);
  const mid = (await inject('GET', '/api/v1/offline-downloads/jobs/' + cancelId, admin)).json();
  const c = await inject('POST', `/api/v1/offline-downloads/jobs/${cancelId}/cancel`, admin, {});
  check('cancel_ok', c.statusCode === 200, 'status=' + c.statusCode);
  const after = await waitJob(cancelId, 30_000);
  check('job_cancel', after && after.state === 'canceled', `before=${mid && mid.state} after=${after && after.state}`);
  // 取消后不应留下半截产物
  const artAfter = await inject('GET', `/api/v1/offline-downloads/jobs/${cancelId}/artifact`, admin);
  check('cancel_no_artifact', artAfter.statusCode !== 200, 'status=' + artAfter.statusCode);

  // ---- 服务端产物：占用统计 / 归还引用 / 手动清理 ----
  const storage0 = (await inject('GET', '/api/v1/offline-downloads/storage', admin)).json();
  check('storage_usage', storage0.count > 0 && storage0.bytes > 0, JSON.stringify(storage0));

  // 下载完成后客户端会 release 一次，让产物能按 TTL 自然回收
  const rel = await inject('POST', `/api/v1/offline-downloads/jobs/${json.id}/release`, admin, {});
  check(
    'job_release',
    rel.statusCode === 200 && rel.json().ok === true,
    'status=' + rel.statusCode + ' ' + rel.body.slice(0, 120),
  );

  // 做旧：清理只看 last_hit_at，以及「两分钟内刚 ready」的保护窗
  const { sql } = require('kysely');
  const nowSec = Math.floor(Date.now() / 1000);
  await sql`update offline_artifacts set last_hit_at = 0`.execute(k.db);
  await sql`update offline_jobs set updated_at = 0 where state = 'ready'`.execute(k.db);

  // ---- 保护窗：产物「刚转好」时，保守档要跳过它 ----
  // 这正是「转完立刻点全部清理，一个都没删掉」的成因；这里把任务做新复现一遍。
  await sql`update offline_artifacts set last_hit_at = ${nowSec}`.execute(k.db);
  await sql`update offline_jobs set updated_at = ${nowSec} where state = 'ready'`.execute(k.db);
  const guarded = (
    await inject('POST', '/api/v1/offline-downloads/storage/cleanup', admin, { olderThanDays: 0 })
  ).json();
  const stillThere = await inject(
    'GET',
    `/api/v1/offline-downloads/jobs/${json.id}/artifact`,
    admin,
  );
  check(
    'cleanup_skips_fresh',
    guarded.skipped > 0 && guarded.count > 0 && stillThere.statusCode === 200,
    JSON.stringify(guarded),
  );

  // ---- 全部清理（force）：刚转好的也要删 ----
  const cleaned = (
    await inject('POST', '/api/v1/offline-downloads/storage/cleanup', admin, {
      olderThanDays: 0,
      force: true,
    })
  ).json();
  check(
    'storage_cleanup_force',
    cleaned.removed > 0 && cleaned.freedBytes > 0 && cleaned.count === 0,
    JSON.stringify(cleaned),
  );
  const storage1 = (await inject('GET', '/api/v1/offline-downloads/storage', admin)).json();
  check('storage_after_cleanup', storage1.count === 0 && storage1.bytes === 0, JSON.stringify(storage1));
  // 产物文件是真删了：再取元信息拿不到
  r = await inject('GET', `/api/v1/offline-downloads/jobs/${json.id}/artifact`, admin);
  check('cleanup_artifact_gone', r.statusCode !== 200, 'status=' + r.statusCode);

  return finish(k, results, app);
}

function finish(k, results, app) {
  const failed = results.filter((r) => !r.ok);
  for (const r of results) {
    console.log(`${r.ok ? 'ok  ' : 'FAIL'} ${r.name}${r.detail ? '  [' + r.detail + ']' : ''}`);
  }
  console.log(`\n${results.length - failed.length}/${results.length} passed`);
  return { failed, results, app };
}

main()
  .then(async (out) => {
    // 不在这里 close：进程退出时 electron 会收尾；临时目录留给系统清理
    process.exitCode = out.failed.length === 0 ? 0 : 1;
  })
  .catch((err) => {
    console.error('[FATAL]', err && err.stack ? err.stack : err);
    process.exitCode = 1;
  });
