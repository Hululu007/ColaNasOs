import fsp from 'node:fs/promises';
import path from 'node:path';

/**
 * 媒体库根目录下的排除规则文件（`.colanasignore`，兼容 `.libignore`）。
 *
 * 语法与 `.gitignore` 对齐，一条一行：
 *   `# 开头`      注释
 *   `old/`        任意层级下名为 old 的**目录**及其全部内容
 *   `*.iso`       任意层级下后缀匹配的文件
 *   `/预告/`      只匹配根目录下的「预告」（前导斜杠 = 锚定到根）
 *   `A/B`         相对根目录的路径
 *   `!保留这个/`   反选（前置感叹号）
 *
 * 只影响**媒体扫描**（影视 / 相册 / 音乐 / 书籍的索引），
 * 文件管理器浏览、播放、下载都不受影响 —— 被排除的目录仍然可以正常打开。
 */

export interface IgnorePattern {
  /** 原始文本，调试 / 报错用 */
  raw: string;
  /** 命中「这一项本身」 */
  re: RegExp;
  /** 命中「这一项下面的内容」，用于 `old/` 这种只排除目录但要连内容一起排除的情况 */
  reDesc: RegExp;
  /** `old/` 这种带尾斜杠的只作用于目录 */
  dirOnly: boolean;
  negate: boolean;
}

export interface IgnoreRules {
  patterns: IgnorePattern[];
  /** 命中的规则条数统计用，不影响逻辑 */
  source: string | null;
}

const IGNORE_FILES = ['.colanasignore', '.libignore'];

function escapeRe(s: string): string {
  return s.replace(/[.+^${}()|[\]\\]/g, '\\$&');
}

function compile(raw: string): IgnorePattern | null {
  let p = raw.trim();
  if (!p || p.startsWith('#')) return null;
  let negate = false;
  if (p.startsWith('!')) {
    negate = true;
    p = p.slice(1).trim();
    if (!p) return null;
  }
  // 行尾空格无意义（想匹配空格用 \ 转义，这里不展开）
  p = p.replace(/\s+$/, '');
  let anchored = false;
  if (p.startsWith('/')) {
    anchored = true;
    p = p.slice(1);
  }
  let dirOnly = false;
  if (p.endsWith('/')) {
    dirOnly = true;
    p = p.replace(/\/+$/, '');
  }
  if (!p) return null;

  // 与 gitignore 一致：模式里出现 `/`（不含结尾那个）就是相对根目录锚定的
  anchored = anchored || p.includes('/');

  let body = '';
  for (let i = 0; i < p.length; i += 1) {
    const c = p[i];
    if (c === '*') {
      if (p[i + 1] === '*') {
        // `**/` 吃掉任意层目录
        if (p[i + 2] === '/') {
          body += '(?:.*/)?';
          i += 2;
        } else {
          body += '.*';
          i += 1;
        }
      } else {
        body += '[^/]*';
      }
    } else if (c === '?') {
      body += '[^/]';
    } else {
      body += escapeRe(c);
    }
  }

  const head = anchored ? '^' : '(?:^|/)';
  // `i` 是因为 Windows 文件系统不分大小写
  const re = new RegExp(`${head}${body}$`, 'i');
  // 这一项下面的内容：`old/` 命中目录本身，也要命中 `old/xxx`
  const reDesc = new RegExp(`${head}${body}/`, 'i');
  return { raw: raw.trim(), re, reDesc, dirOnly, negate };
}

export function parseIgnore(text: string): IgnorePattern[] {
  const out: IgnorePattern[] = [];
  for (const line of text.split(/\r?\n/)) {
    const p = compile(line);
    if (p) out.push(p);
  }
  return out;
}

/**
 * 判断一条相对路径是否被排除。
 * 后面的规则覆盖前面的（与 gitignore 一致），所以从后往前找第一条命中的。
 */
export function ignoredBy(rules: IgnorePattern[], rel: string, isDir: boolean): boolean {
  if (!rules.length) return false;
  const norm = rel.replace(/\\/g, '/').replace(/^\/+/, '');
  for (let i = rules.length - 1; i >= 0; i -= 1) {
    const r = rules[i];
    // 在这条被排除的目录「里面」→ 一定命中，与是文件还是目录无关
    if (r.reDesc.test(norm)) return !r.negate;
    // 命中这一项「本身」：`old/` 只认目录，普通模式文件和目录都认
    if (r.re.test(norm) && (!r.dirOnly || isDir)) return !r.negate;
  }
  return false;
}

interface CacheEntry {
  mtimeMs: number;
  rules: IgnorePattern[];
  file: string | null;
}
const cache = new Map<string, CacheEntry>();

/**
 * 读取某个库根目录的排除规则（带 mtime 缓存：改完文件不用重启服务）。
 * 目录里没有规则文件时返回空规则，开销只是一次 `stat`。
 */
export async function loadIgnore(rootAbs: string): Promise<IgnoreRules> {
  let picked: string | null = null;
  let mtimeMs = 0;
  for (const name of IGNORE_FILES) {
    const abs = path.join(rootAbs, name);
    try {
      const st = await fsp.stat(abs);
      if (!st.isFile()) continue;
      picked = abs;
      mtimeMs = st.mtimeMs;
      break;
    } catch {
      // 没有这个文件，试下一个
    }
  }

  const prev = cache.get(rootAbs);
  if (!picked) {
    if (prev && prev.file === null) return { patterns: prev.rules, source: null };
    cache.set(rootAbs, { mtimeMs: 0, rules: [], file: null });
    return { patterns: [], source: null };
  }
  if (prev && prev.file === picked && prev.mtimeMs === mtimeMs) {
    return { patterns: prev.rules, source: picked };
  }
  let text: string;
  try {
    text = await fsp.readFile(picked, 'utf8');
  } catch {
    return { patterns: [], source: picked };
  }
  const rules = parseIgnore(text.replace(/^\uFEFF/, ''));
  cache.set(rootAbs, { mtimeMs, rules, file: picked });
  return { patterns: rules, source: picked };
}
