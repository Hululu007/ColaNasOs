import fs from 'node:fs';
import path from 'node:path';
import { assertSafeRel, normalizeRel } from './paths';
import { sha256File } from './verify';

/**
 * 版本目录组装：**硬链接 + 只替换变化文件**。
 *
 * 为什么不做二进制 diff：一次发版真正变的只有 `main.dart.js`(1.2 MB)
 * 和几十个内核 `.js`；底下 37 MB 的 canvaskit、4.9 MB 字体一个字节都不变。
 * NTFS 硬链接（同卷 O(1)、不占空间）直接把不变的部分「借」过来，比维护
 * N×N 的 patch 矩阵简单一个数量级，失败面只有「写文件」一种。
 *
 * 两个坑（都处理了）：
 *   1. 硬链接不能原地写：同一份数据两个目录共用，写一个会改掉另一个
 *      → 组装新目录时**从不写已存在的文件**，变化文件先 unlink 再 copy；
 *   2. 跨卷 linkSync 会 EPERM/EXDEV → 降级 copyFileSync（日志里记一次）。
 */

export class AssembleError extends Error {
  constructor(
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = 'AssembleError';
  }
}

export interface AssembleOptions {
  /** 基线版本目录；全量安装时为 null */
  baselineDir: string | null;
  /** 目标（staging）目录，必须不存在或为空 */
  targetDir: string;
  /** 下载解包出来的「变化文件」目录（按相对路径摆好） */
  payloadDir: string;
  /** 目标版本全量文件清单 rel → sha256 */
  files: Record<string, string>;
  /** manifest.json 原文与签名：一起落到版本目录里，供下次校验 */
  manifestText?: Buffer;
  manifestSig?: string;
  onProgress?: (done: number, total: number) => void;
}

export interface AssembleResult {
  files: number;
  linked: number;
  copied: number;
  bytesCopied: number;
  /** 硬链接降级成复制的次数（跨卷时的正常现象） */
  linkFallback: number;
}

/** 递归建目录（硬链接只能对文件，目录必须逐层建） */
function ensureDir(dir: string): void {
  fs.mkdirSync(dir, { recursive: true });
}

function place(src: string, dest: string, mode: { hardlink: boolean }): 'link' | 'copy' | 'fallback' {
  ensureDir(path.dirname(dest));
  if (fs.existsSync(dest)) fs.rmSync(dest, { force: true });
  if (mode.hardlink) {
    try {
      fs.linkSync(src, dest);
      return 'link';
    } catch {
      // 跨卷 / 文件系统不支持硬链接：降级复制
    }
  }
  fs.copyFileSync(src, dest);
  return mode.hardlink ? 'fallback' : 'copy';
}

/**
 * 组装一个新版本目录。
 *
 * 对清单里的每个文件：
 *   - payload 里有 → 复制（这是本次真正变化的部分）；
 *   - 否则基线目录里有 → 硬链接（零拷贝复用）；
 *   - 都没有 → 失败（增量包不完整，绝不能切指针）。
 */
export function assembleVersion(o: AssembleOptions): AssembleResult {
  if (fs.existsSync(o.targetDir) && fs.readdirSync(o.targetDir).length > 0) {
    throw new AssembleError('E_TARGET_EXISTS', `目标目录非空: ${o.targetDir}`);
  }
  ensureDir(o.targetDir);

  const rels = Object.keys(o.files).sort();
  const result: AssembleResult = { files: 0, linked: 0, copied: 0, bytesCopied: 0, linkFallback: 0 };
  const missing: string[] = [];

  let done = 0;
  for (const rawRel of rels) {
    const rel = normalizeRel(rawRel);
    assertSafeRel(rel);
    const dest = path.join(o.targetDir, rel);
    const inPayload = path.join(o.payloadDir, rel);
    const inBaseline = o.baselineDir ? path.join(o.baselineDir, rel) : '';

    if (fs.existsSync(inPayload) && fs.statSync(inPayload).isFile()) {
      const size = fs.statSync(inPayload).size;
      place(inPayload, dest, { hardlink: false });
      result.copied += 1;
      result.bytesCopied += size;
    } else if (inBaseline && fs.existsSync(inBaseline) && fs.statSync(inBaseline).isFile()) {
      const how = place(inBaseline, dest, { hardlink: true });
      if (how === 'fallback') result.linkFallback += 1;
      result.linked += 1;
    } else {
      missing.push(rel);
    }

    done += 1;
    if (o.onProgress && (done % 50 === 0 || done === rels.length)) o.onProgress(done, rels.length);
  }

  if (missing.length > 0) {
    throw new AssembleError(
      'E_INCOMPLETE',
      `增量包缺 ${missing.length} 个文件（例：${missing.slice(0, 3).join(', ')}）`,
    );
  }

  if (o.manifestText) {
    fs.writeFileSync(path.join(o.targetDir, 'manifest.json'), o.manifestText);
    if (o.manifestSig) {
      fs.writeFileSync(path.join(o.targetDir, 'manifest.json.sig'), o.manifestSig);
    }
  }

  result.files = rels.length;
  return result;
}

/**
 * 目录级全量校验：逐文件 sha256。
 *
 * 61 MB / 几百个文件实测 < 1 s —— 切指针前必须跑一遍，因为硬链接只保证
 * 「文件名对了」，不保证「当初那份基线文件没被人改过」。
 */
export function verifyTree(dir: string, files: Record<string, string>): { ok: boolean; errors: string[] } {
  const errors: string[] = [];
  for (const [rawRel, want] of Object.entries(files)) {
    const rel = String(rawRel).replace(/\\/g, '/');
    const abs = path.join(dir, rel);
    let stat: fs.Stats;
    try {
      stat = fs.statSync(abs);
    } catch {
      errors.push(`缺文件: ${rel}`);
      continue;
    }
    if (!stat.isFile()) {
      errors.push(`不是文件: ${rel}`);
      continue;
    }
    if (sha256File(abs) !== want) {
      // 硬链接的目标被外部改动会走到这里：只报错，让调用方删 staging 重来
      errors.push(`摘要不符: ${rel}`);
    }
  }
  return { ok: errors.length === 0, errors };
}

/** 清理残留的 `.staging-*`（启动时调用；超过 1 小时的才算残留） */
export function cleanStaging(versionsDir: string, olderThanMs = 60 * 60 * 1000): string[] {
  const removed: string[] = [];
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(versionsDir, { withFileTypes: true });
  } catch {
    return removed;
  }
  const now = Date.now();
  for (const e of entries) {
    if (!e.isDirectory() || !e.name.startsWith('.staging-')) continue;
    const abs = path.join(versionsDir, e.name);
    try {
      if (now - fs.statSync(abs).mtimeMs < olderThanMs) continue;
      fs.rmSync(abs, { recursive: true, force: true });
      removed.push(e.name);
    } catch {
      /* 占用中：下次再清 */
    }
  }
  return removed;
}
