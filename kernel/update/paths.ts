/**
 * 清单里的相对路径安全校验。
 *
 * 更新包来自网络，路径必须当成**不可信输入**：`../` 穿越、绝对路径、盘符、
 * Windows 保留名（CON/NUL/COM1…）任何一个漏掉都可能写出版本目录之外。
 */
const RESERVED = new Set([
  'con', 'prn', 'aux', 'nul',
  'com1', 'com2', 'com3', 'com4', 'com5', 'com6', 'com7', 'com8', 'com9',
  'lpt1', 'lpt2', 'lpt3', 'lpt4', 'lpt5', 'lpt6', 'lpt7', 'lpt8', 'lpt9',
]);

export function assertSafeRel(rel: string): void {
  const p = String(rel || '').replace(/\\/g, '/');
  if (!p) throw new Error('空路径');
  if (p.startsWith('/')) throw new Error(`绝对路径不允许: ${rel}`);
  if (/^[a-zA-Z]:/.test(p)) throw new Error(`盘符路径不允许: ${rel}`);
  if (p.includes('\0')) throw new Error(`非法字符: ${rel}`);
  for (const seg of p.split('/')) {
    if (!seg || seg === '.' || seg === '..') throw new Error(`非法路径段: ${rel}`);
    if (seg.includes(':')) throw new Error(`非法路径段: ${rel}`);
    const base = seg.split('.')[0].toLowerCase();
    if (RESERVED.has(base) && /\.(exe|dll|js|json|txt|bin)?$/i.test(seg)) {
      throw new Error(`Windows 保留名: ${rel}`);
    }
  }
}

export function normalizeRel(rel: string): string {
  const p = String(rel || '').replace(/\\/g, '/').replace(/^\.\/+/, '');
  assertSafeRel(p);
  return p;
}
