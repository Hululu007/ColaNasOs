import fs from 'node:fs';
import path from 'node:path';

/**
 * 下载源选择：**顺序即优先级**，边下边测速，慢了就熔断换下一个。
 *
 * 默认顺序（方案 §9.1）：局域网服务端 → GitCode → GitHub → Gitee。
 * 这个顺序由调用方拼好（服务端把局域网地址插到最前面），这里只做两件事：
 *   1. 按「上次成功过的源」把同一个资产排在前面（同 sha256 记忆）；
 *   2. 给出熔断判据（首字节超时 / 持续低速 / HTTP 错误）。
 */

/** 首字节等待上限：连不上就别耗着，立刻换源 */
export const FIRST_BYTE_TIMEOUT_MS = 8_000;
/** 速度低于这个值且持续 STALL_WINDOW_MS → 熔断 */
export const MIN_SPEED_BYTES = 200 * 1024;
export const STALL_WINDOW_MS = 6_000;
/** 单源最多重试次数 */
export const MAX_ATTEMPTS_PER_SOURCE = 2;

/** 滑动窗口测速：最近 6 秒的平均吞吐 */
export class SpeedWindow {
  private samples: { at: number; bytes: number }[] = [];

  push(bytes: number, at = Date.now()): void {
    this.samples.push({ at, bytes });
    const cutoff = at - STALL_WINDOW_MS * 2;
    while (this.samples.length > 0 && this.samples[0].at < cutoff) this.samples.shift();
  }

  /** bytes/秒（窗口内样本不足时按实际跨度折算，避免 0 除） */
  avg(now = Date.now()): number {
    const cutoff = now - STALL_WINDOW_MS;
    const recent = this.samples.filter((s) => s.at >= cutoff);
    if (recent.length === 0) return 0;
    const bytes = recent.reduce((sum, s) => sum + s.bytes, 0);
    const span = Math.max(500, now - recent[0].at);
    return Math.round((bytes / span) * 1000);
  }

  reset(): void {
    this.samples = [];
  }
}

/**
 * 同资产记忆：成功下载某个 sha256 之后记下用过的源，下次同资产优先它。
 *
 * 落盘在 `<dataDir>/update/source-memo.json`。读失败就当空表（不是致命错误）。
 */
export class SourceMemo {
  private data: Record<string, string> = {};
  private dirty = false;

  constructor(private readonly file: string) {
    try {
      const raw = JSON.parse(fs.readFileSync(file, 'utf8')) as Record<string, string>;
      if (raw && typeof raw === 'object') this.data = raw;
    } catch {
      /* 没有就用空表 */
    }
  }

  preferred(key: string): string | undefined {
    return key ? this.data[key] : undefined;
  }

  remember(key: string, url: string): void {
    if (!key || !url) return;
    if (this.data[key] === url) return;
    this.data[key] = url;
    this.dirty = true;
    // 只留最近 200 条，防止无限增长
    const keys = Object.keys(this.data);
    if (keys.length > 200) {
      for (const k of keys.slice(0, keys.length - 200)) delete this.data[k];
    }
  }

  flush(): void {
    if (!this.dirty) return;
    try {
      fs.mkdirSync(path.dirname(this.file), { recursive: true });
      fs.writeFileSync(this.file, JSON.stringify(this.data), 'utf8');
      this.dirty = false;
    } catch {
      /* 写不进去不影响下载 */
    }
  }
}

/**
 * 排出候选顺序：记住的源提到最前，其余保持原顺序。
 *
 * 不去重会重复下载同一个 Host —— 清单里同一个文件常常同时给局域网和公网地址，
 * 这里按 URL 字符串去重即可（不同 host 本来就该保留）。
 */
export function orderSources(urls: string[], preferred?: string): string[] {
  const seen = new Set<string>();
  const out: string[] = [];
  for (const u of [preferred, ...urls]) {
    if (!u) continue;
    const clean = u.trim();
    if (!clean || seen.has(clean)) continue;
    seen.add(clean);
    out.push(clean);
  }
  return out;
}

/** 把相对文件名拼到 base 上（base 已带末尾 `/` 或没有都行） */
export function joinUrl(base: string, name: string): string {
  const b = base.endsWith('/') ? base : `${base}/`;
  return `${b}${name.replace(/^\/+/, '')}`;
}

/** 从 URL 猜一个短标签，给界面显示「正在从 GitCode 下载」 */
export function sourceLabel(url: string): string {
  try {
    const host = new URL(url).host.toLowerCase();
    if (host.startsWith('192.168.') || host.startsWith('10.') || host.startsWith('127.')) {
      return 'LAN';
    }
    if (host.includes('gitcode')) return 'GitCode';
    if (host.includes('github')) return 'GitHub';
    if (host.includes('gitee')) return 'Gitee';
    return host;
  } catch {
    return url;
  }
}
