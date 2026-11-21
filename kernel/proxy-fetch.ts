import { ProxyAgent, fetch as undiciFetch } from 'undici';

/**
 * 全局代理出口：设置页保存后调用 `configureProxy` 立即生效。
 *
 * 只影响使用 `proxyFetch` 的出站请求（TMDB / IMDb / 番号源 / 海报下载）；
 * 不走代理的请求（本机 files 等）不受影响。代理进程内只创建一次，
 * 换地址时替换 agent（旧的交给 GC，undici 会自行关闭空闲连接）。
 */
let agent: ProxyAgent | null = null;
let active = '';
/** 环境变量代理（HTTP_PROXY / HTTPS_PROXY）：设置页没填时兜底，抓国外 RSS 靠它 */
let envAgent: ProxyAgent | null = null;
let envUrl = '';
let envChecked = false;

function envProxyAgent(): ProxyAgent | null {
  if (envChecked) return envAgent;
  envChecked = true;
  envUrl = (
    process.env.HTTPS_PROXY ||
    process.env.https_proxy ||
    process.env.HTTP_PROXY ||
    process.env.http_proxy ||
    ''
  ).trim();
  if (envUrl) envAgent = new ProxyAgent(envUrl);
  return envAgent;
}

export function configureProxy(url: string): void {
  const clean = String(url ?? '').trim();
  if (clean === active) return;
  active = clean;
  agent = clean ? new ProxyAgent(clean) : null;
}

export function activeProxy(): string {
  return active;
}

/**
 * 当前出站走的到底是哪条路：设置页代理 / 环境变量 / 直连。
 *
 * 排查「境外源全失败」时必须一眼看出是不是压根没代理（2026-11-17 那次
 * 13 个源同时 fetch failed，先怀疑的就是这个）。`activeProxy()` 只说设置页
 * 填了什么，环境变量兜底与直连它区分不出来，所以单独给一个带来源的版本。
 */
export function activeProxyInfo(): {
  proxy: string;
  source: 'settings' | 'env' | 'direct';
} {
  if (agent) return { proxy: active, source: 'settings' };
  if (envProxyAgent()) return { proxy: envUrl, source: 'env' };
  return { proxy: '', source: 'direct' };
}

/**
 * 当前应当使用的 dispatcher（设置页代理 → 环境变量 → null 直连）。
 *
 * 下载器走 `undici.request` 而不是 `fetch`：需要「按块超时」这种 fetch 拿不到的能力，
 * 而且 fetch 的 body 是 Web Stream，中途取消会踩 undici 的 parser 断言（实测能把
 * 整个内核进程打断）。`request` 给的是 Node Readable，配 `bodyTimeout` 即可。
 */
export function proxyDispatcher(): import('undici').Dispatcher | null {
  return agent ?? envProxyAgent();
}

/** 与全局 `fetch` 同签名，带代理时自动走 dispatcher */
export async function proxyFetch(
  url: string,
  init: Record<string, unknown> = {},
): Promise<Response> {
  // 设置页填的代理优先；没填时用环境变量里的代理（很多人是靠 HTTP(S)_PROXY 配的）
  const dispatcher = agent ?? envProxyAgent();
  const opts = dispatcher ? { ...init, dispatcher } : init;
  return undiciFetch(url, opts as never) as unknown as Promise<Response>;
}