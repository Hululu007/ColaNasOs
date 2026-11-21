import { sql } from 'kysely';

/**
 * 账号**实时**授权快照（scopes + 是否禁用）。
 *
 * 为什么要单独存在：JWT 里的 `scopes` 是**签发那一刻**的快照，管理员后来改了
 * 账号权限 / 禁用了账号，旧 token 里的值不会跟着变。只认 token 就会出现
 * 「改完权限必须重新登录才生效」。
 *
 * 鉴权与 `/auth/me` 都以这里为准：改权限后下一个请求立即按新权限判定，
 * 不需要用户重新登录换 token。
 */
export interface LiveAuth {
  scopes: string[];
  disabled: boolean;
}

/**
 * 短 TTL 缓存。
 *
 * 媒体墙、缩略图这类页面一次会并发几十个请求，每个都点查一次 `auth_users`
 * 虽然也快（SQLite 主键），但没必要。2 秒足够让「刚改完权限」几乎立刻生效，
 * 又能把同一屏的请求合并成一次查询。改权限时还会显式 invalidate，不受 TTL 影响。
 */
const TTL_MS = 2000;
const cache = new Map<string, { value: LiveAuth | null; at: number }>();

export async function loadLiveAuth(db: any, uid: string): Promise<LiveAuth | null> {
  const id = String(uid ?? '');
  if (!id) return null;
  const now = Date.now();
  const hit = cache.get(id);
  if (hit && now - hit.at < TTL_MS) return hit.value;

  const row = (
    await sql<{ scopes: string | null; disabled: number }>`
      select scopes, disabled from auth_users where id = ${id} limit 1
    `.execute(db)
  ).rows[0];

  let value: LiveAuth | null = null;
  if (row) {
    let scopes: string[] = [];
    try {
      const parsed = JSON.parse(row.scopes || '[]');
      if (Array.isArray(parsed)) scopes = parsed.map((s) => String(s));
    } catch {
      // 库里是坏 JSON：当空权限处理，总比放行安全
      scopes = [];
    }
    value = { scopes, disabled: Number(row.disabled) === 1 };
  }
  cache.set(id, { value, at: now });
  return value;
}

/** 改权限 / 禁用 / 删号后调用：下一个请求立即拿到新值，不必等 TTL。 */
export function invalidateLiveAuth(uid?: string): void {
  if (uid) cache.delete(String(uid));
  else cache.clear();
}
