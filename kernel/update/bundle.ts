import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { sha256 } from './verify';
import { assertSafeRel } from './paths';

/**
 * 小文件包（`*.brb` = ColaNasOs Bundle）。
 *
 * 为什么不用 tar/zip：内核里没有解包依赖，为 543 个小文件引一个 tar 库不值得；
 * 自己这个容器只有 30 行，且天然支持「边解边校验」。
 *
 * 布局（整体再 brotli 压缩）：
 *   "CNB1" | u32 headerLen(LE) | header JSON | 各文件字节（顺序拼接）
 *   header = { entries: [{ path, offset, size, sha256 }] }   offset 相对 payload 起点
 */
const MAGIC = 'CNB1';

export interface BundleEntry {
  path: string;
  offset: number;
  size: number;
  sha256: string;
}

export interface BundleHeader {
  version: 1;
  entries: BundleEntry[];
}

export interface BundleInput {
  path: string;
  data: Buffer;
}

export function packBundle(entries: BundleInput[]): Buffer {
  const sorted = [...entries].sort((a, b) => a.path.localeCompare(b.path));
  const headerEntries: BundleEntry[] = [];
  let offset = 0;
  for (const e of sorted) {
    assertSafeRel(e.path);
    headerEntries.push({ path: e.path, offset, size: e.data.length, sha256: sha256(e.data) });
    offset += e.data.length;
  }
  const header: BundleHeader = { version: 1, entries: headerEntries };
  const headerBytes = Buffer.from(JSON.stringify(header), 'utf8');
  const len = Buffer.alloc(4);
  len.writeUInt32LE(headerBytes.length, 0);
  const raw = Buffer.concat([Buffer.from(MAGIC, 'ascii'), len, headerBytes, ...sorted.map((e) => e.data)]);
  // q11 在小文件包上收益最大（几十 KB 的 JS 大段重复），耗时不到 1s
  return zlib.brotliCompressSync(raw, {
    params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11, [zlib.constants.BROTLI_PARAM_SIZE_HINT]: raw.length },
  });
}

export function readBundle(file: string): { header: BundleHeader; payload: Buffer } {
  const raw = zlib.brotliDecompressSync(fs.readFileSync(file));
  if (raw.subarray(0, 4).toString('ascii') !== MAGIC) {
    throw new Error(`不是有效的更新小文件包: ${path.basename(file)}`);
  }
  const headerLen = raw.readUInt32LE(4);
  const header = JSON.parse(raw.subarray(8, 8 + headerLen).toString('utf8')) as BundleHeader;
  return { header, payload: raw.subarray(8 + headerLen) };
}

/**
 * 解包到目录，**逐文件校验 sha256**。
 *
 * 一个文件不符就整体失败（说明传输或发布侧出了问题，不能把半套文件装进版本目录）。
 */
export function unpackBundle(file: string, destDir: string): { files: number; bytes: number } {
  const { header, payload } = readBundle(file);
  let bytes = 0;
  for (const e of header.entries) {
    assertSafeRel(e.path);
    const slice = payload.subarray(e.offset, e.offset + e.size);
    if (slice.length !== e.size) throw new Error(`包内文件被截断: ${e.path}`);
    if (sha256(slice) !== e.sha256) throw new Error(`包内文件摘要不符: ${e.path}`);
    const abs = path.join(destDir, e.path);
    fs.mkdirSync(path.dirname(abs), { recursive: true });
    fs.writeFileSync(abs, slice);
    bytes += slice.length;
  }
  return { files: header.entries.length, bytes };
}
