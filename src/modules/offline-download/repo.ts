import crypto from 'node:crypto';
import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import type { ArtifactRow } from './artifacts';

/** 离线下载任务行 */
export interface JobRow {
  id: string;
  task_id: string;
  item_id: string;
  library_id: string;
  series_key: string | null;
  cache_key: string;
  spec: string;
  operation: string;
  idempotency_key: string | null;
  artifact_id: string | null;
  state: string;
  progress: number;
  error: string | null;
  created_at: number;
  updated_at: number;
}

/** 下载需要的那几列（不整行取，避免把 nfo / 演员这些大字段读进来） */
export interface DownloadItemRow {
  id: string;
  library_id: string;
  rel_path: string;
  title: string;
  duration: number | null;
  width: number | null;
  height: number | null;
  video_codec: string | null;
  audio_codec: string | null;
  container: string | null;
  has_subtitle: number;
  size: number;
  mtime: number;
  series: string | null;
  season: number | null;
  episode: number | null;
}

const now = (): number => Math.floor(Date.now() / 1000);

export async function loadDownloadItem(
  k: KernelApi,
  itemId: string,
): Promise<DownloadItemRow | null> {
  const row = (
    await sql<DownloadItemRow>`
      select id, library_id, rel_path, title, duration, width, height,
             video_codec, audio_codec, container, has_subtitle, size, mtime,
             series, season, episode
        from video_items
       where id = ${itemId}
    `.execute(k.db)
  ).rows[0];
  return row ?? null;
}

/** 库级「响度归一」开关：播放会带上它，下载必须同口径，否则同一部片两种音量 */
export async function libraryAudioNormalize(
  k: KernelApi,
  libraryId: string,
): Promise<boolean> {
  const row = (
    await sql<{ audio_normalize: number | null }>`
      select audio_normalize from video_libraries where id = ${libraryId}
    `.execute(k.db)
  ).rows[0];
  return Number(row?.audio_normalize) === 1;
}

export async function getJob(k: KernelApi, id: string): Promise<JobRow | null> {
  const row = (await sql<JobRow>`select * from offline_jobs where id = ${id}`.execute(k.db))
    .rows[0];
  return row ?? null;
}

export async function getJobByIdempotency(
  k: KernelApi,
  key: string,
): Promise<JobRow | null> {
  const row = (
    await sql<JobRow>`
      select * from offline_jobs where idempotency_key = ${key} limit 1
    `.execute(k.db)
  ).rows[0];
  return row ?? null;
}

/** 同一 item + 同一参数的**活动**任务（唯一索引 ux_offline_jobs_active 的读侧） */
export async function findActiveJob(
  k: KernelApi,
  itemId: string,
  cacheKey: string,
): Promise<JobRow | null> {
  const row = (
    await sql<JobRow>`
      select * from offline_jobs
       where item_id = ${itemId} and cache_key = ${cacheKey}
         and state in ('queued', 'transcoding')
       limit 1
    `.execute(k.db)
  ).rows[0];
  return row ?? null;
}

/** 这台服务端上该 item 最近完成的任务（产物指向的版本，用于回显「当前版本」） */
export async function findReadyJob(
  k: KernelApi,
  itemId: string,
): Promise<JobRow | null> {
  const row = (
    await sql<JobRow>`
      select * from offline_jobs
       where item_id = ${itemId} and state = 'ready'
       order by updated_at desc limit 1
    `.execute(k.db)
  ).rows[0];
  return row ?? null;
}

export async function insertJob(
  k: KernelApi,
  input: {
    id?: string;
    taskId?: string;
    itemId: string;
    libraryId: string;
    seriesKey?: string | null;
    cacheKey: string;
    spec: unknown;
    operation: string;
    idempotencyKey?: string | null;
    state?: string;
    progress?: number;
    artifactId?: string | null;
  },
): Promise<JobRow> {
  const id = input.id || crypto.randomUUID();
  const t = now();
  await sql`
    insert into offline_jobs
      (id, task_id, item_id, library_id, series_key, cache_key, spec, operation,
       idempotency_key, artifact_id, state, progress, created_at, updated_at)
    values
      (${id}, ${input.taskId ?? ''}, ${input.itemId}, ${input.libraryId},
       ${input.seriesKey ?? null}, ${input.cacheKey}, ${JSON.stringify(input.spec ?? {})},
       ${input.operation}, ${input.idempotencyKey ?? null}, ${input.artifactId ?? null},
       ${input.state ?? 'queued'}, ${input.progress ?? 0}, ${t}, ${t})
  `.execute(k.db);
  return (await getJob(k, id)) as JobRow;
}

export async function updateJob(
  k: KernelApi,
  id: string,
  patch: {
    state?: string;
    progress?: number;
    error?: string | null;
    taskId?: string;
    artifactId?: string | null;
  },
): Promise<void> {
  const current = await getJob(k, id);
  if (!current) return;
  await sql`
    update offline_jobs
       set state = ${patch.state ?? current.state},
           progress = ${patch.progress ?? current.progress},
           error = ${patch.error === undefined ? current.error : patch.error},
           task_id = ${patch.taskId ?? current.task_id},
           artifact_id = ${patch.artifactId === undefined ? current.artifact_id : patch.artifactId},
           updated_at = ${now()}
     where id = ${id}
  `.execute(k.db);
}

/**
 * 把行转成接口 DTO。
 *
 * `artifact` 只在这里拼：任务行里那个 artifact_id 可能指向一条已经被回收的产物
 * （TTL 清理先删产物再删任务的情况），所以调用方传进来的必须是**校验过存在**的行。
 */
export function jobToDto(row: JobRow, artifact: ArtifactRow | null) {
  let spec: Record<string, unknown>;
  try {
    spec = JSON.parse(row.spec || '{}') as Record<string, unknown>;
  } catch {
    spec = {};
  }
  return {
    id: row.id,
    itemId: row.item_id,
    libraryId: row.library_id,
    ...(row.series_key ? { seriesKey: row.series_key } : {}),
    spec: {
      preset: String(spec.preset || ''),
      codec: String(spec.codec || ''),
      height: Number(spec.height) || 0,
      videoKbps: Number(spec.videoKbps) || 0,
      audioKbps: Number(spec.audioKbps) || 0,
      audioIndex: Number(spec.audioIndex) || 0,
      container: String(spec.container || 'mp4'),
      subtitleMode: String(spec.subtitleMode || 'none'),
    },
    operation: row.operation,
    state: row.state,
    progress: Math.round(Number(row.progress) || 0),
    ...(row.error ? { error: row.error } : {}),
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    ...(artifact
      ? {
          artifact: {
            id: artifact.id,
            size: Number(artifact.size) || 0,
            sha256: artifact.sha256,
            etag: artifact.etag,
            mime: artifact.mime,
            width: Number(artifact.width) || 0,
            height: Number(artifact.height) || 0,
            durationMs: Number(artifact.duration) || 0,
            videoCodec: artifact.video_codec || '',
            container: artifact.container,
            bitrateKbps: Number(artifact.bitrate) || 0,
          },
        }
      : {}),
  };
}
