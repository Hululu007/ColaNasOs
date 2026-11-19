#!/usr/bin/env node
/**
 * media sidecar（SP2-03）：缩略图 / 转码。
 *
 * 协议：
 *   invoke('thumb', { src, dst, size?, quality? }) -> { dst, ms }
 *   invoke('transcode', { src, dst, preset? })     -> { dst, ms, reused }
 *   invoke('bench', { src, dir, count?, size?, concurrency? }) -> { count, ms, throughput }
 *   invoke('stats')                                -> 计数器
 *
 * 「转码会话复用」：同一 (src,dst,preset) 的并发/重复请求共享同一个进行中任务，
 * 只会真正启动一次 ffmpeg，后到的请求拿 reused=true。
 */
'use strict';

const fs = require('node:fs');
const nodePath = require('node:path');
const { spawn } = require('node:child_process');
const { cpus, tmpdir } = require('node:os');

/** 画质档位表（由 tool/gen-play-quality.js 从 contracts/play-quality.json 生成） */
const PLAY_QUALITY = require('./play-quality.generated.json');
/** 硬件转码链路决策 + 片源能力解析（独立纯函数，便于 smoke 断言） */
const gpu = require('./gpu-pipeline');
const { detectHwaccels, decodePlans, CPU_PLAN, parseSource } = gpu;

process.stdin.setEncoding('utf8');
process.stdout.on('error', () => {
  /* 父进程已退出 */
});

let buf = '';
const send = (obj) => {
  if (process.stdout.writable) process.stdout.write(JSON.stringify(obj) + '\n');
};

/**
 * 找 ffmpeg：优先 `COLANAS_FFMPEG`（内核会传绝对路径），其次仓库自带的
 * `vendor/ffmpeg`，最后才退回 PATH。
 *
 * 顺序很重要：PATH 上常常是别的软件捎带的精简版 ffmpeg（实测 ImageMagick 那个
 * 7.0.1 essentials 没有 `scale_d3d11` / `tonemap_d3d11` / `libplacebo`），
 * 一旦用它，硬解零拷贝会因为「滤镜不存在」**静默退化成软解 + 硬编** ——
 * 速度掉一半还不报错，只有 `stats` 里的 filters 能看出来。
 */
function findFfmpeg() {
  const cands = [];
  const env = process.env.COLANAS_FFMPEG;
  if (env && env.trim()) cands.push(env.trim());
  const exe = process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg';
  const vendorRoot = nodePath.join(__dirname, '..', '..', 'vendor', 'ffmpeg');
  cands.push(nodePath.join(vendorRoot, exe), nodePath.join(vendorRoot, 'bin', exe));
  const hit = cands.find((p) => {
    try {
      return fs.existsSync(p);
    } catch {
      return false;
    }
  });
  return hit || exe;
}

const FFMPEG = findFfmpeg();
// 启动就把「用的哪个 ffmpeg + 缺哪些硬件滤镜」写进内核日志。
// 精简版 ffmpeg（PATH 上常见）缺 scale_d3d11 / tonemap_d3d11 / libplacebo 时，
// 零拷贝链会无声退化成「CPU 软解 + 硬编」，速度掉一半但一个错都不报 ——
// 只有看得到这行才能立刻定位。探测结果有缓存，代价是每进程一次 -filters。
try {
  const flt = gpu.detectFilters(FFMPEG);
  const lacks = [
    'scale_d3d11',
    'tonemap_d3d11',
    'scale_cuda',
    'tonemap_cuda',
    'scale_qsv',
    'libplacebo',
  ].filter((n) => !gpu.hasCap(flt, n));
  console.error(
    `[media] ffmpeg=${FFMPEG} 缺硬件滤镜=${lacks.join(',') || '无'}` +
      (lacks.length ? '（相关片源会退化成软解）' : ''),
  );
} catch {
  /* 探测失败不影响转码，按原有的逐级回退走 */
}

const stats = { thumbs: 0, transcodes: 0, reused: 0, fails: 0 };
const inflight = new Map();
const CONCURRENCY = Math.max(1, Math.min(Number(process.env.COLANAS_MEDIA_CONCURRENCY) || 4, 16));
const failedHwEncoders = new Set();

/** 正在跑的 HLS ffmpeg：dir → child。取消会话时按 dir 精确 kill，不误伤其它任务。 */
const activeHls = new Map();
/** 被主动取消的 dir（用于把「kill 导致的非零退出」标成 E_CANCELED，避免上层误判并重试） */
const canceledHls = new Set();

function runFfmpeg(args, timeoutMs = 120_000, opts = {}) {
  return new Promise((resolve, reject) => {
    // `cwd` 只给 HLS 用：ffmpeg 的 `-hls_fmp4_init_filename` 是相对**进程工作目录**解析的，
    // 不设就会把 init.mp4 丢到 sidecar 的启动目录（实测落在仓库根），播放器再请求 init.mp4 就 404。
    //
    // stdout 平时直接 ignore（每条命令都开一条管道纯属浪费）；只有传了 `progress`
    // 才接管：`-progress pipe:1` 往 stdout 写 NDJSON，是我们唯一能拿到编码进度的口子。
    const wantProgress = typeof opts.progress === 'function';
    const child = spawn(FFMPEG, args, {
      windowsHide: true,
      stdio: ['ignore', wantProgress ? 'pipe' : 'ignore', 'pipe'],
      cwd: opts.cwd || undefined,
    });
    const hlsKey = opts.hlsKey || null;
    if (hlsKey) activeHls.set(hlsKey, child);
    let err = '';
    let settled = false;
    const finish = (fn, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      clearInterval(watchTimer);
      fn(value);
    };
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        /* 忽略 */
      }
      finish(reject, Object.assign(new Error('ffmpeg timeout'), { code: 'E_TIMEOUT' }));
    }, timeoutMs);

    // 进度看门狗：HLS 只要迟迟不出首片、或出片后长时间不再增长，就认为这家编码器
    // 卡死了（实测 h264_amf 在 4K 源上出了第一片后挂住，30 分钟超时才报错，
    // 用户对着黑屏等半小时）。杀掉换下一条路径，比等 30 分钟好。
    let watchTimer = null;
    const watch = opts.watch;
    // 把「这一轮真正用上的编码」写进 <dir>/.session.json，上层 playerSessionGet 读它。
    // 为什么需要：选了 AV1 但机器上 AV1 编码器起不来时，sidecar 会**静默降级**
    // 回 H.264，而会话行要到整片转完才更新实际编码 —— 没有这个文件，播放中
    // 界面会一直显示 AV1（用户看到的就是「我选了 AV1，为什么还是 264」）。
    // 两个触发点：首片落盘（转码中就能看见）、正常退出（几秒的短片也补一份）。
    const writeSessionMeta = () => {
      if (!watch || !watch.dir || !watch.meta) return;
      try {
        fs.writeFileSync(
          nodePath.join(watch.dir, '.session.json'),
          JSON.stringify({ ...watch.meta, at: Date.now() }),
        );
      } catch {
        /* 写不了不影响转码本身 */
      }
    };
    if (watch && watch.dir) {
      const firstMs = Number(watch.firstMs) || 90000;
      const idleMs = Number(watch.idleMs) || 120000;
      const startedAt = Date.now();
      let lastCount = 0;
      let lastAt = startedAt;
      watchTimer = setInterval(() => {
        let count = 0;
        try {
          for (const f of fs.readdirSync(watch.dir)) {
            if (f.endsWith('.ts') || f.endsWith('.m4s')) count += 1;
          }
        } catch {
          count = -1; // 目录暂时读不到：先不判定
        }
        if (count < 0) return;
        if (count > lastCount) {
          const firstSegment = lastCount === 0;
          lastCount = count;
          lastAt = Date.now();
          // 首片落盘 = 这一轮确实跑起来了，转码中就能回显实际编码
          if (firstSegment) writeSessionMeta();
          return;
        }
        const nowMs = Date.now();
        const stuck = lastCount === 0 ? nowMs - startedAt >= firstMs : nowMs - lastAt >= idleMs;
        if (!stuck) return;
        try {
          child.kill('SIGKILL');
        } catch {
          /* 已退出 */
        }
        finish(
          reject,
          Object.assign(
            new Error(lastCount === 0 ? 'ffmpeg 首片超时' : 'ffmpeg 转码停滞'),
            { code: 'E_STALL' },
          ),
        );
      }, 2000);
      if (watchTimer.unref) watchTimer.unref();
    }

    child.stderr.on('data', (c) => {
      err += String(c);
      if (err.length > 8192) err = err.slice(-4096);
    });
    // `-progress pipe:1` 的输出形如 `out_time_us=12345678\nspeed=1.4x\n`，逐行解析。
    // 回调抛错一律吞掉：进度是观测，不能因为它把正在跑的编码带崩。
    if (wantProgress) {
      let pbuf = '';
      child.stdout.setEncoding('utf8');
      child.stdout.on('data', (c) => {
        pbuf += c;
        let idx = pbuf.indexOf('\n');
        while (idx >= 0) {
          const line = pbuf.slice(0, idx).trim();
          pbuf = pbuf.slice(idx + 1);
          const eq = line.indexOf('=');
          if (eq > 0) {
            try {
              opts.progress(line.slice(0, eq), line.slice(eq + 1));
            } catch {
              /* 观测失败不影响编码 */
            }
          }
          idx = pbuf.indexOf('\n');
        }
        // 兜底：没有换行的异常输出不能无限增长
        if (pbuf.length > 8192) pbuf = '';
      });
    }
    child.on('error', (e) => {
      if (hlsKey && activeHls.get(hlsKey) === child) activeHls.delete(hlsKey);
      finish(
        reject,
        Object.assign(new Error(`ffmpeg spawn failed: ${e.message}`), { code: 'E_NO_FFMPEG' }),
      );
    });
    child.on('exit', (code) => {
      if (hlsKey && activeHls.get(hlsKey) === child) activeHls.delete(hlsKey);
      if (canceledHls.delete(hlsKey)) {
        finish(reject, Object.assign(new Error('ffmpeg canceled'), { code: 'E_CANCELED' }));
        return;
      }
      if (code === 0) {
        // 短片（几秒的测试片）可能在整个 2s 采样周期内就跑完了，首片那次没赶上；
        // 正常退出补写一次，保证上层始终能拿到这一轮的实际编码
        writeSessionMeta();
        finish(resolve);
        return;
      }
      finish(
        reject,
        Object.assign(new Error(`ffmpeg exited ${code}: ${err.slice(-400)}`), { code: 'E_FFMPEG' }),
      );
    });
  });
}

/** 简易信号量：限制同时运行的 ffmpeg 数量 */
function createLimiter(n) {
  let active = 0;
  const queue = [];
  const next = () => {
    if (active >= n || queue.length === 0) return;
    active += 1;
    const { fn, resolve, reject } = queue.shift();
    fn()
      .then(resolve, reject)
      .finally(() => {
        active -= 1;
        next();
      });
  };
  return (fn) =>
    new Promise((resolve, reject) => {
      queue.push({ fn, resolve, reject });
      next();
    });
}

const limit = createLimiter(CONCURRENCY);

/**
 * 单文件编码（离线下载）单独排队，且只允许 1 路。
 *
 * 整片编码动辄几十分钟，占的是编码器本身而不是「一次处理」：跟播放一起排进
 * CONCURRENCY 的槽里，会让缩略图、字幕提取这些短任务排在它后面干等。
 * 限死 1 路 + encode() 里「播放正在转码就让位 CPU」的规则，才有「边看边下」。
 */
const encodeLimiter = createLimiter(1);

/**
 * GPU 零拷贝链路串行门：两路 AMF 并发会把编码器卡死（见 cancel() 的实测记录），
 * D3D11 设备 / 显存也不该让多路同时抢。CPU 软解链路不排队，照旧走 limit()。
 * 排队时不占 limit 槽，缩略图之类的 CPU 任务不会被饿死。
 */
let gpuTail = Promise.resolve();
function withGpuGate(fn) {
  const run = gpuTail.then(fn, fn);
  gpuTail = run.then(
    () => {},
    () => {},
  );
  return run;
}

/**
 * 抓取 ffmpeg 输出（不因退出码非 0 抛错）。
 * 探测流信息只能靠 `ffmpeg -i`（本机只带 ffmpeg，没有 ffprobe），它必然以 1 退出。
 */
function runCapture(args, timeoutMs = 60_000) {
  return new Promise((resolve) => {
    let out = '';
    let err = '';
    let child;
    try {
      child = spawn(FFMPEG, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    } catch (e) {
      resolve({ code: -1, stdout: '', stderr: String(e) });
      return;
    }
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        /* 已退出 */
      }
      resolve({ code: -1, stdout: out, stderr: err });
    }, timeoutMs);
    child.stdout.on('data', (c) => {
      out += String(c);
    });
    child.stderr.on('data', (c) => {
      err += String(c);
    });
    child.on('error', (e) => {
      clearTimeout(timer);
      resolve({ code: -1, stdout: out, stderr: err + String(e) });
    });
    child.on('exit', (code) => {
      clearTimeout(timer);
      resolve({ code, stdout: out, stderr: err });
    });
  });
}

/** 容器内的文本字幕编码器（图形字幕 PGS / DVD 无法转 WebVTT，不纳入列表） */
const TEXT_SUBTITLE_CODECS = new Set([
  'subrip',
  'srt',
  'ass',
  'ssa',
  'mov_text',
  'webvtt',
  'text',
  'microdvd',
  'subviewer',
  'subviewer1',
  'sami',
  'realtext',
  'jacosub',
  'vplayer',
]);

/**
 * 列出内嵌字幕轨（按 ffmpeg 的 `-i` 流信息解析）。
 * `index` 是该文件里第几条字幕流，直接可用于 `-map 0:s:<index>`。
 */
async function subtitleTracks(params) {
  const { src } = params || {};
  if (!src) throw Object.assign(new Error('src required'), { code: 'E_PARAM' });
  if (!fs.existsSync(src)) throw Object.assign(new Error('src not found: ' + src), { code: 'E_NO_SRC' });

  const r = await runCapture(['-hide_banner', '-loglevel', 'info', '-i', src]);
  const tracks = [];
  for (const line of String(r.stderr || '').split(/\r?\n/)) {
    // 例：Stream #0:2(eng): Subtitle: subrip (srt)
    const m = /Stream #\d+:(\d+)(?:\[[^\]]*\])?(?:\(([^)]+)\))?: Subtitle: ([^\s(]+)/.exec(line);
    if (!m) continue;
    const codec = String(m[3] || '').toLowerCase();
    tracks.push({
      index: tracks.length,
      lang: m[2] ? String(m[2]) : null,
      codec,
      text: TEXT_SUBTITLE_CODECS.has(codec),
    });
  }
  return { tracks };
}

/** 抽取一条字幕轨到文本文件（默认 srt；srt / webvtt 都支持，图形字幕会失败） */
async function extractSubtitle(params) {
  const { src, dst } = params || {};
  const index = Number(params && params.index);
  if (!src || !dst || !Number.isInteger(index) || index < 0) {
    throw Object.assign(new Error('src/dst/index required'), { code: 'E_PARAM' });
  }
  if (!fs.existsSync(src)) throw Object.assign(new Error('src not found: ' + src), { code: 'E_NO_SRC' });
  const format = String(params.format || 'srt').toLowerCase() === 'webvtt' ? 'webvtt' : 'srt';
  fs.mkdirSync(nodePath.dirname(dst), { recursive: true });
  await limit(() =>
    runFfmpeg(
      [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-i', src,
        '-map', `0:s:${index}`,
        '-c:s', format,
        dst,
      ],
      120_000,
    ),
  );
  if (!fs.existsSync(dst)) throw Object.assign(new Error('subtitle output missing'), { code: 'E_FFMPEG' });
  return { dst, ms: 0 };
}

async function thumb(params) {
  const { src, dst } = params || {};
  if (!src || !dst) throw Object.assign(new Error('src/dst required'), { code: 'E_PARAM' });
  const size = Math.max(16, Math.min(Number(params.size) || 256, 4096));
  const quality = Math.max(1, Math.min(Number(params.quality) || 4, 31));
  // 视频抽帧位置（秒）。`-ss` 放在 `-i` 前是快速定位（关键帧跳转），
  // 相册里长视频首帧多半是黑场，海报图必须从中间取。
  const at = Number(params.at) || 0;

  const started = process.hrtime.bigint();
  await limit(() =>
    runFfmpeg([
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      ...(at > 0 ? ['-ss', String(at)] : []),
      '-i',
      src,
      '-vf',
      `scale=${size}:-2:flags=lanczos`,
      '-frames:v',
      '1',
      '-q:v',
      String(quality),
      dst,
    ]),
  );
  stats.thumbs += 1;
  return { dst, ms: Number(process.hrtime.bigint() - started) / 1e6 };
}

function transcodeArgs(params) {
  const o = params.options || null;
  const args = ['-hide_banner', '-loglevel', 'error', '-y', '-i', params.src];

  // 兼容旧 preset（没有 options 时保持原行为）
  if (!o) {
    if (params.preset === 'web720') {
      args.push('-vf', 'scale=-2:720', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '23');
    } else if (params.preset === 'audio') {
      args.push('-vn', '-c:a', 'aac', '-b:a', '192k');
    } else {
      args.push('-c', 'copy');
    }
    args.push(params.dst);
    return args;
  }

  const mode = o.mode === 'audio' ? 'audio' : o.mode === 'image' ? 'image' : 'video';

  if (mode === 'image') {
    const size = Number(o.size) || 0;
    if (size > 0) {
      args.push('-vf', `scale='min(${size},iw)':-2:flags=lanczos`);
    }
    const quality = Math.max(1, Math.min(100, Number(o.quality) || 80));
    const q = Math.max(2, Math.min(31, Math.round(31 - (quality / 100) * 29)));
    args.push('-frames:v', '1', '-q:v', String(q), '-map_metadata', '0', '-an');
    args.push(params.dst);
    return args;
  }

  if (mode === 'audio') {
    const codecMap = {
      mp3: 'libmp3lame',
      m4a: 'aac',
      aac: 'aac',
      flac: 'flac',
      ogg: 'libvorbis',
      wav: 'pcm_s16le',
      opus: 'libopus',
      wma: 'wmav2',
    };
    const codec = codecMap[String(o.format || 'mp3').toLowerCase()] || 'aac';
    args.push('-vn', '-c:a', codec);
    const sampleRate = Number(o.sampleRate) || 0;
    if (sampleRate > 0) args.push('-ar', String(sampleRate));
    if (o.channels === 'mono') args.push('-ac', '1');
    else if (o.channels === 'stereo') args.push('-ac', '2');
    const bitrate = Number(o.bitrateKbps) || 0;
    if (bitrate > 0) args.push('-b:a', `${bitrate}k`);
    const threads = Number(o.threads) || 0;
    if (threads > 0) args.push('-threads', String(threads));
    args.push(params.dst);
    return args;
  }

  // video
  const vcodecRaw = String(o.vcodec || 'h264');
  const vcodec =
    vcodecRaw === 'copy' ? 'copy' : vcodecRaw === 'h265' ? 'libx265' : 'libx264';
  const acodecRaw = String(o.acodec || 'aac');
  const acodec = acodecRaw === 'copy' ? 'copy' : acodecRaw === 'mp3' ? 'libmp3lame' : 'aac';

  const resolution = String(o.resolution || 'source');
  if (resolution !== 'source' && vcodec !== 'copy') {
    if (resolution === '8k') args.push('-vf', 'scale=7680:-2');
    else if (resolution === '4k') args.push('-vf', 'scale=3840:-2');
    else {
      const height = {
        '1080p': 1080,
        '720p': 720,
        '480p': 480,
        '320p': 320,
        '240p': 240,
      }[resolution];
      if (height) args.push('-vf', `scale=-2:${height}`);
    }
  }

  if (vcodec !== 'copy') {
    args.push('-c:v', vcodec);
    const vbitrate = Number(o.vbitrateKbps) || 0;
    if (vbitrate > 0) args.push('-b:v', `${vbitrate}k`);
  } else {
    args.push('-c:v', 'copy');
  }
  if (acodec !== 'copy') {
    args.push('-c:a', acodec);
    const abrate = Number(o.abrateKbps) || 0;
    if (abrate > 0) args.push('-b:a', `${abrate}k`);
  } else {
    args.push('-c:a', 'copy');
  }
  const fps = Number(o.fps) || 0;
  if (fps > 0) args.push('-r', String(fps));
  const threads = Number(o.threads) || 0;
  if (threads > 0) args.push('-threads', String(threads));
  const format = String(o.format || '').toLowerCase();
  if (format === 'gif') args.push('-loop', '0', '-an');
  if (format === 'webp') args.push('-an');
  args.push(params.dst);
  return args;
}

function transcodeOnce(params) {
  const key = `${params.src}|${params.dst}|${params.preset || 'default'}|${JSON.stringify(params.options || null)}`;
  const existing = inflight.get(key);
  if (existing) {
    stats.reused += 1;
    return existing.then((r) => ({ ...r, reused: true }));
  }

  const job = (async () => {
    const started = process.hrtime.bigint();
    const args = transcodeArgs(params);
    await limit(() => runFfmpeg(args));
    stats.transcodes += 1;
    return { dst: params.dst, ms: Number(process.hrtime.bigint() - started) / 1e6, reused: false };
  })();

  inflight.set(key, job);
  return job.finally(() => {
    inflight.delete(key);
  });
}

async function transcode(params) {
  if (!params || !params.src || !params.dst) {
    throw Object.assign(new Error('src/dst required'), { code: 'E_PARAM' });
  }
  if (!fs.existsSync(params.src)) {
    throw Object.assign(new Error('src not found: ' + params.src), { code: 'E_NO_SRC' });
  }
  return transcodeOnce(params);
}

/** ffmpeg filter 参数里的路径转义（Windows 盘符与反斜杠） */
function escapeFilterPath(p) {
  return p.replace(/\\/g, '/').replace(/:/g, '\\:').replace(/'/g, "\\'");
}

/**
 * HLS 转码：产物统一 fMP4（**必须带 EXT-X-MAP**），h264 / h265 / av1 都是。
 *
 * 背景：AV1 / HEVC in MPEG-TS 本来就不稳；h264 以前走 MPEG-TS，但 TS 的 PTS
 * 从 1.483s 起、每片再 +2s，与静态列表的 EXTINF（0/2/4…）错开一拍，
 * hls.js 按列表建的 buffer 和分片时间戳对不上，seek 后容易卡住。
 * fMP4 的 tfdt 从 0 起、逐片 +2s，与 EXTINF 完全一致（实测见
 * docs/进度与下一步.md §159.8）。
 * 失败自动降级回 h264（兼容性优先），并在返回值里带回实际使用的编码与容器，
 * 便于上层显示与排障（不静默假装成功）。
 */
/**
 * 硬件编码器探测（进程内缓存一次）。
 *
 * 为什么需要：转码此前写死 `libx264 / libx265 / libsvtav1` —— 纯 CPU。4K 源会把
 * 8 核打满、风扇起飞，而这正是 NAS 最典型的负载。项目本来就选了带 QSV / VAAPI /
 * NVENC 的 jellyfin-ffmpeg，却一直没用上。
 *
 * 只探 Windows/Linux 上常见的三家（nvenc / qsv / amf）。**vaapi 不自动启用**：
 * 它要先 `-vaapi_device /dev/dri/renderDxxx` 再用 `hwupload` 滤镜，设备节点因机器而异，
 * 猜错就是整个转码失败 —— 宁可不用，也不要在用户机器上"偶发失败"。
 *
 * 探测不到就返回 null，调用方走 CPU 原路径：**没有任何机器会因此变慢或变坏**。
 */
/**
 * 全部可用的硬件编码器（按「画质/兼容性」排序），供「首选解码器」按厂商挑。
 *
 * **必须异步探测**：sidecar 是单线程的，之前用 spawnSync 逐个试编码器会把事件循环
 * 卡住十几秒，supervisor 的 10s 心跳直接超时并把进程 SIGKILL（smoke:player 实测）。
 * `-encoders` 列表只说明「build 里编进来了」，不代表本机真有硬件，所以逐个真编一帧。
 */
let hwAllCache = null;
let hwAllPromise = null;

/**
 * 硬件编码器探测结果落盘缓存。
 *
 * 实测：内核冷启动后第一次起流 8.2s，第二次 0.3s —— 差额几乎全是
 * 「逐个硬件编码器试编一帧」（AMF/NVENC/QSV 各一次，弱机上每次几秒）。
 * sidecar 进程一重启就重新付一遍，用户看到的就是「隔一会儿第一次播特别慢」。
 *
 * key = ffmpeg 路径 + 大小 + mtime：换了 ffmpeg 立刻失效；GPU 驱动换了可能
 * 命中旧结果，但真正用起来失败时 attempt() 会走 CPU 兜底，不会卡死。
 */
const HW_CACHE_TTL_MS = 7 * 86400_000;

function hwCacheFile() {
  return nodePath.join(tmpdir(), 'colanas-media-hwenc.json');
}

function hwCacheKey() {
  try {
    const ff = findFfmpeg();
    const st = fs.statSync(ff);
    return `${ff}|${st.size}|${Math.round(st.mtimeMs)}`;
  } catch {
    return '';
  }
}

function readHwCache(key) {
  if (!key) return null;
  try {
    const raw = JSON.parse(fs.readFileSync(hwCacheFile(), 'utf-8'));
    if (raw?.key !== key) return null;
    if (!raw?.at || Date.now() - raw.at > HW_CACHE_TTL_MS) return null;
    const out = raw.encoders;
    if (!out || !Array.isArray(out.h264) || !Array.isArray(out.h265) || !Array.isArray(out.av1)) {
      return null;
    }
    return out;
  } catch {
    return null;
  }
}

function writeHwCache(key, encoders) {
  if (!key) return;
  try {
    fs.writeFileSync(hwCacheFile(), JSON.stringify({ key, at: Date.now(), encoders }), 'utf-8');
  } catch {
    /* 缓存失败不影响转码 */
  }
}

/**
 * `ffmpeg -encoders` 的原始输出。
 *
 * **必须异步**：这里曾经是 `spawnSync(..., {timeout: 15000})`。ffmpeg 冷启动 +
 * 输出几百行 encoder 列表，在这台机器上实测能卡住事件循环好几秒；sidecar 是单线程，
 * 心跳（supervisor 2.5s 就判超时）一超时就 SIGKILL —— 正在跑的 4K 转码连带一起死，
 * 用户看到的就是「4K 一播就报错」。日志里 `[media] heartbeat timeout, killing for restart`
 * 紧跟着 `player hls failed (signal=SIGKILL)` 就是这个。
 */
function encoderListing() {
  return new Promise((resolve) => {
    let out = '';
    let done = false;
    const finish = (text) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve(text);
    };
    let child;
    try {
      child = require('node:child_process').spawn(findFfmpeg(), ['-hide_banner', '-encoders'], {
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'ignore'],
      });
    } catch {
      return resolve('');
    }
    const timer = setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        /* 已退出 */
      }
      finish(out);
    }, 15000);
    child.stdout.setEncoding('utf8');
    child.stdout.on('data', (chunk) => {
      out += chunk;
    });
    child.on('error', () => finish(''));
    child.on('close', () => finish(out));
  });
}

/** 实测某个硬件编码器能否用（1 帧 lavfi → null）。失败就当没有，绝不靠名字猜。 */
async function probeEncoder(name) {
  try {
    await runFfmpeg(
      [
        '-hide_banner', '-loglevel', 'error', '-y',
        '-f', 'lavfi', '-i', 'testsrc=size=320x240:rate=1',
        '-frames:v', '1', '-c:v', name, '-f', 'null', '-',
      ],
      15000,
    );
    return true;
  } catch {
    return false;
  }
}

async function detectHwAll() {
  if (hwAllCache) return hwAllCache;
  if (hwAllPromise) return hwAllPromise;
  hwAllPromise = (async () => {
    const cacheKey = hwCacheKey();
    const cached = readHwCache(cacheKey);
    if (cached) {
      hwAllCache = cached;
      return cached;
    }
    const out = { h264: [], h265: [], av1: [] };
    const listing = await encoderListing();
    const map = { h264: 'h264_', h265: 'hevc_', av1: 'av1_' };
    const candidates = [];
    for (const kind of ['h264', 'h265', 'av1']) {
      for (const vendor of ['nvenc', 'qsv', 'amf']) {
        const name = map[kind] + vendor;
        if (listing.includes(name)) candidates.push([kind, name]);
      }
    }
    // 串行验证（并行 9 个 ffmpeg 会把弱机瞬间打满）；结果缓存，只付一次成本
    for (const [kind, name] of candidates) {
      if (await probeEncoder(name)) out[kind].push(name);
    }
    hwAllCache = out;
    writeHwCache(cacheKey, out);
    return out;
  })();
  return hwAllPromise;
}

/** 按 codec 给出编码器参数（不含 `-c:v`）。`allowHw=false` 时强制 CPU；`prefer` 限定厂商。 */
function videoCodecArgs(codec, allowHw, prefer = 'auto', hw = null, targetKbps = 0) {
  const kind = codec === 'h265' ? 'h265' : codec === 'av1' ? 'av1' : 'h264';
  const kbps = Number(targetKbps) > 0 ? Math.round(Number(targetKbps)) : 0;
  let enc = null;
  if (allowHw) {
    const list = ((hw || { h264: [], h265: [], av1: [] })[kind] || []).filter(
      (name) => !failedHwEncoders.has(name),
    );
    if (prefer === 'cpu') enc = null;
    else if (prefer === 'auto' || !prefer) enc = list[0] || null;
    else enc = list.find((n) => n.endsWith('_' + prefer)) || null;
  }
  if (enc) {
    // 硬件编码器**必须给目标码率**：以前只给 -cq / -qp_i（恒定质量），
    // AMF 实测完全忽略后面的 -maxrate，1080p/1.4Mbps 的档位吐出 20~30 Mbps
    // 的分片（6 秒 24MB），边转边播时播放器一直在缓冲、局域网也被打满。
    if (kbps > 0) {
      if (enc.endsWith('_nvenc')) {
        return {
          args: [
            enc,
            '-preset',
            'p4',
            '-tune',
            'll',
            '-bf',
            '0',
            '-rc',
            'vbr',
            '-b:v',
            `${kbps}k`,
          ],
          encoder: enc,
        };
      }
      if (enc.endsWith('_qsv')) {
        return {
          args: [
            enc,
            '-preset',
            'veryfast',
            '-look_ahead',
            '0',
            '-async_depth',
            '1',
            '-bf',
            '0',
            '-b:v',
            `${kbps}k`,
          ],
          encoder: enc,
        };
      }
      // AMF：vbr_peak + 目标码率。注意 `-rc` 只认 cqp/cbr/vbr_peak/vbr_latency/
      // qvbr/hqvbr/hqcbr（写 `vbr` 会直接 "Error applying encoder options"，
      // 整个转码起不来）；CQP 与 -maxrate 不兼容，所以必须切到码率模式。
      return {
        args: [
          enc,
          // 780M 实测 lowlatency 可用（ultralowlatency 也支持，画质更差）；
          // 只影响首帧/缓冲，不改变码率目标。
          '-usage',
          'lowlatency',
          '-quality',
          'speed',
          '-rc',
          'vbr_peak',
          '-b:v',
          `${kbps}k`,
          '-maxrate',
          `${Math.round(kbps * 1.5)}k`,
          '-bufsize',
          `${kbps * 2}k`,
        ],
        encoder: enc,
      };
    }
    if (enc.endsWith('_nvenc')) {
      // p4 = 均衡档；-cq 是恒定质量（数值语义接近 crf）
      return { args: [enc, '-preset', 'p4', '-cq', kind === 'h264' ? '23' : '28'], encoder: enc };
    }
    if (enc.endsWith('_qsv')) {
      return {
        args: [enc, '-preset', 'veryfast', '-global_quality', kind === 'h264' ? '23' : '28'],
        encoder: enc,
      };
    }
    // AMF 的 balanced 在部分机器上慢得离谱（实测 4K 源只有 ~0.2x 实时），
    // 边转边播场景速度优先：speed 档 + 显式 qp，画质差异在 1080p/720p 档可接受。
    return {
      args: [enc, '-quality', 'speed', '-qp_i', kind === 'h264' ? '23' : '28'],
      encoder: enc,
    };
  }
  // CPU 路径同样按「边转边播」取舍：AV1 默认 preset=10 时 4K 源慢到 30 分钟都出不了片
  // （实测会话直接超时 1800000ms），这里取最快档；H.265 用 ultrafast 而不是 medium。
  if (kind === 'h265')
    return {
      args: [
        'libx265',
        '-preset',
        'ultrafast',
        '-tune',
        'zerolatency',
        '-x265-params',
        'rc-lookahead=0:bframes=0:scenecut=0',
        '-crf',
        '28',
        '-tag:v',
        'hvc1',
      ],
      encoder: 'libx265',
    };
  if (kind === 'av1') return { args: ['libsvtav1', '-preset', '12', '-crf', '32'], encoder: 'libsvtav1' };
  return {
    args: [
      'libx264',
      '-preset',
      'veryfast',
      '-tune',
      'zerolatency',
      '-x264-params',
      'rc-lookahead=0:sync-lookahead=0:bframes=0:scenecut=0',
      '-crf',
      '23',
    ],
    encoder: 'libx264',
  };
}

function rememberHwEncoderFailure(encoder, error) {
  if (
    !encoder ||
    gpu.vendorOf(encoder) === 'cpu' ||
    !gpu.isHardwareEncoderInitializationFailure(error) ||
    failedHwEncoders.has(encoder)
  ) {
    return;
  }
  failedHwEncoders.add(encoder);
  console.error(`[media] disabling ${encoder} after encoder initialization failure`);
}

function assertHwEncoderAvailable(encoder) {
  if (!failedHwEncoders.has(encoder)) return;
  throw Object.assign(
    new Error(`hardware encoder ${encoder} disabled after initialization failure`),
    { code: 'E_HW_ENCODER_DISABLED' },
  );
}

/**
 * 片源能力探测：只用 `ffmpeg -i` 的 stderr（本机没有 ffprobe），按 (路径, mtime, size)
 * 缓存，同一部片换档位不会重复起进程。探测失败返回空对象，链路会保守退回 CPU。
 */
const sourceCache = new Map();
async function probeSourceInfo(src) {
  let stat;
  try {
    stat = fs.statSync(src);
  } catch {
    return gpu.EMPTY_SOURCE;
  }
  const key = `${stat.mtimeMs}|${stat.size}`;
  const hit = sourceCache.get(src);
  if (hit && hit.key === key) return hit.info;
  const r = await runCapture(['-hide_banner', '-loglevel', 'info', '-i', src], 20_000);
  const info = parseSource(r.stderr);
  sourceCache.set(src, { key, info });
  if (sourceCache.size > 256) sourceCache.delete(sourceCache.keys().next().value);
  return info;
}

/**
 * 编码方案解析（HLS 与单文件 encode 共用）。
 *
 * 把「片源探测 → 档位收敛 → 编码/码率 → HDR→SDR → 解码链路」整体抽出来：
 * 边转边播的分片和离线下载的单文件，差别只在下游的 ffmpeg 输出参数。
 * 针对片源兼容性的修补必须同时作用于两条产出 —— 各写一份迟早会漂。
 *
 * @param {object} params hls / encode 的入参（preset/codec/height/subtitle/audioIndex/…）
 * @param {string} tag    日志前缀（hls / encode），只用于排障时区分来源
 */
async function resolveEncodePlan(params, tag) {
  const src = params.src;

  const presetRow =
    PLAY_QUALITY.presets.find((p) => p.key === params.preset) ||
    PLAY_QUALITY.presets.find((p) => p.key === PLAY_QUALITY.defaultPreset) ||
    PLAY_QUALITY.presets[0];
  // 目标高度：片源比档位矮就跟着片源走。
  // 720P 档 + 480P 片源不该放大成 720P（更大更糊还多占带宽），540P 片源
  // 也不该被塞进 480P 档；编码器要求偶数高度，奇数向下取偶。
  const srcHeight = Number(params.height) || 0;
  const presetHeight = Number(presetRow.height) || 0;
  const wantedHeight =
    srcHeight > 0 && presetHeight > 0
      ? Math.min(srcHeight, presetHeight)
      : presetHeight || srcHeight;
  const height = wantedHeight > 0 ? wantedHeight - (wantedHeight % 2) : 0;
  // 片源真实能力：比库里的 hdr 标记可信。
  //
  // 库里的 dolby_vision / hdr10 是扫描期写进去的，老库可能整批是 0（早期解析把
  // `Side data:` 的缩进子行丢掉了，见 src/modules/video/ffmpeg.ts）。一旦按
  // 「不需要 HDR→SDR」转码，DV Profile 5 的 IPTPQc2 就被当成普通 BT.2020 直出，
  // 浏览器里是一整片偏绿/偏紫 —— 这不是用户选项，是坏画面。
  // 所以每次起转码都自己 `ffmpeg -i` 读一遍（带 mtime/size 缓存），片源说了算。
  const source = await probeSourceInfo(src);
  const sourceNeedsTonemap = Number(source.dvProfile) > 0 || Boolean(source.hasHdrMeta);
  // 「原画（copy）」= 不转码，所以输出编码必须**等于片源编码**，不能一律当 h264。
  // 只允许 H.264 直通，理由是「AV1 / HEVC 复制进 MPEG-TS 解不出来」——
  // 容器统一 fMP4（带 EXT-X-MAP）之后这条不再成立：实测 hls.js 1.4.10 + Chrome 157
  // 播 HEVC/AV1 的 fMP4 正常（buffered 连续、seek 正常、powerEfficient=true 硬解）。
  //
  // 编码取 ffprobe 实测（`probeSourceInfo` 刚跑过）：库里的 video_codec 对老库
  // 整批不可信，实测拿不到才退回上层传来的标记。
  const srcCodec = String(source.codec || params.srcVideoCodec || '').toLowerCase();
  const srcMapped = /h264|avc/.test(srcCodec)
    ? 'h264'
    : /hevc|h265/.test(srcCodec)
      ? 'h265'
      : /av1/.test(srcCodec)
        ? 'av1'
        : '';
  const wantCodec = PLAY_QUALITY.codecs.some((c) => c.key === params.codec)
    ? params.codec
    : PLAY_QUALITY.defaultCodec;
  // 原画直通：会话是 `preset=original` 时由内核置位。此时片源自带 DV / HDR10+
  // 元数据是要交给电视的资产，不能因为「自动检测到 HDR」就 tone-map 掉；
  // 输出编码也不看请求的档位，就是片源编码本身。
  const passthrough =
    params.passthrough === true &&
    presetRow.copy === true &&
    !params.subtitle &&
    !!srcMapped;
  const hdrToSdr =
    !passthrough &&
    params.toneMap !== false &&
    (params.hdrToSdr === true || sourceNeedsTonemap);
  if (sourceNeedsTonemap && !passthrough && params.hdrToSdr !== true) {
    console.error(
      `[media] ${tag} 片源是 ${source.hdrKind}${source.dvProfile ? ` P${source.dvProfile}` : ''}，` +
        '库标记缺失，按片源自动启用 HDR→SDR',
    );
  }
  // 普通「原画」仍要求「请求编码 == 片源编码」：客户端请求 h265 前会用
  // `MediaSource.isTypeSupported('hvc1…')` 探过，请求什么就说明它能解什么；
  // 不看请求直接吐 HEVC 会让 Firefox 黑屏。直通会话例外，见上。
  const copyVideo =
    presetRow.copy === true &&
    !params.subtitle &&
    !hdrToSdr &&
    !!srcMapped &&
    (passthrough || srcMapped === wantCodec);
  // 目标码率：离线下载允许手填（`videoKbps`），播放只能吃档位表。
  // 手填值原样采信 —— 合法区间在服务端 quote 里已经夹过，这里再夹一次只会让
  // 两端显示的数字对不上（用户填 2500，界面显示 2500，实际编码 1800）。
  const manualKbps = Number(params.videoKbps) || 0;
  const targetKbps = copyVideo
    ? 0
    : manualKbps > 0
      ? manualKbps
      : Number((presetRow.bitrates || {})[wantCodec] || presetRow.videoBitrateKbps || 0);
  // original 档 height=0：scale=-2:0 非法，改成保持原分辨率的合法滤镜
  const scale = height > 0 ? `scale=-2:${height}` : 'scale=iw:-2';
  const subtitleFilter = params.subtitle
    ? "subtitles='" + escapeFilterPath(params.subtitle) + "'"
    : '';
  // 非 copy 统一输出 8-bit + BT.709 标记，避免 10-bit / 未标记色彩在浏览器发灰
  const tailParts = [scale];
  if (subtitleFilter) tailParts.push(subtitleFilter);
  if (!copyVideo) tailParts.push('format=yuv420p');
  // 片源能力决定 tonemap 链：DV P5 / 无标记 10-bit 的 `zscale=t=linear` 实测直接
  // `-22 Invalid argument`；现在软件帧链自动切到 libplacebo/Vulkan，
  // 硬件帧链用滤镜自带的 apply_dovi（d3d11 / cuda 默认开启）。
  let pipelineCtx = null;
  const cpuFilter = (tonemapOn) => gpu.cpuFilter(pipelineCtx, tonemapOn);
  const timeoutMs = Math.max(Number(params.timeoutMs) || 0, 30 * 60 * 1000);
  // 首选解码器（auto / nvenc / qsv / amf / cpu）：只影响「用哪家硬件」，不影响编码格式
  const prefer = String(params.hwaccel || 'auto');
  // 响度归一：由库级开关决定（video_libraries.audio_normalize），这里只负责把它变成 ffmpeg 参数。
  // 用 dynaudnorm 而不是 loudnorm：单遍、实时友好，适合边转边播。
  const audioFilter = String(params.audioFilter || '').trim();
  // 音轨序号：默认 0；负数 / 非整数回落 0
  const an = Number(params.audioIndex);
  const audioIndex = Number.isInteger(an) && an >= 0 ? an : 0;
  // 直通时音轨也尽量不重编码：fMP4 能安全容纳的常见编码直接 copy。
  // 响度归一 / 降混要改音频，只能走 AAC 重编码；TrueHD / DTS 进 MP4 不稳，
  // 也交给 AAC，避免出一条解不出来的音轨。
  const srcAudio = String(params.srcAudioCodec || '').toLowerCase();
  const audioCopy =
    copyVideo &&
    !audioFilter &&
    /^(aac|ac3|eac3|mp3|flac|opus|alac)$/.test(srcAudio);
  // 硬件编码器探测（异步 + 缓存）：不阻塞心跳，结果供所有 attempt 复用
  const hw = await detectHwAll();
  // 原画直通只可能是「片源编码未变」：容器 / 编码标签必须跟着实际输出走，
  // 否则会出现「界面显示 AV1、实际拷的是 H.264 却塞进 fMP4」的错位。
  const outputCodec = copyVideo ? srcMapped : wantCodec;
  // 解码方案按编码器所属厂商分派：AMD→D3D11、NVIDIA→CUDA、Intel→QSV；
  // 三家都用「硬解 → 显存内 tonemap/scale → 硬编」零拷贝，失败逐级回退。
  const primaryEncoder = videoCodecArgs(outputCodec, true, prefer, hw).encoder;
  pipelineCtx = {
    platform: process.platform,
    hwaccels: detectHwaccels(FFMPEG),
    filters: gpu.detectFilters(FFMPEG),
    encoder: primaryEncoder,
    prefer,
    copyVideo,
    subtitle: params.subtitle,
    subtitleFilter,
    hdrToSdr,
    height,
    source,
    tailParts,
  };
  const plans = decodePlans(pipelineCtx);

  return {
    presetRow,
    srcHeight,
    height,
    source,
    sourceNeedsTonemap,
    hdrToSdr,
    srcCodec,
    srcMapped,
    wantCodec,
    copyVideo,
    targetKbps,
    scale,
    subtitleFilter,
    tailParts,
    pipelineCtx,
    cpuFilter,
    timeoutMs,
    prefer,
    audioIndex,
    audioFilter,
    audioCopy,
    passthrough,
    hw,
    outputCodec,
    plans,
  };
}

async function hls(params) {
  const { src, dir } = params || {};
  if (!src || !dir) throw Object.assign(new Error('src/dir required'), { code: 'E_PARAM' });
  if (!fs.existsSync(src))
    throw Object.assign(new Error('src not found: ' + src), { code: 'E_NO_SRC' });

  // 分段续转：从片源的第 seekMs 毫秒开始，只转 limitMs 毫秒。
  // 两个都是**输入侧**选项（必须排在 -i 之前）；0 / 缺省 = 从片头转到片尾（原行为）。
  // 每段是独立的 init.mp4 + 分片，由上层把多段拼成一份播放列表，
  // 段与段之间用 #EXT-X-DISCONTINUITY 隔开（实测 hls.js 会自动追加新的 init）。
  const seekMs = Math.max(0, Number(params.seekMs) || 0);
  const limitMs = Math.max(0, Number(params.limitMs) || 0);
  const rangeArgs = [
    ...(seekMs > 0 ? ['-ss', (seekMs / 1000).toFixed(3)] : []),
    ...(limitMs > 0 ? ['-t', (limitMs / 1000).toFixed(3)] : []),
  ];

  fs.mkdirSync(dir, { recursive: true });
  // 新会话复用同一目录时先把「已取消」标记清掉；同一次 hls() 内部的重试不清，
  // 否则被抢占的旧会话会在重试里继续跑、和新会话抢 GPU。
  canceledHls.delete(dir);
  const {
    source,
    sourceNeedsTonemap,
    hdrToSdr,
    srcMapped,
    copyVideo,
    targetKbps,
    cpuFilter,
    timeoutMs,
    prefer,
    audioIndex,
    audioFilter,
    audioCopy,
    passthrough,
    hw,
    outputCodec,
    plans,
  } = await resolveEncodePlan(params, 'hls');

  const attempt = async (codec, allowHw = true, plan = CPU_PLAN, tonemapOn = true) => {
    // 被抢占（换档 / 新会话）时立即收手：旧会话的重试链不能再起新 ffmpeg
    if (canceledHls.has(dir)) {
      throw Object.assign(new Error('ffmpeg canceled'), { code: 'E_CANCELED' });
    }
    // 封装由契约决定：h264 / h265 / av1 统一 fMP4（带 EXT-X-MAP）
    const container =
      (PLAY_QUALITY.codecs.find((c) => c.key === codec) || {}).container || 'mpegts';
    const fmp4 = container === 'fmp4';
    // 硬件编码能探测到就用（参数见 videoCodecArgs），否则原样走 CPU
    const vc = videoCodecArgs(codec, allowHw, prefer, hw, targetKbps);
    const vCodec = vc.args;
    // 硬件计划自带显存内滤镜；其余计划走软件帧滤镜（含 libplacebo 回退）。
    const vf = plan.filter ? plan.filter(tonemapOn) : cpuFilter(tonemapOn);

    // 清掉上一次尝试的产物，避免残留 index.m3u8 让「降级」误判成功
    for (const f of fs.existsSync(dir) ? fs.readdirSync(dir) : []) {
      try {
        fs.unlinkSync(nodePath.join(dir, f));
      } catch {
        /* 忽略 */
      }
    }

    const args = [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      // `-ss` / `-t` 是输入选项，必须在 `-i` 之前；`-hwaccel*` 同样。
      ...rangeArgs,
      ...plan.inputArgs,
      // 入库时已经 ffprobe 过；起流只要读头部就够。默认 5MB/5s 的探测在
      // 4K 多音轨 MKV 上实测要 1~3s，是首片延迟的大头之一。
      // 只认头部元数据，不靠它做流选择（下面 -map 是显式的）。
      '-probesize',
      '2M',
      '-analyzeduration',
      '0',
      '-i',
      src,
      // 显式选流：视频第 0 条、指定音轨（`?` 让越界时不选音轨而非整片失败）
      '-map',
      '0:v:0',
      '-map',
      `0:a:${audioIndex}?`,
      // 字幕由播放器侧渲染（外挂）或单独烧录，不走默认字幕流；
      // 数据流（章节 / 时间码）更没用。MKV 里几十条轨会明显拖慢起流。
      '-sn',
      '-dn',
      // 直通时把 HEVC 的 sample entry 标成 `hvc1`：MKV 源多是 `hev1`（参数集可随
      // 分片变动），`hvc1` 要求参数集只在 init.mp4 里出现一次。ffmpeg 只改这个
      // 四字符标签、不重编，Chrome / Safari / libmpv 都按 hvc1 走硬件解码。
      ...(copyVideo
        ? ['-c:v', 'copy', ...(srcMapped === 'h265' ? ['-tag:v', 'hvc1'] : [])]
        : ['-vf', vf, '-c:v', ...vCodec]),
      // 色彩标记：输出统一标为 BT.709 SDR，避免播放器按源元数据乱解
      ...(!copyVideo
        ? ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709']
        : []),
      // CRF 定质量 + maxrate 兜住流量上限（原画直通不控码率）
      ...(!copyVideo && targetKbps > 0
        ? ['-maxrate', `${targetKbps}k`, '-bufsize', `${targetKbps * 2}k`]
        : []),
      ...(audioFilter ? ['-af', audioFilter] : []),
      // GOP / 强制关键帧只对**编码器**有意义。视频 copy 时下这些参数不会生效，
      // 还会让部分 ffmpeg 构建报「Codec AVOption g specified, but ... not used」；
      // 直通的分片切在片源自己的关键帧上，播放列表也因此改读 ffmpeg 直出的那份。
      ...(!copyVideo
        ? [
            '-g', '48', '-keyint_min', '48', '-sc_threshold', '0',
            // 强制每 2s 一个 IDR：-hls_time 2 才能真正切在 2s，而不是按帧率漂移。
            '-force_key_frames', 'expr:gte(t,n_forced*2)',
          ]
        : []),
      // 直通且音轨能安全塞进 fMP4 时连音频一起 copy，TrueHD / DTS / Atmos
      // 原样保留；否则（或开了响度归一 / 降混）转 AAC 双声道。
      ...(audioCopy
        ? ['-c:a', 'copy']
        : [
            '-c:a', 'aac',
            '-b:a', String(PLAY_QUALITY.audioBitrateKbps) + 'k',
            '-ac', '2',
          ]),
      // 响度归一（dynaudnorm）会先扣住音频再吐：整片模式没有 `-t` 时 ffmpeg
      // 不知道终点，视频已经写出两片、音频才带着原始 PTS 追上来，muxer 不能
      // 往回写 → **前两片只剩视频**，音频从 0 重新开始。
      // 浏览器侧（hls.js）表现为「播到 7 秒卡死、buffered 从 7.5 起」：
      // 实测 4K DV + 电影库（audioNormalize=1）必现，关掉归一就正常。
      // `-max_interleave_delta 0` 让 muxer 等两条流对齐再落片；只在开归一时加，
      // 免得让普通片源的首片白等几秒。
      ...(audioFilter ? ['-max_interleave_delta', '0'] : []),
      '-f',
      'hls',
      // 2s 一片：首片只等 2s 内容。客户端播放列表按同一常量（SEG_MS=2000）
      // 预列分片，两处必须一致，否则 seek 会漂。
      '-hls_time',
      '2',
      '-hls_init_time',
      '2',
      // VOD 要等全片转完才写 index.m3u8：4K HDR 整片几十分钟，期间一个分片
      // 都播不了。EVENT 在第一个分片落盘时就写出播放列表并持续追加，hls.js
      // 按 live 语义定时刷新 → 边转边播。list_size=0 保留全部分片，
      // 否则默认滚动窗口只有 5 片，用户没法拖回片头。
      '-hls_playlist_type',
      'event',
      '-hls_list_size',
      '0',
      // 分片先写 .tmp 落完再改名：边转边播时播放器会立刻按播放列表去取最新分片，
      // 直接写目标名会让它读到写了一半的 m4s/ts（fMP4 尤其致命：init 之后的
      // 分片解析失败 → 播放器反复重启 demuxer，表现成「一直在缓冲、点了也不播」）。
      '-hls_flags',
      'temp_file',
    ];
    if (fmp4) {
      args.push(
        '-hls_segment_type',
        'fmp4',
        '-hls_fmp4_init_filename',
        'init.mp4',
        '-hls_segment_filename',
        nodePath.join(dir, 'seg%05d.m4s'),
      );
    } else {
      args.push('-hls_segment_filename', nodePath.join(dir, 'seg%05d.ts'));
    }
    args.push(nodePath.join(dir, 'index.m3u8'));

    // 钉子：把这一轮真正下发的 ffmpeg 参数落一份到会话目录里。
    // 「同样的片源，浏览器里首片没有音轨」这种问题，光看 kernel.log 猜不出是
    // 哪条滤镜/哪个候选跑出来的 —— 参数在手才能原样复跑。
    try {
      fs.writeFileSync(
        nodePath.join(dir, '.ffmpeg-args.json'),
        JSON.stringify(
          { container: fmp4 ? 'fmp4' : 'mpegts', codec, plan: plan.pipeline,
            passthrough, copyVideo, audioCopy, args },
          null,
          1,
        ),
      );
    } catch {
      /* 目录被清理 / 无权限都无所谓 */
    }

    const started = process.hrtime.bigint();
    const exec = () =>
      limit(() => Promise.resolve().then(() => {
        if (!copyVideo) assertHwEncoderAvailable(vc.encoder);
        return runFfmpeg(args, timeoutMs, {
          cwd: dir,
          hlsKey: dir,
          watch: {
            dir,
            firstMs: Number(process.env.COLANAS_HLS_FIRST_SEGMENT_MS) || 90000,
            idleMs: Number(process.env.COLANAS_HLS_STALL_MS) || 120000,
            // 首片落盘时写 <dir>/.session.json，供上层回显「实际用上的编码」。
            // 直通（copy）没有编码器 / 解码器参与，别把 `hevc_amf`+`cpu` 写出去 ——
            // 界面会显示「CPU 软解」，用户以为在烧 CPU，实际一个像素都没重编。
            meta: {
              codec,
              container: fmp4 ? 'fmp4' : 'mpegts',
              encoder: copyVideo ? 'copy' : vc.encoder,
              decoder: copyVideo ? 'copy' : plan.decoder,
              pipeline: copyVideo ? 'copy' : plan.pipeline,
            },
          },
        });
      }));
    // GPU 零拷贝串行；CPU 链路直接跑
    try {
      await (plan.gpu ? withGpuGate(exec) : exec());
    } catch (err) {
      if (!copyVideo) rememberHwEncoderFailure(vc.encoder, err);
      throw err;
    }

    const playlist = nodePath.join(dir, 'index.m3u8');
    if (!fs.existsSync(playlist))
      throw Object.assign(new Error('hls output missing'), { code: 'E_FFMPEG' });
    const text = fs.readFileSync(playlist, 'utf8');
    if (fmp4 && !text.includes('#EXT-X-MAP')) {
      throw Object.assign(new Error('fmp4 playlist missing EXT-X-MAP'), { code: 'E_FFMPEG' });
    }
    const segments = fs.readdirSync(dir).filter((f) => f.endsWith('.ts') || f.endsWith('.m4s')).length;
    // 本段实际产出时长：上层靠它判断「已经转到哪儿了」，以及片源是不是转完了。
    // `-t` 掐出来的最后一片可能比 hls_time 短，所以不能拿 segments × 6s 估。
    const durationMs = Math.round(
      [...text.matchAll(/#EXTINF:([\d.]+)/g)]
        .map((m) => Number(m[1]))
        .reduce((a, b) => a + b, 0) * 1000,
    );
    return {
      segments,
      durationMs,
      ms: Number(process.hrtime.bigint() - started) / 1e6,
      codec,
      container: fmp4 ? 'fmp4' : 'mpegts',
      copyVideo,
      audioCopy,
      playlist,
      // 实际用的编码 / 解码链路：排障时能一眼看出「到底 GPU 跑了没有」。
      // copy 时三者都写 `copy`：这时候既没解码器也没编码器，写 hevc_amf+cpu
      // 会让人误判成本地软解在烧 CPU。
      encoder: copyVideo ? 'copy' : vc.encoder,
      decoder: copyVideo ? 'copy' : plan.decoder,
      pipeline: copyVideo ? 'copy' : plan.pipeline,
      vendor: copyVideo ? 'copy' : plan.vendor || 'cpu',
      source: {
        codec: source.codec,
        pixFmt: source.pixFmt,
        dvProfile: source.dvProfile,
        hi10p: source.hi10p,
        hdrKind: source.hdrKind,
        hasHdrMeta: source.hasHdrMeta,
      },
    };
  };

  let result;
  // 候选链：GPU 零拷贝 → 普通硬解 → CPU 软解（同 codec + 硬编）→ 同 codec CPU 编码 → h264 CPU。
  // 顺序即「画质优先、可用性兜底」：任何一步失败都往下走，绝不让用户对着黑屏等超时。
  const candidates = [];
  for (const plan of plans) candidates.push({ codec: outputCodec, allowHw: true, plan });
  candidates.push({ codec: outputCodec, allowHw: false, plan: CPU_PLAN });
  if (outputCodec !== 'h264') candidates.push({ codec: 'h264', allowHw: false, plan: CPU_PLAN });

  const runAll = async (tonemapOn) => {
    let last = null;
    for (let i = 0; i < candidates.length; i += 1) {
      // 原画直通不涉及编码 / 解码，失败重试没有意义
      if (copyVideo && i > 0) break;
      const c = candidates[i];
      try {
        return await attempt(c.codec, c.allowHw, c.plan, tonemapOn);
      } catch (err) {
        // 主动取消（新会话抢占旧会话）不是故障：直接冒泡，别浪费时间换编码器重试。
        if (err && err.code === 'E_CANCELED') throw err;
        last = err;
        if (i + 1 < candidates.length) {
          console.error(
            `[media] hls ${c.codec}/${c.plan.pipeline}/${c.allowHw ? 'hw' : 'cpu'} failed, fallback: ${String((err && err.message) || err)}`,
          );
        }
      }
    }
    throw last || Object.assign(new Error('hls failed'), { code: 'E_FFMPEG' });
  };
  try {
    result = await runAll(true);
  } catch (err) {
    if (err && err.code === 'E_CANCELED') throw err;
    // tonemap 链在片源上跑不通 → 关掉 tonemap 再跑一遍。
    // GPU 链只去掉 tonemap_d3d11、仍保留 scale_d3d11，CPU 链退化成纯 SDR 转换。
    //
    // 但**片源本身就是 DV/HDR 时不能这么退**：关掉 tonemap 得到的是一整片偏绿/偏紫的
    // 错色画面，用户看到的比报错更糟（还会以为是自己设备坏了）。这种情况如实报错，
    // 让前端提示「该片源转码失败」，而不是静默给一张坏画面。
    if (hdrToSdr && !copyVideo && !sourceNeedsTonemap) {
      console.error(
        `[media] hls tonemap failed, retry without tonemap: ${String((err && err.message) || err)}`,
      );
      result = await runAll(false);
    } else {
      throw err;
    }
  }

  stats.transcodes += 1;
  return { dir, ...result };
}
/**
 * 单文件编码（离线下载）：把片源按参数压成**一个完整文件**，供客户端整包下载。
 *
 * 与 hls() 的差别只在输出侧 —— 容器、音轨选择、可选内挂字幕、进度上报；
 * 解码链路 / 档位收敛 / HDR→SDR 全部走 resolveEncodePlan()，不另写一份。
 *
 * 为什么不用现成的 transcode()：它只认 h264/h265（没有 AV1）、不探硬件编码器、
 * 没有进度也没有取消、mp4 里 HEVC 不标 hvc1、不加 faststart，`scale=-2:h` 还会把
 * 矮片源放大。那套是给图片 / 音频转换写的，压整部片会重踩播放链路踩过的坑。
 *
 * 产物先写 `<dst>.part`，校验通过后由调用方（或这里）rename —— 中途被 kill 不会留下
 * 一个「看起来完整」的文件，避免上层把半截文件算成一个合法的 sha256。
 */
async function encode(params) {
  const { src, dir } = params || {};
  if (!src || !dir) throw Object.assign(new Error('src/dir required'), { code: 'E_PARAM' });
  if (!fs.existsSync(src))
    throw Object.assign(new Error('src not found: ' + src), { code: 'E_NO_SRC' });

  fs.mkdirSync(dir, { recursive: true });
  // 同一目录重试时清掉上一轮留下的取消标记，否则这一轮第一刀就被判成「已取消」
  canceledHls.delete(dir);

  // 原画 = 不重编码，remux 到 mkv：mp4 装不了 DTS / PGS / 多音轨，硬塞就得重编码音频，
  // 那就不叫原画了。mkv 里 `-c copy` 能把视频 / 全部音轨 / 内嵌字幕一次带过去。
  const remux = params.preset === 'original';
  const file = String(params.file || (remux ? 'out.mkv' : 'out.mp4'));
  const dst = nodePath.join(dir, file);
  const part = dst + '.part';
  try {
    fs.rmSync(part, { force: true });
  } catch {
    /* 忽略 */
  }

  const resolved = remux ? null : await resolveEncodePlan(params, 'encode');
  const source = resolved ? resolved.source : await probeSourceInfo(src);
  const durationMs = Number(params.durationMs) || Number(source.durationMs) || 0;
  // 整片编码的耗时上限：按片长 × 6 估（4K 软编实测约 1.5~2.5 倍片长），保底 10 分钟
  const timeoutMs =
    Number(params.timeoutMs) || Math.max(durationMs > 0 ? durationMs * 6 : 0, 10 * 60 * 1000);

  const started = Date.now();
  let lastEmit = 0;
  let speedText = '';
  const onProgress = (key, value) => {
    if (key === 'speed') {
      speedText = String(value);
      return;
    }
    // `-progress` 同时给 out_time_us 与 out_time_ms，后者因历史原因也是微秒，只信前者
    if (key !== 'out_time_us') return;
    const us = Number(value);
    if (!Number.isFinite(us) || us <= 0) return;
    const now = Date.now();
    if (now - lastEmit < 500) return;
    lastEmit = now;
    const percent =
      durationMs > 0 ? Math.min(99, Math.round((us / 1000 / durationMs) * 1000) / 10) : 0;
    send({
      type: 'event',
      event: 'encode_progress',
      data: {
        dir,
        file,
        percent,
        outTimeMs: Math.round(us / 1000),
        totalMs: durationMs,
        speed: speedText,
        elapsedMs: now - started,
      },
    });
  };

  const logArgs = (args, extra) => {
    try {
      fs.writeFileSync(
        nodePath.join(dir, '.encode.json'),
        JSON.stringify({ ...extra, args, at: Date.now() }, null, 1),
      );
    } catch {
      /* 写不了不影响编码 */
    }
  };

  // ------------------------------------------------------------------ 原画 remux
  if (remux) {
    const args = [
      '-hide_banner',
      '-loglevel',
      'error',
      '-y',
      '-nostats',
      '-progress',
      'pipe:1',
      '-i',
      src,
      // 显式选流：`?` 让缺失的流不致命（没有字幕轨的片子照样能 remux）
      '-map',
      '0:v?',
      '-map',
      '0:a?',
      '-map',
      '0:s?',
      // mkv 里的附件（字体）是 ASS 字幕渲染需要的东西，一并带过去
      '-map',
      '0:t?',
      '-c',
      'copy',
      '-map_metadata',
      '0',
      '-map_chapters',
      '0',
      // 产物先写 `.part`，ffmpeg 从后缀猜不出容器，必须显式指定
      '-f',
      'matroska',
      part,
    ];
    logArgs(args, { mode: 'remux' });
    await encodeLimiter(() => runFfmpeg(args, timeoutMs, { hlsKey: dir, progress: onProgress }));
    if (!fs.existsSync(part) || fs.statSync(part).size <= 0) {
      throw Object.assign(new Error('remux output missing'), { code: 'E_FFMPEG' });
    }
    fs.renameSync(part, dst);
    stats.transcodes += 1;
    return {
      dir,
      file,
      dst,
      bytes: fs.statSync(dst).size,
      durationMs,
      codec: source.codec || '',
      container: 'mkv',
      encoder: 'copy',
      decoder: 'copy',
      pipeline: 'copy',
      ms: Date.now() - started,
    };
  }

  // ------------------------------------------------------------------ 转码档
  const buildArgs = (codec, plan, tonemapOn) => {
    const vc = videoCodecArgs(codec, plan.gpu === true, resolved.prefer, resolved.hw, resolved.targetKbps);
    const vCodec = vc.args;
    const vf = plan.filter ? plan.filter(tonemapOn) : resolved.cpuFilter(tonemapOn);
    const audioKbps = Number(params.audioBitrateKbps) || PLAY_QUALITY.audioBitrateKbps;
    const embedSubs = params.subtitleMode === 'embed';
    // mp4 里的 HEVC 必须标 `hvc1`：MKV 源多是 `hev1`，Android 硬解只认 hvc1，
    // 标错不会报错、只会退化软解（4K 片子直接卡成幻灯片）。libx265 自带这个参数，
    // 硬件编码器不带，所以这里补一条（重复给 ffmpeg 也认，后者覆盖前者）。
    const needHvc1 = codec === 'h265' && !vCodec.includes('hvc1');
    return {
      vc,
      args: [
        '-hide_banner',
        '-loglevel',
        'error',
        '-y',
        '-nostats',
        '-progress',
        'pipe:1',
        ...plan.inputArgs,
        // 起流只需读头部；4K 多音轨源默认 5MB/5s 探测能白等 1~3 秒
        '-probesize',
        '2M',
        '-analyzeduration',
        '0',
        '-i',
        src,
        '-map',
        '0:v:0',
        '-map',
        `0:a:${resolved.audioIndex}?`,
        ...(embedSubs ? ['-map', '0:s?'] : ['-sn']),
        '-dn',
        ...(resolved.copyVideo
          ? ['-c:v', 'copy', ...(resolved.srcMapped === 'h265' ? ['-tag:v', 'hvc1'] : [])]
          : ['-vf', vf, '-c:v', ...vCodec]),
        // 统一 8-bit + BT.709：10-bit / 未标色彩的片源不这么做会在手机上一片发灰
        ...(!resolved.copyVideo
          ? ['-color_primaries', 'bt709', '-color_trc', 'bt709', '-colorspace', 'bt709']
          : []),
        // 码率封顶：目标码率是「平均」，不加 maxrate 遇到高动态镜头会翻倍
        ...(!resolved.copyVideo && resolved.targetKbps > 0
          ? ['-maxrate', `${resolved.targetKbps}k`, '-bufsize', `${resolved.targetKbps * 2}k`]
          : []),
        ...(resolved.audioFilter ? ['-af', resolved.audioFilter] : []),
        '-c:a',
        'aac',
        '-b:a',
        `${audioKbps}k`,
        '-ac',
        '2',
        ...(embedSubs ? ['-c:s', 'mov_text'] : []),
        ...(needHvc1 ? ['-tag:v', 'hvc1'] : []),
        // moov 前置：客户端边下边播 / 拖进度不用等整文件
        '-movflags',
        '+faststart',
        // 同理：`.part` 后缀猜不出容器
        '-f',
        'mp4',
        part,
      ],
    };
  };

  const runOne = async (codec, plan, tonemapOn) => {
    const { args, vc } = buildArgs(codec, plan, tonemapOn);
    logArgs(args, {
      mode: 'transcode',
      codec,
      pipeline: plan.pipeline,
      targetKbps: resolved.targetKbps,
      copyVideo: resolved.copyVideo,
    });
    const exec = () =>
      encodeLimiter(() => Promise.resolve().then(() => {
        if (!resolved.copyVideo) assertHwEncoderAvailable(vc.encoder);
        return runFfmpeg(args, timeoutMs, { hlsKey: dir, progress: onProgress });
      }));
    // GPU 零拷贝链是全局串行的，且两路硬件编码会把编码器卡死。播放正在转码时
    // 本任务只走 CPU：宁可慢，也不能把用户正在看的片子卡住。
    try {
      await (plan.gpu ? withGpuGate(exec) : exec());
    } catch (err) {
      if (!resolved.copyVideo) rememberHwEncoderFailure(vc.encoder, err);
      throw err;
    }
    if (!fs.existsSync(part) || fs.statSync(part).size <= 0) {
      throw Object.assign(new Error('encode output missing'), { code: 'E_FFMPEG' });
    }
    return {
      codec,
      encoder: resolved.copyVideo ? 'copy' : vc.encoder,
      decoder: resolved.copyVideo ? 'copy' : plan.decoder,
      pipeline: resolved.copyVideo ? 'copy' : plan.pipeline,
    };
  };

  // 候选链与 hls 同口径：GPU 零拷贝 → 普通硬解 → CPU 软解 → h264 CPU 兜底。
  // 区别只有一处：播放正在转码时（activeHls 非空）直接跳过所有硬件候选。
  const playbackBusy = activeHls.size > 0;
  const candidates = [];
  if (!playbackBusy) {
    for (const plan of resolved.plans) candidates.push({ codec: resolved.outputCodec, plan });
  }
  candidates.push({ codec: resolved.outputCodec, plan: CPU_PLAN });
  if (resolved.outputCodec !== 'h264') candidates.push({ codec: 'h264', plan: CPU_PLAN });

  let out = null;
  let lastErr = null;
  for (let i = 0; i < candidates.length && !out; i += 1) {
    // 原画直通不涉及编码器，换候选没有意义
    if (resolved.copyVideo && i > 0) break;
    const c = candidates[i];
    try {
      out = await runOne(c.codec, c.plan, true);
    } catch (err) {
      if (err && err.code === 'E_CANCELED') throw err;
      lastErr = err;
      try {
        fs.rmSync(part, { force: true });
      } catch {
        /* 忽略 */
      }
      if (i + 1 < candidates.length) {
        console.error(
          `[media] encode ${c.codec}/${c.plan.pipeline} failed, fallback: ${String(
            (err && err.message) || err,
          )}`,
        );
      }
    }
  }
  if (!out) throw lastErr || Object.assign(new Error('encode failed'), { code: 'E_FFMPEG' });

  fs.renameSync(part, dst);
  stats.transcodes += 1;
  return {
    dir,
    file,
    dst,
    bytes: fs.statSync(dst).size,
    durationMs,
    codec: out.codec,
    container: 'mp4',
    encoder: out.encoder,
    decoder: out.decoder,
    pipeline: out.pipeline,
    // 播放抢占导致的降级要让用户/排障看得到：这不是故障，是让位
    degradedToCpu: playbackBusy,
    ms: Date.now() - started,
  };
}

/**
 * 取消某个目录下正在跑的 HLS 转码（新会话抢占旧会话 / 用户换档时调用）。
 * 只 kill 精确匹配的 ffmpeg；取消标记让 runFfmpeg 抛 E_CANCELED，上层不重试。
 */
async function cancel(params) {
  const { dir } = params || {};
  if (!dir) throw Object.assign(new Error('dir required'), { code: 'E_PARAM' });
  // 先打标记再找 child：旧会话可能正好处在「上一次 attempt 已退出、下一次还没
  // 起来」的窗口里。只 kill 当前 child 的话，它接下来还会继续重试 —— 旧进程
  // 和新会话同时抢 GPU（实测两路 AMF 并发会把编码器卡死）。
  canceledHls.add(dir);
  const child = activeHls.get(dir);
  if (!child) return { canceled: true };
  try {
    child.kill('SIGKILL');
  } catch {
    /* 已退出 */
  }
  return { canceled: true };
}

async function bench(params) {
  const { src, dir } = params || {};
  if (!src || !dir) throw Object.assign(new Error('src/dir required'), { code: 'E_PARAM' });
  const count = Math.max(1, Math.min(Number(params.count) || 500, 5000));
  const size = Math.max(16, Math.min(Number(params.size) || 256, 4096));

  fs.mkdirSync(dir, { recursive: true });
  const started = process.hrtime.bigint();
  const tasks = [];
  for (let i = 0; i < count; i++) {
    tasks.push(thumb({ src, dst: nodePath.join(dir, `t${String(i).padStart(4, '0')}.jpg`), size }));
  }
  await Promise.all(tasks);
  const ms = Number(process.hrtime.bigint() - started) / 1e6;
  return { count, ms, throughput: (count / ms) * 1000, concurrency: CONCURRENCY };
}

async function handle(msg) {
  if (msg.type === 'ping') {
    send({ id: msg.id, ok: true, result: 'pong' });
    return;
  }
  if (msg.type === 'shutdown') {
    send({ id: msg.id, ok: true });
    setTimeout(() => process.exit(0), 5);
    return;
  }
  if (msg.type !== 'invoke') {
    send({ type: 'log', level: 'warn', message: `unknown message type: ${msg.type}` });
    return;
  }

  const handlers = {
    thumb,
    transcode,
    hls,
    encode,
    cancel,
    subtitleTracks,
    extractSubtitle,
    bench,
    stats: async () => ({
      ...stats,
      ffmpeg: FFMPEG,
      concurrency: CONCURRENCY,
      cpus: cpus().length,
      // 排障用：这台机器有哪些硬解方式与硬件滤镜，决定转码会不会走全 GPU 链
      gpuDecode: {
        platform: process.platform,
        d3d11va: detectHwaccels(FFMPEG).includes('d3d11va'),
        cuda: detectHwaccels(FFMPEG).includes('cuda'),
        qsv: detectHwaccels(FFMPEG).includes('qsv'),
        filters: {
          scale_d3d11: gpu.detectFilters(FFMPEG).includes('scale_d3d11'),
          tonemap_d3d11: gpu.detectFilters(FFMPEG).includes('tonemap_d3d11'),
          scale_cuda: gpu.detectFilters(FFMPEG).includes('scale_cuda'),
          tonemap_cuda: gpu.detectFilters(FFMPEG).includes('tonemap_cuda'),
          scale_qsv: gpu.detectFilters(FFMPEG).includes('scale_qsv'),
          vpp_qsv: gpu.detectFilters(FFMPEG).includes('vpp_qsv'),
          libplacebo: gpu.detectFilters(FFMPEG).includes('libplacebo'),
        },
        sourceCache: sourceCache.size,
      },
    }),
  };
  const fn = handlers[msg.method];
  if (!fn) {
    send({
      id: msg.id,
      ok: false,
      error: { code: 'E_METHOD', message: `unknown method: ${msg.method}` },
    });
    return;
  }

  try {
    const result = await fn(msg.params || {});
    send({ id: msg.id, ok: true, result });
  } catch (err) {
    stats.fails += 1;
    send({
      id: msg.id,
      ok: false,
      error: { code: err.code || 'E_MEDIA', message: String(err.message || err) },
    });
  }
}

/**
 * 空闲预热：用户点播放之前就把「硬件编码器 / hwaccel」探测做完（2026-11-16）。
 *
 * 实测冷进程第一次转码要额外付 ~6.8s：`detectHwAll` 里 4 次 ffmpeg 冷启动
 * （`-encoders` + 逐个试编 h264_amf / hevc_amf / av1_amf）。安卓端那次
 * 「首片 7852ms」正是它 —— 探测完写缓存的时间戳减去会话创建时间正好 6.85s，
 * 而同一组参数在机器热起来之后首片只要 0.94s。用户感受就是「第一部片特别慢，
 * 第二部就正常」，还容易误以为是手机没硬解。
 *
 * 这里趁 sidecar 刚起来、还没人等着看片的时候跑一遍；失败一律吞掉，
 * 暖不起来最多回到原来那 7 秒。
 */
setTimeout(() => {
  void (async () => {
    try {
      gpu.detectHwaccels(FFMPEG);
      await detectHwAll();
    } catch {
      /* 预热失败不影响播放 */
    }
  })();
}, 2000);

process.stdin.on('data', (chunk) => {
  buf += chunk;
  let idx = buf.indexOf('\n');
  while (idx >= 0) {
    const line = buf.slice(0, idx).trim();
    buf = buf.slice(idx + 1);
    if (line) {
      try {
        handle(JSON.parse(line));
      } catch {
        send({ type: 'log', level: 'warn', message: 'bad ndjson line' });
      }
    }
    idx = buf.indexOf('\n');
  }
});

process.stdin.on('end', () => process.exit(0));
