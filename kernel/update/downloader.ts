import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { pipeline } from 'node:stream/promises';
import { proxyFetch } from '../proxy-fetch';
import { sha256File, sha256 } from './verify';
import {
  FIRST_BYTE_TIMEOUT_MS,
  MAX_ATTEMPTS_PER_SOURCE,
  MIN_SPEED_BYTES,
  STALL_WINDOW_MS,
  SpeedWindow,
  orderSources,
  sourceLabel,
  type SourceMemo,
} from './sources';

export class DownloadError extends Error {
  constructor(
    public readonly code: string,
    message: string,
    public readonly detail?: Record<string, unknown>,
  ) {
    super(message);
    this.name = 'DownloadError';
  }
}

export interface ProgressEvent {
  /** 当前传输的是哪个资产（文件名，给界面显示） */
  asset: string;
  loaded: number;
  /** 压缩后的总字节数（未知时为 0） */
  total: number;
  /** 字节/秒 */
  speed: number;
  source: string;
  /** 第几个源 / 共几个源 */
  sourceIndex: number;
  sourceCount: number;
}

export interface DownloadOptions {
  urls: string[];
  dest: string;
  /** 最终（解压后）文件的大小与摘要 */
  size?: number;
  sha256?: string;
  /** 远端是 brotli 压缩形态时给出：先下压缩包，校验它，再解压校验原文件 */
  br?: { size?: number; sha256?: string };
  memo?: SourceMemo;
  /** 记忆键（一般用 sha256 原文件摘要） */
  memoKey?: string;
  onProgress?: (e: ProgressEvent) => void;
  signal?: AbortSignal;
}

export interface DownloadResult {
  bytes: number;
  source: string;
  /** 已有同摘要文件，直接复用 */
  cached: boolean;
}

function ensureDir(p: string): void {
  fs.mkdirSync(path.dirname(p), { recursive: true });
}

function fileSize(p: string): number {
  try {
    return fs.statSync(p).size;
  } catch {
    return 0;
  }
}

/** 用户取消 / 内核退出时的统一错误 */
function aborted(): DownloadError {
  return new DownloadError('E_ABORTED', '已取消');
}

/**
 * 单个资产的下载：多源 + Range 续传 + 熔断换源。
 *
 * 失败语义：所有源都失败才抛错，抛错时**保留 `.part`**（7 天内可续传）。
 * 校验不通过则删 `.part`（内容已经错了，续传只会错上加错），换源重来。
 */
export async function downloadAsset(opts: DownloadOptions): Promise<DownloadResult> {
  const { dest, urls } = opts;
  ensureDir(dest);

  // 已下载且校验通过：直接复用（重试 / 重启进程都能命中）
  if (opts.sha256 && fs.existsSync(dest) && sha256File(dest) === opts.sha256) {
    return { bytes: fileSize(dest), source: 'cache', cached: true };
  }

  const preferred = opts.memo && opts.memoKey ? opts.memo.preferred(opts.memoKey) : undefined;
  const ordered = orderSources(urls, preferred);
  if (ordered.length === 0) {
    throw new DownloadError('E_NO_SOURCE', `没有可用的下载地址: ${path.basename(dest)}`);
  }

  const asset = path.basename(dest);
  const errors: string[] = [];

  for (let i = 0; i < ordered.length; i += 1) {
    const url = ordered[i];
    for (let attempt = 1; attempt <= MAX_ATTEMPTS_PER_SOURCE; attempt += 1) {
      if (opts.signal?.aborted) throw aborted();
      try {
        const bytes = await fetchToFile({
          url,
          dest,
          asset,
          total: opts.br ? opts.br.size : opts.size,
          sourceIndex: i + 1,
          sourceCount: ordered.length,
          onProgress: opts.onProgress,
          signal: opts.signal,
        });

        /**
         * 落盘的是 `<dest>.part`，校验与改名都发生在它身上 ——
         * 千万不能直接读 `dest`（此时还不存在）。
         */
        const part = `${dest}.part`;
        if (opts.br) {
          // 先校验压缩形态，再流式解压，最后校验原文件
          if (opts.br.sha256) {
            const got = sha256File(part);
            if (got !== opts.br.sha256) {
              fs.rmSync(part, { force: true });
              throw new DownloadError('E_HASH', `${asset} 压缩包摘要不符`);
            }
          }
          await brotliTo(part, opts);
        } else if (opts.sha256) {
          const got = sha256File(part);
          if (got !== opts.sha256) {
            fs.rmSync(part, { force: true });
            throw new DownloadError('E_HASH', `${asset} 摘要不符`);
          }
          fs.renameSync(part, dest);
        } else if (fs.existsSync(part)) {
          fs.renameSync(part, dest);
        }

        opts.memo?.remember(opts.memoKey ?? opts.sha256 ?? asset, url);
        opts.memo?.flush();
        return { bytes, source: url, cached: false };
      } catch (err) {
        if (err instanceof DownloadError && err.code === 'E_ABORTED') throw err;
        const msg = `${sourceLabel(url)}: ${(err as Error).message}`;
        errors.push(msg);
        // 摘要不符已经删了 part；其余情况保留 part 续传
      }
    }
  }

  throw new DownloadError('E_ALL_SOURCES', `全部下载源失败（${asset}）`, { errors });
}

interface FetchToFileOptions {
  url: string;
  dest: string;
  asset: string;
  total?: number;
  sourceIndex: number;
  sourceCount: number;
  onProgress?: (e: ProgressEvent) => void;
  signal?: AbortSignal;
}

/**
 * 一个源的一次尝试：写 `<dest>.part`，失败保留已下部分。
 *
 * 为什么用 `fetch` + `getReader()` 手工抽干，而不是 `undici.request` + pipeline：
 * 实测遇到 HTTP/1.0 响应（例如 `python -m http.server`）时，`request` 的 body
 * 被消费完之后仍会触发 `AssertionError: assert(!this.paused)` —— 那是 undici
 * 内部的 parser 断言，**直接把整个内核进程打崩**。`fetch` 的 reader 路径不会。
 *
 * 熔断也不用 AbortController 打断 body（同样会踩那个断言），而是
 * `reader.cancel()` 优雅收尾：连接正常关闭，已下部分保留续传。
 */
async function fetchToFile(o: FetchToFileOptions): Promise<number> {
  const part = `${o.dest}.part`;
  let offset = fileSize(part);

  const headers: Record<string, string> = {};
  if (offset > 0) headers.range = `bytes=${offset}-`;

  // 首字节超时：连不上就别耗着（此时还没开始读 body，abort 是安全的）
  const ctrl = new AbortController();
  const firstByte = setTimeout(() => ctrl.abort(new Error('first-byte timeout')), FIRST_BYTE_TIMEOUT_MS);
  let res: Response;
  try {
    res = await proxyFetch(o.url, { headers, signal: ctrl.signal, redirect: 'follow' });
  } finally {
    clearTimeout(firstByte);
  }

  if (res.status === 416) {
    // 已下部分比服务端文件还大（服务端换了文件）：清掉重来
    await res.body?.cancel().catch(() => undefined);
    fs.rmSync(part, { force: true });
    throw new DownloadError('E_RANGE', '续传区间非法，已重置');
  }
  if (!res.ok) {
    await res.body?.cancel().catch(() => undefined);
    throw new DownloadError('E_HTTP', `HTTP ${res.status}`);
  }
  if (!res.body) throw new DownloadError('E_BODY', '响应没有 body');

  // 服务端不认 Range（返回 200 整包）：丢弃已有片段，从头写
  const ranged = res.status === 206;
  if (offset > 0 && !ranged) offset = 0;

  const contentLength = Number(res.headers.get('content-length') || 0);
  const total = o.total || contentLength || 0;

  const reader = res.body.getReader();
  const window = new SpeedWindow();
  let loaded = offset;
  let lastEmit = 0;
  let lastDataAt = Date.now();
  let cancelled = false;

  const onAbort = () => {
    cancelled = true;
  };
  o.signal?.addEventListener('abort', onAbort, { once: true });

  /**
   * 用**同步**写：`await handle.write()` 会在两次 read 之间留出异步间隙，
   * undici 的 body 就会因背压暂停底层 socket；HTTP/1.0 响应（服务端发完即断）
   * 在暂停状态下收尾会触发 parser 断言，直接崩进程。同步写让消费速度跟得上，
   * 本地磁盘每次只写 16~64 KB，开销可忽略。
   */
  const fd = fs.openSync(part, offset > 0 && ranged ? 'a' : 'w');
  try {
    for (;;) {
      if (cancelled) {
        await reader.cancel().catch(() => undefined);
        throw aborted();
      }
      const { done, value } = await reader.read();
      if (done) break;
      if (value && value.length > 0) {
        fs.writeSync(fd, value);
        loaded += value.length;
        lastDataAt = Date.now();
        window.push(value.length);
        const now = Date.now();
        // 100ms 一次进度足够界面平滑，也更省 IPC
        if (o.onProgress && now - lastEmit >= 100) {
          lastEmit = now;
          o.onProgress({
            asset: o.asset,
            loaded,
            total,
            speed: window.avg(now),
            source: o.url,
            sourceIndex: o.sourceIndex,
            sourceCount: o.sourceCount,
          });
        }
        // 熔断：持续低速 → 主动收尾换源（已下部分保留续传）
        const speed = window.avg(now);
        if (loaded - offset > 512 * 1024 && speed > 0 && speed < MIN_SPEED_BYTES) {
          await reader.cancel().catch(() => undefined);
          throw new DownloadError('E_SLOW', `速度过低 ${Math.round(speed / 1024)} KB/s`);
        }
      }
      // 卡住不动：连续一段时间没有任何数据
      if (Date.now() - lastDataAt > STALL_WINDOW_MS * 3) {
        await reader.cancel().catch(() => undefined);
        throw new DownloadError('E_STALL', '下载停滞');
      }
    }
  } finally {
    try {
      fs.closeSync(fd);
    } catch {
      /* 已关闭 */
    }
    o.signal?.removeEventListener('abort', onAbort);
  }

  if (o.onProgress) {
    o.onProgress({
      asset: o.asset,
      loaded,
      total: total || loaded,
      speed: window.avg(),
      source: o.url,
      sourceIndex: o.sourceIndex,
      sourceCount: o.sourceCount,
    });
  }

  if (total > 0 && loaded < total) {
    throw new DownloadError('E_TRUNCATED', `传输不完整 ${loaded}/${total}`);
  }
  return loaded;
}

/** `.part`（brotli）→ `dest`，流式解压后校验原文件摘要 */
async function brotliTo(part: string, opts: DownloadOptions): Promise<void> {
  const out = `${opts.dest}.out`;
  await pipeline(
    fs.createReadStream(part),
    zlib.createBrotliDecompress(),
    fs.createWriteStream(out),
  );
  if (opts.sha256) {
    const got = sha256File(out);
    if (got !== opts.sha256) {
      fs.rmSync(out, { force: true });
      fs.rmSync(part, { force: true });
      throw new DownloadError('E_HASH', `${path.basename(opts.dest)} 解压后摘要不符`);
    }
  }
  if (opts.size && fileSize(out) !== opts.size) {
    fs.rmSync(out, { force: true });
    fs.rmSync(part, { force: true });
    throw new DownloadError('E_SIZE', `${path.basename(opts.dest)} 大小不符`);
  }
  fs.renameSync(out, opts.dest);
  fs.rmSync(part, { force: true });
}

/**
 * 小文件直读（清单 / 签名 / 小 JSON），带同样的换源与超时。
 *
 * 用 `arrayBuffer()` 一次读完：清单只有几 KB，没必要为它写流式；
 * 同时避开「读一半取消」这类会踩 undici 断言的路径。
 */
export async function fetchText(
  urls: string[],
  opts: { maxBytes?: number; signal?: AbortSignal; memo?: SourceMemo; memoKey?: string } = {},
): Promise<{ text: string; source: string }> {
  const ordered = orderSources(urls, opts.memo && opts.memoKey ? opts.memo.preferred(opts.memoKey) : undefined);
  const maxBytes = opts.maxBytes ?? 4 * 1024 * 1024;
  const errors: string[] = [];
  for (const url of ordered) {
    if (opts.signal?.aborted) throw aborted();
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(new Error('timeout')), FIRST_BYTE_TIMEOUT_MS);
    try {
      const res = await proxyFetch(url, { signal: ctrl.signal, redirect: 'follow' });
      if (!res.ok) {
        await res.body?.cancel().catch(() => undefined);
        throw new Error(`HTTP ${res.status}`);
      }
      const buf = Buffer.from(await res.arrayBuffer());
      if (buf.length > maxBytes) throw new Error(`响应过大 ${buf.length}B`);
      opts.memo?.remember(opts.memoKey ?? sha256(buf).slice(0, 16), url);
      return { text: buf.toString('utf8'), source: url };
    } catch (err) {
      errors.push(`${sourceLabel(url)}: ${(err as Error).message}`);
    } finally {
      clearTimeout(timer);
    }
  }
  throw new DownloadError('E_ALL_SOURCES', '全部更新源失败', { errors });
}
