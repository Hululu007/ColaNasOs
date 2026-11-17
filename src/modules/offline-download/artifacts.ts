import crypto from 'node:crypto';
import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';

/**
 * 产物（转码出来的那个文件）的命名、校验与回收。
 *
 * 一个缓存目录 = 一份「同参数产物」。目录名是参数指纹，所以两台设备选同样参数时
 * 天然指向同一个目录，不需要额外的去重表。
 */

/** 客户端请求的那一组参数（也是缓存的键） */
export interface ArtifactSpec {
  preset: string;
  codec: string;
  height: number;
  videoKbps: number;
  audioKbps: number;
  audioIndex: number;
  container: string;
  subtitleMode: string;
}

export interface ArtifactRow {
  id: string;
  cache_key: string;
  rel_path: string;
  size: number;
  sha256: string;
  etag: string;
  mime: string;
  width: number | null;
  height: number | null;
  duration: number | null;
  video_codec: string | null;
  audio_codec: string | null;
  bitrate: number | null;
  container: string;
  state: string;
  ref_count: number;
  created_at: number;
  last_hit_at: number;
}

/** 产物根目录：与 hls 分开，便于各自按不同 TTL 清理 */
export function artifactsRootOf(k: KernelApi): string {
  return path.join(k.paths.dataDir, 'offline', 'artifacts');
}

export function artifactDirOf(k: KernelApi, cacheKey: string): string {
  return path.join(artifactsRootOf(k), cacheKey);
}

/**
 * 参数指纹。
 *
 * 只放**影响产物内容**的字段：同一个 item 换分辨率 / 编码 / 码率 / 音轨 / 字幕
 * 都必须得到不同目录，否则第二次下载会拿到上一次的产物。
 * `preset` 不进指纹 —— 它已经被展开成 height + videoKbps，同一组数字换档位名
 * 不该重复编码。
 */
export function cacheKeyOf(itemId: string, spec: ArtifactSpec): string {
  const raw = [
    itemId,
    spec.codec,
    spec.height,
    spec.videoKbps,
    spec.audioIndex,
    spec.audioKbps,
    spec.subtitleMode,
    spec.container,
  ].join('|');
  return crypto.createHash('sha1').update(raw).digest('hex').slice(0, 24);
}

export function mimeOf(container: string): string {
  return container === 'mkv' ? 'video/x-matroska' : 'video/mp4';
}

/** 流式 SHA-256：整片几个 GB，一次性 readFile 会把内存打爆 */
export async function sha256File(abs: string): Promise<string> {
  const hash = crypto.createHash('sha256');
  await new Promise<void>((resolve, reject) => {
    const stream = fs.createReadStream(abs);
    stream.on('data', (chunk) => hash.update(chunk));
    stream.on('end', () => resolve());
    stream.on('error', reject);
  });
  return hash.digest('hex');
}

/** 产物是否真实可用：目录里有文件、大小对得上。数据库说 active 不算数 */
export async function artifactExists(k: KernelApi, row: ArtifactRow): Promise<boolean> {
  if (row.state !== 'active') return false;
  const abs = path.join(k.paths.dataDir, row.rel_path);
  const st = await fsp.stat(abs).catch(() => null);
  return Boolean(st && st.isFile() && st.size === row.size);
}

/** 建/复用产物行：同一 cacheKey 已存在就只刷新命中时间 */
export async function upsertArtifact(
  k: KernelApi,
  input: {
    cacheKey: string;
    relPath: string;
    size: number;
    sha256: string;
    etag: string;
    container: string;
    width: number | null;
    height: number | null;
    durationMs: number | null;
    videoCodec: string | null;
    audioCodec: string | null;
    bitrateKbps: number | null;
  },
): Promise<ArtifactRow> {
  const t = Math.floor(Date.now() / 1000);
  const existing = (
    await sql<ArtifactRow>`
      select * from offline_artifacts where cache_key = ${input.cacheKey}
    `.execute(k.db)
  ).rows[0];

  if (existing) {
    // 产物被重新编出来（上次的文件被清理 / 参数相同但编码器升级了）：覆盖元信息，
    // 但**不动 ref_count** —— 引用关系是任务绑定出来的，不能因为重编就丢。
    await sql`
      update offline_artifacts
         set rel_path = ${input.relPath},
             size = ${input.size},
             sha256 = ${input.sha256},
             etag = ${input.etag},
             mime = ${mimeOf(input.container)},
             width = ${input.width},
             height = ${input.height},
             duration = ${input.durationMs},
             video_codec = ${input.videoCodec},
             audio_codec = ${input.audioCodec},
             bitrate = ${input.bitrateKbps},
             container = ${input.container},
             state = 'active',
             last_hit_at = ${t}
       where id = ${existing.id}
    `.execute(k.db);
    return { ...existing, ...{ rel_path: input.relPath, size: input.size, state: 'active' } };
  }

  const id = crypto.randomUUID();
  await sql`
    insert into offline_artifacts
      (id, cache_key, rel_path, size, sha256, etag, mime, width, height, duration,
       video_codec, audio_codec, bitrate, container, state, ref_count, created_at, last_hit_at)
    values
      (${id}, ${input.cacheKey}, ${input.relPath}, ${input.size}, ${input.sha256}, ${input.etag},
       ${mimeOf(input.container)}, ${input.width}, ${input.height}, ${input.durationMs},
       ${input.videoCodec}, ${input.audioCodec}, ${input.bitrateKbps}, ${input.container},
       'active', 0, ${t}, ${t})
  `.execute(k.db);
  return (
    await sql<ArtifactRow>`select * from offline_artifacts where id = ${id}`.execute(k.db)
  ).rows[0];
}

export async function artifactByCacheKey(
  k: KernelApi,
  cacheKey: string,
): Promise<ArtifactRow | null> {
  const row = (
    await sql<ArtifactRow>`
      select * from offline_artifacts where cache_key = ${cacheKey}
    `.execute(k.db)
  ).rows[0];
  return row ?? null;
}

export async function artifactById(k: KernelApi, id: string): Promise<ArtifactRow | null> {
  const row = (
    await sql<ArtifactRow>`select * from offline_artifacts where id = ${id}`.execute(k.db)
  ).rows[0];
  return row ?? null;
}

export async function touchArtifact(k: KernelApi, id: string): Promise<void> {
  await sql`
    update offline_artifacts set last_hit_at = ${Math.floor(Date.now() / 1000)} where id = ${id}
  `.execute(k.db);
}

/** 产物 TTL：没有人再引用它、也没人下载，就回收 */
const ARTIFACT_TTL_SEC = 24 * 3600;
const ARTIFACT_SWEEP_MS = 60 * 60 * 1000;

/**
 * 回收无人引用的产物。
 *
 * 三个安全条件（照 hls 的 sweep 口径）：
 *   · 只删 `ref_count = 0` 的 —— 还有任务指着它就不能动；
 *   · 只删 `last_hit_at` 超过 24h 的 —— 刚下完正在传的不能动；
 *   · 目录存在但行不存在（手工清过库）按 mtime 兜底收。
 */
export async function sweepArtifacts(k: KernelApi): Promise<number> {
  const t = Math.floor(Date.now() / 1000);
  const rows = (
    await sql<{ id: string; rel_path: string }>`
      select id, rel_path from offline_artifacts
       where ref_count = 0 and last_hit_at < ${t - ARTIFACT_TTL_SEC}
    `.execute(k.db)
  ).rows;

  for (const row of rows) {
    const abs = path.join(k.paths.dataDir, row.rel_path);
    await fsp.rm(path.dirname(abs), { recursive: true, force: true }).catch(() => undefined);
    await sql`delete from offline_artifacts where id = ${row.id}`.execute(k.db);
  }

  // 孤儿目录
  try {
    const alive = new Set(
      (
        await sql<{ cache_key: string }>`select cache_key from offline_artifacts`.execute(k.db)
      ).rows.map((r) => r.cache_key),
    );
    const names = await fsp.readdir(artifactsRootOf(k)).catch(() => [] as string[]);
    for (const name of names) {
      if (alive.has(name)) continue;
      const dir = path.join(artifactsRootOf(k), name);
      const st = await fsp.stat(dir).catch(() => null);
      if (!st || !st.isDirectory()) continue;
      if (Date.now() - st.mtimeMs < ARTIFACT_TTL_SEC * 1000) continue;
      await fsp.rm(dir, { recursive: true, force: true }).catch(() => undefined);
    }
  } catch {
    // 根目录还不存在 / 没权限：下次再说，别让清理把启动搞挂
  }

  if (rows.length > 0) k.log.info({ removed: rows.length }, 'offline artifacts swept');
  return rows.length;
}

/** 启动一次 + 每小时一次（与 hls 的 sweep 同形态，但间隔更长：产物被复用的概率更高） */
export function startArtifactSweeper(k: KernelApi): () => void {
  const kick = setTimeout(() => {
    void sweepArtifacts(k).catch((err) =>
      k.log.warn({ err: String(err) }, 'offline artifacts sweep failed'),
    );
  }, 5_000);
  kick.unref?.();
  const timer = setInterval(() => {
    void sweepArtifacts(k).catch((err) =>
      k.log.warn({ err: String(err) }, 'offline artifacts sweep failed'),
    );
  }, ARTIFACT_SWEEP_MS);
  timer.unref?.();
  return () => {
    clearTimeout(kick);
    clearInterval(timer);
  };
}
