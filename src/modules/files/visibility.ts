import { sql } from 'kysely';
import {
  accessPathOf,
  isFullAccess,
  POLICY_KEY_PREFIX,
  readPolicy,
  type PathRule,
} from '../../../kernel/access-policy';
import type { ConfigStore } from '../../../kernel/config';
import { filesRoot } from './fs-root';

/**
 * 「这个账号能看到哪些目录」的统一判定。
 *
 * 目录授权里存的路径有两种形态：文件根内的相对路径（`/media`）和目录选择器
 * 选出来的绝对路径（`D:/Media` → 归一后 `/D:/Media`）。而库 / 条目里的路径
 * 同样两者都有，直接字符串比会永远对不上。这里统一走 [accessPathOf]，
 * 折成**小写、正斜杠的绝对路径**再比（盘符大小写 / 反斜杠 / UNC 都兼容）。
 *
 * 语义（与 preHandler 的 `effectivePathRules` 保持一致）：
 * - 全权账号（`*` / 访问令牌的 ownerAdmin）→ `unrestricted`，任何过滤都不生效；
 * - 普通账号**显式保存过空规则 → 什么都不能看**（用户 2026-11-11：必须显式授权）；
 * - 普通账号从没配过规则 → 视为未做目录限制（兼容 scope-only 账号与旧数据）；
 * - 配了目录规则 → 只放行规则覆盖到的路径（规则 `/` 表示全部）。
 *
 * 以前「显式空规则 = 列表按全量」是错的：文件读写会被 403 拦住，但影视库、
 * 首页聚合、最近添加却把全部内容都吐出来（用户 2026-11-14 用小号复现）。
 */
export interface Visibility {
  unrestricted: boolean;
  rules: PathRule[];
  /** 归一后的绝对路径前缀（小写、无尾斜杠） */
  prefixes: string[];
}

function posix(input: string): string {
  return String(input ?? '').trim().replace(/\\/g, '/');
}

/** 规则路径 / 库源路径 / 条目路径统一成绝对形式 */
export function absolutePathOf(input: string): string {
  return accessPathOf(input, filesRoot());
}

export function visibilityOf(config: ConfigStore, user: unknown): Visibility {
  if (isFullAccess(user)) {
    return { unrestricted: true, rules: [], prefixes: [] };
  }
  const uid = String((user as { sub?: string } | null)?.sub ?? '');
  const policy = readPolicy(config, uid);
  const rules = policy.paths ?? [];
  // 规则 `/` 的语义是「全部」，等价于不限制（历史上 ACL 也是这么判的）
  if (rules.some((r) => r.path === '/')) {
    return { unrestricted: true, rules, prefixes: [] };
  }
  if (rules.length === 0) {
    // 区分「从没配过规则」和「显式保存了一份空规则」：
    // - 从没配过：scope-only 的账号 / 旧数据，列表仍按全量（兼容既有行为）；
    // - 显式保存为空：管理员在账号页点过保存但一个目录都没授权，
    //   此时必须和文件 ACL 一样「一个目录都不给看」，否则就是小号
    //   文件 403、影视库却全量泄露（用户 2026-11-14 复现）。
    const explicit = config.get(`${POLICY_KEY_PREFIX}${uid}`);
    if (explicit === undefined) return { unrestricted: true, rules: [], prefixes: [] };
    return { unrestricted: false, rules: [], prefixes: [] };
  }
  return {
    unrestricted: false,
    rules,
    prefixes: rules.map((r) => absolutePathOf(r.path)),
  };
}

/** 一条数据（库源 / 条目 / 文件）是否落在授权目录内 */
export function pathVisible(v: Visibility, candidate: string): boolean {
  if (v.unrestricted) return true;
  if (v.rules.length === 0) return false;
  if (v.rules.some((r) => r.path === '/')) return true;
  const abs = absolutePathOf(candidate);
  return v.prefixes.some((p) => abs === p || abs.startsWith(`${p}/`));
}

/**
 * 目录选择器用：除了授权目录本身与子目录，**通往它的祖先目录**也要能浏览，
 * 否则用户根本点不进 `D:/Media/Movies`（`D:` 和 `D:/Media` 会被过滤掉）。
 */
export function dirVisible(v: Visibility, candidate: string): boolean {
  if (v.unrestricted) return true;
  if (v.rules.length === 0) return false;
  if (v.rules.some((r) => r.path === '/')) return true;
  const abs = absolutePathOf(candidate);
  return v.prefixes.some(
    (p) => abs === p || abs.startsWith(`${p}/`) || p.startsWith(`${abs}/`),
  );
}

/**
 * SQL LIKE 前缀：条目列表要在数据库里过滤才能保住分页，不能拉全量到内存。
 * 同时给出「原始形态」和「绝对形态」两套，覆盖 rel_path 的相对 / 绝对两种写法。
 */
export function likePrefixes(v: Visibility): string[] {
  const out = new Set<string>();
  const root = posix(filesRoot()).replace(/\/+$/, '').toLowerCase();
  for (const r of v.rules) {
    // UNC 规则（`//host/share`）要带上双斜杠原样参与 LIKE：
    // SMB 条目的 rel_path 也是 `//host/share/...`，剥掉前导斜杠会永远匹配不上。
    const raw = posix(r.path);
    if (raw && raw !== '/') out.add(raw);
    const bare = raw.replace(/^\/+/, '');
    if (bare) out.add(bare);
    const abs = absolutePathOf(r.path).replace(/^\/+/, '');
    if (abs) out.add(abs);
    // 目录选择器选出来的是绝对路径，规则因此是 `/C:/.../files/music`；
    // 但库 / 曲目的 rel_path 往往是相对 filesRoot 的 `music/a.mp3`。
    // 少了这一条，库能显示、曲目却被 LIKE 全部滤空（2026-11-12 tv 账号实测）。
    if (abs.toLowerCase().startsWith(`${root}/`)) {
      out.add(abs.slice(root.length + 1));
    }
  }
  return [...out];
}

/**
 * 可拼进 `where` 的 SQL 片段：列表接口靠它把过滤留在数据库里，
 * 分页 / cursor 语义才不会被破坏（拉全量到内存过滤会让每页条数变少）。
 * 超级管理员返回恒真；没配目录的普通账号返回恒假。
 */
export function pathWhere(v: Visibility, column: string) {
  if (v.unrestricted) return sql`1 = 1`;
  const prefs = likePrefixes(v);
  if (prefs.length === 0) return sql`1 = 0`;
  // 列里的路径可能带反斜杠：库根是 `G:\music` 时条目存成 `G:\music/国语怀旧/a.flac`
  // （根用 Windows 写法 + 拼接用 `/`），而规则前缀一律是正斜杠小写 —— 直接 LIKE
  // 会因为一个 `\` 把整个音乐库滤空（列表返回空、专辑详情「没有曲目」，
  // 但专辑 / 歌手聚合没走这个过滤，于是「有专辑、点进去空的」，2026-11-18 实测）。
  // 两边都折成「小写 + 正斜杠」再比，不依赖数据写成哪种分隔符。
  const norm = sql`replace(lower(${sql.ref(column)}), '\\', '/')`;
  let cond = sql`1 = 0`;
  for (const p of prefs) {
    cond = sql`${cond} or ${norm} like ${`${p.toLowerCase()}%`}`;
  }
  return cond;
}
