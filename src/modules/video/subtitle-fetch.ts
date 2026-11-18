import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

import { proxyFetch } from '../../../kernel/proxy-fetch';

/**
 * 日本片自动字幕：avsubtitles.com 五步链路。
 *
 * 实测要点（少一条就失败）：
 * 1. 搜索 → movie 页 → 字幕列表页，取 **subid 最大**（最新）；
 * 2. `download_page.php` 先种 `PHPSESSID`；
 * 3. 页面里 `let countdown = 6`，**必须等过倒计时**再请求下载，否则 302 到 error_403；
 * 4. `download_sub.php` 必须带 **Referer=download_page**，返回 application/zip；
 * 5. 未登录每天 **5 个**上限（返回纯文本 "cannot download more than 5 subtitles a day"）
 *    ⇒ 遇到就整轮中止，不要继续重试。
 *
 * zip 用内置 zlib 解（不引第三方依赖）：只取第一个 .srt/.ass/.vtt。
 */
export const SUB_STATE = {
  PENDING: 0,
  OK: 1,
  NO_CODE: 2,
  NOT_FOUND: 3,
  NO_CHINESE: 4,
  FAILED: 5,
} as const;

export type SubState = (typeof SUB_STATE)[keyof typeof SUB_STATE];

export interface SubtitleResult {
  state: SubState;
  reason: string;
  /** 命中每日上限：调用方应中止整轮 */
  limitReached?: boolean;
  text?: string;
}

interface ZipEntry {
  name: string;
  data: Buffer;
}

export function unzipFirstSubtitle(buffer: Buffer): ZipEntry | null {
  let eocd = -1;
  const min = Math.max(0, buffer.length - 70_000);
  for (let i = buffer.length - 22; i >= min; i -= 1) {
    if (buffer.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) return null;

  const count = buffer.readUInt16LE(eocd + 10);
  let off = buffer.readUInt32LE(eocd + 16);
  for (let i = 0; i < count; i += 1) {
    if (off + 46 > buffer.length || buffer.readUInt32LE(off) !== 0x02014b50) break;
    const method = buffer.readUInt16LE(off + 10);
    const compSize = buffer.readUInt32LE(off + 20);
    const nameLen = buffer.readUInt16LE(off + 28);
    const extraLen = buffer.readUInt16LE(off + 30);
    const commentLen = buffer.readUInt16LE(off + 32);
    const localOff = buffer.readUInt32LE(off + 42);
    const name = buffer.toString('utf8', off + 46, off + 46 + nameLen);

    if (/\.(srt|ass|ssa|vtt)$/i.test(name) && localOff + 30 <= buffer.length) {
      const localNameLen = buffer.readUInt16LE(localOff + 26);
      const localExtraLen = buffer.readUInt16LE(localOff + 28);
      const start = localOff + 30 + localNameLen + localExtraLen;
      const raw = buffer.subarray(start, start + compSize);
      try {
        const data = method === 0 ? Buffer.from(raw) : zlib.inflateRawSync(raw);
        return { name, data };
      } catch {
        return null;
      }
    }
    off += 46 + nameLen + extraLen + commentLen;
  }
  return null;
}

/** 字幕编码：BOM（UTF-16LE）→ UTF-8 校验 → GBK 兜底 */
export function decodeSubtitle(buffer: Buffer): string {
  if (buffer.length >= 2 && buffer[0] === 0xff && buffer[1] === 0xfe) {
    return buffer.subarray(2).toString('utf16le');
  }
  const utf8 = buffer.toString('utf8');
  if (!utf8.includes('\uFFFD')) return utf8.replace(/^\uFEFF/, '');
  try {
    return new TextDecoder('gbk').decode(buffer);
  } catch {
    return utf8;
  }
}

const LIMIT_RE = /cannot download more than \d+ subtitles a day/i;

/** 登录页/登录失败的判定文案（站点会把这句塞进 error_block） */
const WRONG_PWD_RE = /wrong username or password/i;

export interface FetchSubtitleOptions {
  base?: string;
  /** 已登录的 PHPSESSID（未登录也能下，但每天 5 个） */
  cookie?: string;
  /**
   * 登录会话 cookie：带上它就不再受「每天 5 个/天」限制。
   * 与 `cookie` 的区别是——链路里后续步骤种出来的 PHPSESSID **不覆盖**它
   * （覆盖等于把登录态换回匿名会话，限制又回来了）。
   */
  authCookie?: string;
  timeoutMs?: number;
  /** 倒计时等待上限；测试传 0 */
  waitMs?: number;
  fetchImpl?: typeof fetch;
}

export interface LoginResult {
  ok: boolean;
  /** 失败原因（可读，直接给用户看）：wrong_password / network / unexpected */
  reason: string;
  /** 登录后的 PHPSESSID；带上它就不再受「每天 5 条」限制 */
  cookie: string;
}

/**
 * 登录 avsubtitles.com。
 *
 * 实测要点：
 * 1. 表单是 `POST login_do.php`，字段 `inputLogin`（用户名或邮箱）+ `inputPassword`；
 * 2. **必须先 GET 一次 login.php** 拿到 PHPSESSID，否则 POST 会被当成新会话拒掉；
 * 3. 成功 = 302 跳到 `login.php` 之外的地址（通常回首页）；
 *    失败 = 302 回 `login.php`，且页面里有 `wrong username or password`；
 * 4. 站点会把 `avsubtitles.com` 301 到 `www.*`，POST 也要跟这次 301。
 */
export async function loginSubtitleSite(
  user: string,
  pass: string,
  opts: FetchSubtitleOptions = {},
): Promise<LoginResult> {
  const login = String(user || '').trim();
  const pwd = String(pass || '');
  if (!login || !pwd) return { ok: false, reason: 'no_credentials', cookie: '' };

  const doFetch = opts.fetchImpl ?? (proxyFetch as unknown as typeof fetch);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(2000, opts.timeoutMs ?? 12_000));
  try {
    let base = (opts.base || 'https://avsubtitles.com').replace(/\/$/, '');
    const ua = { 'user-agent': 'Mozilla/5.0 (compatible; ColaNasOs/1.0)' };

    // ① 先取登录页：既拿到 PHPSESSID，也把 301 后的真实域名定下来
    const page = await doFetch(`${base}/login.php`, {
      signal: controller.signal,
      redirect: 'manual',
      headers: ua,
    });
    if (page.status === 301 || page.status === 308) {
      const loc = page.headers.get('location');
      if (!loc) return { ok: false, reason: 'network', cookie: '' };
      base = new URL(loc, base).origin;
    } else if (!page.ok) {
      return { ok: false, reason: 'network', cookie: '' };
    }
    const seed = pickSessionCookie(page.headers);

    // ② POST 登录。302 的落点决定成败：跳回 login.php = 没登进去。
    const res = await doFetch(`${base}/login_do.php`, {
      method: 'POST',
      signal: controller.signal,
      redirect: 'manual',
      headers: {
        ...ua,
        'content-type': 'application/x-www-form-urlencoded',
        referer: `${base}/login.php`,
        ...(seed ? { cookie: seed } : {}),
      },
      body: new URLSearchParams({
        inputLogin: login,
        inputPassword: pwd,
        redirect: '',
      }).toString(),
    });

    const session = pickSessionCookie(res.headers) || seed;
    const location = res.headers.get('location') || '';

    // 跳回 login.php（含 query）= 登录被拒
    if (res.status >= 300 && res.status < 400 && /login\.php/i.test(location)) {
      // 拿到错误文案更友好，但页面要再请求一次才知道；这里直接判失败
      let detail = 'wrong_password';
      try {
        const back = await doFetch(`${base}/login.php`, {
          signal: controller.signal,
          redirect: 'manual',
          headers: { ...ua, ...(session ? { cookie: session } : {}) },
        });
        const text = await back.text().catch(() => '');
        if (WRONG_PWD_RE.test(text)) detail = 'wrong_password';
        else if (!text) detail = 'network';
      } catch {
        // 拿不到错误页也按密码错处理：302 回到登录页本身就是被拒
      }
      return { ok: false, reason: detail, cookie: '' };
    }

    // ③ 校验：拿首页看是不是还停在匿名态。
    // 匿名首页带「登录」入口（login.php）；登录成功后首页会带 logout / 账户区。
    try {
      const home = await doFetch(`${base}/`, {
        signal: controller.signal,
        redirect: 'manual',
        headers: { ...ua, ...(session ? { cookie: session } : {}) },
      });
      const text = await home.text().catch(() => '');
      if (WRONG_PWD_RE.test(text)) return { ok: false, reason: 'wrong_password', cookie: '' };
      const stillAnonymous = /inputLogin/i.test(text) || /href=["\'][^"']*login\.php/i.test(text);
      if (stillAnonymous && !/logout/i.test(text)) {
        // 首页还是匿名态 → 没登上
        return { ok: false, reason: 'wrong_password', cookie: '' };
      }
    } catch {
      // 首页探测失败不影响登录结论（302 落点已经说明问题）
    }

    return { ok: true, reason: 'ok', cookie: session };
  } catch {
    return { ok: false, reason: 'network', cookie: '' };
  } finally {
    clearTimeout(timer);
  }
}

async function get(
  url: string,
  opts: FetchSubtitleOptions,
  extra: Record<string, string> = {},
): Promise<{ text: string; buffer: Buffer; headers: Headers; url: string } | null> {
  const doFetch = opts.fetchImpl ?? (proxyFetch as unknown as typeof fetch);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), Math.max(2000, opts.timeoutMs ?? 12_000));
  try {
    const headers = {
      'user-agent': 'Mozilla/5.0 (compatible; ColaNasOs/1.0)',
      ...(opts.cookie ? { cookie: opts.cookie } : {}),
      ...extra,
    };
    let target = url;
    // 只跟 **301/308**（永久搬家）：avsubtitles.com 现在会 301 到 www.*，
    // 不跟就是「拿到跳转页」→ 搜索结果永远为空（表现为 search_failed）。
    // 302/307 一律不跟：`download_sub.php` 没过倒计时时的 302 → error_403 是要拦住的。
    for (let hop = 0; hop < 3; hop += 1) {
      const res = await doFetch(target, {
        signal: controller.signal,
        redirect: 'manual',
        headers,
      });
      if (res.status === 301 || res.status === 308) {
        const location = res.headers.get('location');
        if (!location) return null;
        target = new URL(location, target).toString();
        continue;
      }
      if (res.status >= 300 && res.status < 400) return null;
      if (!res.ok) return null;
      const buffer = Buffer.from(await res.arrayBuffer());
      return {
        text: buffer.toString('utf8'),
        buffer,
        headers: res.headers,
        url: target,
      };
    }
    return null;
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/** 从搜索页取 movie 详情链接（取第一个匹配片号的） */
export function pickMovieLink(html: string, code: string): string | null {
  const norm = code.toUpperCase().replace(/[^A-Z0-9]/g, '');
  const re = /<a[^>]+href="(\/movie[\d]+[^"]*)"[^>]*>([\s\S]{0,200}?)<\/a>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const text = m[2].toUpperCase().replace(/[^A-Z0-9]/g, '');
    if (text.includes(norm)) return m[1];
  }
  // 兜底：页面里链接本身含片号
  const direct = /href="(\/movie[\d]+[^"]*)"/i.exec(html);
  return direct ? direct[1] : null;
}

/** 字幕列表里取 subid 最大的中文条目 */
export function pickLatestChineseSub(html: string): { subId: string; href: string } | null {
  const re = /href="([^"]*\/subtitles\/[^"]*zh\/(\d+)[^"]*)"/gi;
  let best: { subId: string; href: string } | null = null;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const id = Number(m[2]);
    if (!best || id > Number(best.subId)) best = { subId: m[2], href: m[1] };
  }
  return best;
}

/**
 * 从响应里取出 PHPSESSID。
 *
 * `download_page.php` 会种 PHPSESSID，而 `download_sub.php` 必须带**同一个**
 * session（带不上就是 403，表现为 download_failed）。所以整条链路要一直带着它。
 */
function pickSessionCookie(headers: Headers): string {
  try {
    const raw = (headers as unknown as { getSetCookie?: () => string[] })
      .getSetCookie?.();
    if (!raw || raw.length === 0) return '';
    const parts: string[] = [];
    for (const item of raw) {
      const kv = String(item || '').split(';')[0]?.trim();
      if (kv && kv.toUpperCase().includes('PHPSESSID')) parts.push(kv);
    }
    return parts.join('; ');
  } catch {
    return '';
  }
}

/**
 * 抓一条字幕。`waitMs` 是倒计时等待（默认 6500ms；测试可设 0）。
 * 返回 `limitReached` 时调用方必须中止整轮。
 */
export async function fetchSubtitle(
  code: string,
  opts: FetchSubtitleOptions = {},
): Promise<SubtitleResult> {
  let base = (opts.base || 'https://avsubtitles.com').replace(/\/$/, '');
  const clean = String(code || '')
    .toUpperCase()
    .trim();
  if (!clean) return { state: SUB_STATE.NO_CODE, reason: 'no_code' };

  // 会话 cookie 跟着链路走：任何一步种下的 PHPSESSID 都要带给下一步。
  let session: FetchSubtitleOptions = { ...opts };
  let track = (res: { headers: Headers } | null) => {
    const cookie = res ? pickSessionCookie(res.headers) : '';
    if (cookie && cookie !== session.cookie) {
      session = { ...session, cookie };
    }
  };
  // 登录态：authCookie 优先，绝不被后续步骤种出来的 PHPSESSID 顶掉。
  // 顶掉就等于把会话换回匿名，「每天 5 个」的限制立刻回来。
  const authCookie = String(opts.authCookie || '').trim();
  if (authCookie) {
    session = { ...session, cookie: authCookie };
    track = () => {};
  }

  const search = await get(
    `${base}/search_results.php?search=${encodeURIComponent(clean)}`,
    session,
  );
  if (!search) return { state: SUB_STATE.FAILED, reason: 'search_failed' };
  track(search);
  if (LIMIT_RE.test(search.text)) {
    return { state: SUB_STATE.FAILED, reason: 'daily_limit', limitReached: true };
  }
  // 跟随 301 之后的真实域名（avsubtitles.com → www.avsubtitles.com），
  // 后续相对链接都要拼在这个域名上，否则每一步都吃一次 301。
  if (search.url) {
    try {
      base = new URL(search.url).origin;
    } catch {
      // url 不合法就沿用原 base
    }
  }

  const movieHref = pickMovieLink(search.text, clean);
  if (!movieHref) return { state: SUB_STATE.NOT_FOUND, reason: 'movie_not_found' };

  const movie = await get(`${base}${movieHref}`, session);
  if (!movie) return { state: SUB_STATE.FAILED, reason: 'movie_page_failed' };
  track(movie);

  const sub = pickLatestChineseSub(movie.text);
  if (!sub) return { state: SUB_STATE.NO_CHINESE, reason: 'no_chinese_sub' };

  const subPage = await get(`${base}${sub.href}`, session);
  if (!subPage) return { state: SUB_STATE.FAILED, reason: 'sub_page_failed' };
  track(subPage);

  const subId = /name="subid"\s+value="(\d+)"/i.exec(subPage.text)?.[1] ?? sub.subId;
  const revId = /name="revid"\s+value="(\d+)"/i.exec(subPage.text)?.[1] ?? '';
  const countdown = Number(/countdown\s*=\s*(\d+)/i.exec(subPage.text)?.[1] ?? 6);

  const downloadPage = `${base}/download_page.php?subid=${subId}&revid=${revId}`;
  const dpage = await get(downloadPage, session);
  if (!dpage) return { state: SUB_STATE.FAILED, reason: 'download_page_failed' };
  track(dpage);

  // 倒计时没走完直接下 → 302 / error_403
  const wait =
    opts.waitMs ?? (Number.isFinite(countdown) ? Math.max(0, countdown) * 1000 + 500 : 6500);
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));

  const file = await get(
    `${base}/download_sub.php?subid=${subId}&revid=${revId}`,
    session,
    {
      referer: downloadPage,
    },
  );
  if (!file) return { state: SUB_STATE.FAILED, reason: 'download_failed' };
  if (LIMIT_RE.test(file.text)) {
    return { state: SUB_STATE.FAILED, reason: 'daily_limit', limitReached: true };
  }

  const entry = unzipFirstSubtitle(file.buffer);
  if (!entry) return { state: SUB_STATE.FAILED, reason: 'zip_invalid' };
  const text = decodeSubtitle(entry.data);
  if (!text.trim()) return { state: SUB_STATE.FAILED, reason: 'empty_subtitle' };

  return { state: SUB_STATE.OK, reason: 'ok', text };
}

/** 落盘：与视频同名同目录（保留原扩展名） */
export function writeSubtitleBeside(videoAbs: string, text: string, ext = '.srt'): string {
  const target = path.join(
    path.dirname(videoAbs),
    `${path.basename(videoAbs, path.extname(videoAbs))}${ext}`,
  );
  fs.writeFileSync(target, text, 'utf-8');
  return target;
}
