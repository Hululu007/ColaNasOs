import { proxyFetch } from '../../../kernel/proxy-fetch';

/**
 * 日本片库：**番号优先**刮削。
 *
 * 决策顺序：番号源（javbus → javdb → avsox）→ 失败才回退 TMDB。
 * 为什么番号优先：TMDB 上大量 AV 条目是「标题 == 搜索词 + overview 全是 1」的垃圾条目，
 * 先走番号源能避开这类脏数据；番号源全挂时才回退，且回退前用 `looksJunkTmdbMatch` 过滤。
 *
 * 站点结构随时会变，解析一律**宽松正则 + 精确番号比对**，任何异常都返回 null（不阻断扫描）。
 *
 * 抓取层的三个硬约束（踩过坑，别再退回去）：
 *   1. 必须带**真实浏览器 UA**。默认 UA 是 `ColaNasOs/1.0` 时 javbus 直接给验证页、javdb 直接 403。
 *   2. javbus / avsox 有**年龄确认墙**：不带 `age=verified` 只会拿到 "Age Verification" 页面，
 *      页面能 200 但里面没有任何作品信息 —— 表现为「所有番号都刮不到」。
 *   3. javbus 的搜索就是**详情页直达**（`/{番号}`），没有中转搜索结果页，
 *      不能套 javdb 那套「先搜再挑链接」，否则永远挑不到链接。
 */
export type JpSource = 'javdb' | 'javbus' | 'avsox';

/** javbus 覆盖面最广（有码/无码/素人日期番号都收），放第一位；javdb 常年 403，放兜底 */
export const JP_SOURCE_ORDER: JpSource[] = ['javbus', 'javdb', 'avsox'];

const BROWSER_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/122.0.0.0 Safari/537.36';

/** 每个源的请求头：UA + 年龄墙 cookie。少一个都会静默抓空。 */
const SOURCE_HEADERS: Record<JpSource, Record<string, string>> = {
  javbus: {
    'user-agent': BROWSER_UA,
    accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'accept-language': 'zh-CN,zh;q=0.9,ja;q=0.8,en;q=0.7',
    cookie: 'age=verified; existmag=mag; dv=1',
  },
  avsox: {
    'user-agent': BROWSER_UA,
    accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'accept-language': 'zh-CN,zh;q=0.9,ja;q=0.8,en;q=0.7',
    cookie: 'age=verified; existmag=mag; dv=1',
  },
  javdb: {
    'user-agent': BROWSER_UA,
    accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
    'accept-language': 'zh-CN,zh;q=0.9,ja;q=0.8,en;q=0.7',
    cookie: 'over18=1; locale=zh',
  },
};

/** avsox 域名换得勤，主域挂了换镜像；连续失败两次就在本次进程内停用它 */
const AVSOX_HOSTS = ['https://avsox.health', 'https://avsox.click', 'https://avsox.monster'];
const avsoxHost = 0;
let avsoxFails = 0;

export interface JpScrapeResult {
  source: JpSource;
  code: string;
  title: string;
  coverUrl: string | null;
  actors: string[];
  tags: string[];
  releasedAt: string | null;
  /** 厂牌 / メーカー（javbus 的「發行商」），没有就是 null */
  studio?: string | null;
  /** 导演，没有就是 null */
  director?: string | null;
  /** 片长（分钟），没抓到就是 0 */
  runtimeMin?: number;
  /** JavDB 评价人数（其它源没有，抓不到就是 0）—— 演员/作品综合排序的首要档位 */
  votes: number;
  /** JavDB 评分（0 = 没抓到） */
  score: number;
}

export interface JpScrapeOptions {
  timeoutMs?: number;
  /** 注入 fetch 便于测试；缺省用全局 fetch */
  fetchImpl?: typeof fetch;
  order?: JpSource[];
}

function searchUrl(source: JpSource, code: string): string {
  const q = encodeURIComponent(code);
  if (source === 'javdb') return `https://javdb.com/search?q=${q}&f=all`;
  if (source === 'javbus') return `https://www.javbus.com/${q}`;
  return `${AVSOX_HOSTS[avsoxHost % AVSOX_HOSTS.length]}/cn/search/${q}`;
}

/** 番号归一：去掉分隔符与大小写，用于「页面上真的是这个番号吗」的判定 */
export function codeKey(text: string): string {
  return String(text || '')
    .toUpperCase()
    .replace(/[^A-Z0-9]/g, '');
}


/**
 * 从搜索结果页里挑「番号精确匹配」的详情链接。
 * javdb 的坑：搜索页第一行常是同一演员的其他作品，必须按链接文本/strong 里的番号精确比对，
 * 否则点进错误详情页，刮出来的标题和封面全是别人的。
 */
export function pickExactCodeLink(html: string, code: string): string | null {
  const norm = code.toUpperCase().replace(/[^A-Z0-9]/g, '');
  const re = /<a[^>]+href="([^"]+)"[^>]*>([\s\S]{0,200}?)<\/a>/gi;
  let m: RegExpExecArray | null;
  while ((m = re.exec(html)) !== null) {
    const href = m[1];
    const text = m[2]
      .replace(/<[^>]+>/g, ' ')
      .toUpperCase()
      .replace(/[^A-Z0-9]/g, '');
    if (text.includes(norm) && /\/v\/|\/movie\//.test(href)) {
      return href.startsWith('http') ? href : new URL(href, 'https://javdb.com').toString();
    }
  }
  return null;
}

/** TMDB 垃圾条目：标题与搜索词相同、且 overview 是「1111…」这类占位 */
export function looksJunkTmdbMatch(
  candidate: { title?: string | null; overview?: string | null },
  query: string,
): boolean {
  const title = String(candidate.title || '')
    .toLowerCase()
    .replace(/\s+/g, '');
  const q = String(query || '')
    .toLowerCase()
    .replace(/\s+/g, '');
  if (!title) return true;
  const placeholder = /^[0-9\W_]{0,}$/.test(String(candidate.overview || '').trim());
  return title === q && placeholder;
}

function meta(html: string, patterns: RegExp[]): string | null {
  for (const re of patterns) {
    const m = re.exec(html);
    if (m && m[1]) return m[1].trim();
  }
  return null;
}

function parseDetail(html: string, source: JpSource, code: string): JpScrapeResult | null {
  const rawTitle =
    meta(html, [
      /<h2[^>]*class="[^"]*title[^"]*"[^>]*>([\s\S]*?)<\/h2>/i,
      /<title>([\s\S]*?)<\/title>/i,
    ])
      ?.replace(/<[^>]+>/g, ' ')
      .replace(/\s+/g, ' ')
      .trim() ?? '';
  // javbus/avsox 的 <title> 是「番号 标题 - 站点名」，去掉站点后缀与开头的番号
  const title = rawTitle
    .replace(/\s*[-|｜]\s*(JavBus|JavDB|AVSOX|javdb\.com)\s*$/i, '')
    .replace(new RegExp('^' + code.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '\\s*[-–—]?\\s*', 'i'), '')
    .trim();
  if (!title) return null;

  const coverUrl =
    meta(html, [
      /<a[^>]+class="[^"]*bigImage[^"]*"[^>]+href="([^"]+)"/i,
      /<meta[^>]+property="og:image"[^>]+content="([^"]+)"/i,
      /<img[^>]+class="[^"]*video-cover[^"]*"[^>]+src="([^"]+)"/i,
      /<img[^>]+id="[^"]*sample-watermark[^"]*"[^>]+src="([^"]+)"/i,
    ]) ?? null;
  const coverAbs = coverUrl
    ? coverUrl.startsWith('http')
      ? coverUrl
      : new URL(coverUrl, coverBase(source)).toString()
    : null;

  // 演员：javdb 走 /actors/，javbus / avsox 走 /star/（链接里常带 title 属性）
  const actors = [
    ...html.matchAll(/\/actors?\/[^"]+"[^>]*>([^<]{1,40})</gi),
    ...html.matchAll(/\/star\/[^"]*"[^>]*?(?:title="([^"]{1,40})"|>([^<]{1,40})<)/gi),
  ]
    .map((m) => (m[1] ?? m[2] ?? '').trim())
    .filter(Boolean);
  // 分类：javdb 走 /tags/，javbus / avsox 走 /genre/
  const tags = [
    ...html.matchAll(/\/tags?\/[^"]+"[^>]*>([^<]{1,40})</gi),
    ...html.matchAll(/\/genre\/[^"]*"[^>]*>([^<]{1,40})</gi),
  ]
    .map((m) => m[1].trim())
    .filter(Boolean);
  const releasedAt =
    meta(html, [/(\d{4}-\d{2}-\d{2})/, /(\d{4}\/\d{2}\/\d{2})/])?.replace(/\//g, '-') ?? null;

  // 厂牌 / 导演 / 片长：javbus 是「發行商:」「導演:」「長度: 187分鐘」
  const studio = meta(html, [/\/studio\/[^"]*"[^>]*>([^<]{1,60})</i])?.trim() ?? null;
  const director = meta(html, [/\/director\/[^"]*"[^>]*>([^<]{1,40})</i])?.trim() ?? null;
  const runtimeHit = /(\d{2,4})\s*(?:分鐘|分钟|分|min)/i.exec(html);
  const runtimeMin = runtimeHit ? Number(runtimeHit[1]) || 0 : 0;

  const votes = parseVotes(html);
  const score = parseScore(html);

  return {
    source,
    code,
    title: title.slice(0, 200),
    coverUrl: coverAbs,
    actors: [...new Set(actors)].slice(0, 20),
    tags: [...new Set(tags)].slice(0, 20),
    releasedAt,
    studio,
    director,
    runtimeMin,
    votes,
    score,
  };
}

function coverBase(source: JpSource): string {
  if (source === 'javbus') return 'https://www.javbus.com';
  if (source === 'avsox') return AVSOX_HOSTS[avsoxHost % AVSOX_HOSTS.length];
  return 'https://javdb.com';
}


/**
 * 评价人数：JavDB 详情页是 `4.21分, 由4838人評價`（繁体）/ `由 4838 人评价`。
 * 只认带「人」字的那个数字 —— 页面上还有海报尺寸、时长等一堆数字，乱抓会把
 * 时长当热度，排序立刻变成「越长的片越热」。
 */
export function parseVotes(html: string): number {
  const m =
    /由\s*([\d,]{1,9})\s*人\s*(?:評價|评价|評分|评分)/i.exec(html) ??
    /([\d,]{1,9})\s*人\s*(?:評價|评价|評分|评分)/i.exec(html);
  if (!m) return 0;
  const n = Number(String(m[1]).replace(/,/g, ''));
  return Number.isFinite(n) && n > 0 ? n : 0;
}

/** 评分：`4.21分` / `score: 4.21`；超过 10 的当作误抓丢掉 */
export function parseScore(html: string): number {
  const m = /([\d.]{1,4})\s*分(?:,|\s|<)/.exec(html) ?? /"ratingValue"\s*:\s*"?([\d.]+)/i.exec(html);
  if (!m) return 0;
  const n = Number(m[1]);
  return Number.isFinite(n) && n > 0 && n <= 10 ? Math.round(n * 100) / 100 : 0;
}

/**
 * javdb 需要先访问一次首页拿 `_jdb_session`，否则 `/search` 一律 403。
 * 会话 cookie 有效期两周，拿到后在进程内一直复用。
 */
let javdbCookie = '';

async function ensureJavdbCookie(fetchImpl: typeof fetch, timeoutMs: number): Promise<void> {
  if (javdbCookie) return;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl('https://javdb.com/', {
      signal: controller.signal,
      headers: SOURCE_HEADERS.javdb,
    });
    const reader = (res.headers as unknown as { getSetCookie?: () => string[] }).getSetCookie;
    const jar = typeof reader === 'function' ? reader.call(res.headers) : [];
    const parts = jar.map((c) => c.split(';')[0].trim()).filter(Boolean);
    if (parts.length > 0) javdbCookie = parts.join('; ');
  } catch {
    // 拿不到就直连再试一次，失败也只是跳过这个源
  } finally {
    clearTimeout(timer);
  }
}

async function fetchText(
  url: string,
  fetchImpl: typeof fetch,
  timeoutMs: number,
  source: JpSource,
): Promise<string | null> {
  const headers: Record<string, string> = { ...SOURCE_HEADERS[source] };
  if (source === 'javdb') {
    await ensureJavdbCookie(fetchImpl, timeoutMs);
    headers.referer = 'https://javdb.com/';
    if (javdbCookie) headers.cookie = `${javdbCookie}; over18=1; locale=zh`;
  }
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetchImpl(url, { signal: controller.signal, headers });
    if (!res.ok) return null;
    return await res.text();
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
  }
}

/**
 * 页面里是不是真的写到了这个番号。
 *
 * 年龄墙 / 404 页都会返回 200，只有比对番号才能确认抓到了真详情页 ——
 * 否则会把「Age Verification」当成作品标题写进 NFO。
 */
function pageHasCode(html: string, code: string): boolean {
  const key = codeKey(code);
  if (!key) return false;
  const head = html.slice(0, 4000);
  const title = /<title[^>]*>([\s\S]{0,200}?)<\/title>/i.exec(head);
  if (title && codeKey(title[1]).includes(key)) return true;
  const h3 = /<h3[^>]*>([\s\S]{0,200}?)<\/h3>/i.exec(head);
  return Boolean(h3 && codeKey(h3[1]).includes(key));
}

/**
 * 番号优先刮削：任一源成功即返回；全部失败返回 null（调用方回退 TMDB 或只保留文件名）。
 * 不做重试风暴：单源一次、超时即换下一个。
 */
export async function scrapeJp(
  code: string,
  opts: JpScrapeOptions = {},
): Promise<JpScrapeResult | null> {
  const clean = String(code || '')
    .trim()
    .toUpperCase();
  if (!clean) return null;
  const fetchImpl = opts.fetchImpl ?? (proxyFetch as unknown as typeof fetch);
  const timeoutMs = Math.max(1000, opts.timeoutMs ?? 8000);

  for (const source of opts.order ?? JP_SOURCE_ORDER) {
    if (source === 'avsox' && avsoxFails >= 2) continue;
    const url = searchUrl(source, clean);
    const list = await fetchText(url, fetchImpl, timeoutMs, source);
    if (!list) {
      if (source === 'avsox') avsoxFails += 1;
      continue;
    }
    // javbus 的搜索地址本身就是详情页，直接解析；javdb / avsox 才需要先挑链接
    if (source === 'javbus') {
      if (!pageHasCode(list, clean)) continue;
      const parsed = parseDetail(list, source, clean);
      if (parsed) return parsed;
      continue;
    }
    const href = pickExactCodeLink(list, clean);
    if (!href) {
      if (source === 'avsox') avsoxFails += 1;
      continue;
    }
    const detail = await fetchText(href, fetchImpl, timeoutMs, source);
    if (!detail) {
      if (source === 'avsox') avsoxFails += 1;
      continue;
    }
    const parsed = parseDetail(detail, source, clean);
    if (parsed && pageHasCode(detail, clean)) return parsed;
    if (source === 'avsox') avsoxFails += 1;
  }
  return null;
}

