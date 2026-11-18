import fs from 'node:fs';
import fsp from 'node:fs/promises';
import path from 'node:path';
import { sql } from 'kysely';
import { secured } from '../../../kernel/route';
import { Err } from '../../../kernel/errors';
import type { KernelApi, ServerModule } from '../../../kernel/types';
import { etagOf, matchesEtag, parseRange } from '../files/download';
import { filesRoot, resolveAnyPath } from '../files/fs-root';
import { isOfflinePath, offlineSmbPrefixes } from '../video/sources';
import {
  DEFAULT_PLAY_CODEC,
  PLAY_AUDIO_BITRATE_KBPS,
  PLAY_CODECS,
  PLAY_QUALITY_PRESETS,
  isPlayCodec,
} from '../videoPlayer/play-quality.generated';
import { OFFLINE_MIGRATIONS } from './migrations';
import * as S from './schemas';
import {
  type ArtifactRow,
  type ArtifactSpec,
  artifactById,
  artifactByCacheKey,
  artifactDirOf,
  artifactExists,
  cacheKeyOf,
  cleanupArtifacts,
  markDownloading,
  releaseArtifact,
  sha256File,
  startArtifactSweeper,
  storageUsageOf,
  touchArtifact,
  upsertArtifact,
} from './artifacts';
import {
  type DownloadItemRow,
  type JobRow,
  findActiveJob,
  getJob,
  getJobByIdempotency,
  insertJob,
  jobToDto,
  failOrphanJob,
  libraryAudioNormalize,
  loadDownloadItem,
  updateJob,
} from './repo';

const TAG = ['offline'];
const ref = (id: string) => ({ $ref: `${id}#` });

/**
 * offline-download：把「看过的片子留一份到本机」做成服务端能力。
 *
 * 职责边界（很重要，别越界）：
 *   - 服务端**只负责把片源压成一份可整包下载的文件**，并给出 sha256 / etag；
 *   - 客户端本地有没有这份文件、留了几个版本、删不删，全由客户端自己管
 *     （离线副本是设备级数据，服务端不该知道也不该干预）；
 *   - 服务端**永远不删原始影视文件**，产物只在自己的 `dataDir/offline` 下。
 *
 * 为什么产物要按参数指纹缓存：同一部片子两台设备、或者同一个人换设备重下，
 * 参数一样就该复用同一份产物。4K 软编一部片动辄半小时，重复编码纯属浪费。
 *
 * 编码跑在内核任务队列上（`offline.encode`），进度由 sidecar 的 ffmpeg
 * `-progress` 事件推上来 —— 不是按文件大小估的。
 */
export const offlineDownload: ServerModule = {
  id: 'offline-download',
  prefix: '/api/v1/offline-downloads',
  // 不新增 scope：下载影视就是读影视 + 让服务端跑转码，语义上和播放同权
  permissions: ['video:read', 'video:write'],
  dependsOn: ['files', 'video'],
  migrations: OFFLINE_MIGRATIONS,

  async register(app, k) {
    for (const schema of [
      S.OfflineSpec,
      S.QuoteBody,
      S.QuoteResponse,
      S.CreateJobBody,
      S.OfflineArtifact,
      S.OfflineJob,
      S.ListQuery,
      S.JobListResponse,
      S.OkResponse,
      S.StorageUsage,
      S.CleanupBody,
      S.CleanupResult,
      S.ReleaseResult,
    ]) {
      app.addSchema(schema);
    }

    // ------------------------------------------------------------ 参数解析

    type PresetRow = (typeof PLAY_QUALITY_PRESETS)[number];
    const bitrateFor = (p: PresetRow, codec: string): number =>
      Number((p.bitrates as Record<string, number>)[codec] ?? p.videoBitrateKbps ?? 0);

    /** 片源撑得住的档位高度（降序）。矮片源不列 1080P：那是放大再压，纯浪费 */
    const heightsFor = (sourceHeight: number): number[] => {
      const set = new Set<number>();
      for (const p of PLAY_QUALITY_PRESETS) {
        if (!p.height) continue;
        if (sourceHeight > 0 && p.height > sourceHeight) continue;
        set.add(p.height);
      }
      return [...set].sort((a, b) => b - a);
    };

    /** 同高度有 4 档码率，取中位当「标准」；省空间 / 高画质再用系数乘 */
    const presetForHeight = (height: number, codec: string): PresetRow | null => {
      const rows = PLAY_QUALITY_PRESETS.filter((p) => p.height === height);
      if (rows.length === 0) return null;
      const sorted = [...rows].sort((a, b) => bitrateFor(a, codec) - bitrateFor(b, codec));
      return sorted[Math.floor(sorted.length / 2)];
    };

    const QUALITY_FACTOR: Record<string, number> = {
      saver: 0.6,
      standard: 1,
      high: 1.8,
    };

    /** quote / jobs 共用的入参形状 */
    interface SpecInput {
      preset?: string;
      codec?: string;
      height?: number;
      qualityMode?: string;
      videoKbps?: number;
      audioIndex?: number;
      audioBitrateKbps?: number;
      subtitleMode?: string;
    }

    interface Resolved {
      spec: ArtifactSpec;
      recommendedKbps: number;
      minKbps: number;
      maxKbps: number;
      estimateBytes: number;
    }

    /**
     * 把请求参数收敛成一份**可执行**的 spec。
     *
     * 联动规则只在这里实现一次：客户端为了即时反馈会自己算一版，但以本函数为准
     * （片源只有 720p 时选 1080P 必须被夹到 720P，这件事只有服务端知道）。
     */
    function resolveSpec(item: DownloadItemRow, body: SpecInput): Resolved {
      const sourceHeight = Number(item.height) || 0;
      const durationMs = Number(item.duration) || 0;
      const audioIndex = Number.isInteger(body.audioIndex) && (body.audioIndex as number) >= 0
        ? (body.audioIndex as number)
        : 0;

      // 原画：不重编码，remux 到 mkv（mp4 装不了 DTS / PGS / 多音轨）。
      // 此时 codec / 码率 / 字幕全部锁死 —— 用户选了原画又让它转码是没有意义的组合。
      if (body.codec === 'original' || body.preset === 'original') {
        return {
          spec: {
            preset: 'original',
            codec: 'original',
            height: 0,
            videoKbps: 0,
            audioKbps: 0,
            audioIndex,
            container: 'mkv',
            subtitleMode: 'none',
          },
          recommendedKbps: 0,
          minKbps: 0,
          maxKbps: 0,
          // remux 不改变码率，体积基本就是源文件大小（封装开销 ±1%）
          estimateBytes: Math.round((Number(item.size) || 0) * 1.01),
        };
      }

      const codec = isPlayCodec(body.codec) ? body.codec : DEFAULT_PLAY_CODEC;
      // 高度优先级：显式 height > preset 的高度 > 默认档
      let wantedHeight = Number(body.height) || 0;
      if (wantedHeight <= 0 && body.preset) {
        const explicit = PLAY_QUALITY_PRESETS.find((p) => p.key === body.preset);
        if (explicit) wantedHeight = Number(explicit.height) || 0;
      }
      if (wantedHeight <= 0) {
        const fallback = PLAY_QUALITY_PRESETS.find((p) => p.key === '1080p_3m');
        wantedHeight = Number(fallback?.height) || 1080;
      }
      // 下降取最接近的合法档位：720p 片源请求 1080P → 720P，绝不上采样
      const allowed = heightsFor(sourceHeight);
      const height = allowed.find((h) => h <= wantedHeight) ?? allowed[allowed.length - 1] ?? 720;
      const row = presetForHeight(height, codec);
      const base = row ? bitrateFor(row, codec) : 0;
      const factor = QUALITY_FACTOR[String(body.qualityMode || 'standard')] ?? 1;
      const recommendedKbps = Math.max(1, Math.round(base * factor));
      const minKbps = Math.max(120, Math.round(recommendedKbps * 0.4));
      const maxKbps = Math.max(minKbps + 1, Math.round(recommendedKbps * 2.5));

      const manual = Number(body.videoKbps) || 0;
      const videoKbps =
        manual > 0 ? Math.min(maxKbps, Math.max(minKbps, Math.round(manual))) : recommendedKbps;
      const audioKbps = Number(body.audioBitrateKbps) || PLAY_AUDIO_BITRATE_KBPS;
      const subtitleMode = body.subtitleMode === 'embed' ? 'embed' : 'none';

      // 预估体积：(视频 + 音频) kbps × 时长 + 2% 封装开销
      const seconds = durationMs > 0 ? durationMs / 1000 : 0;
      const estimateBytes = Math.round(((videoKbps + audioKbps) * 1000 * seconds) / 8 * 1.02);

      return {
        spec: {
          preset: row?.key || 'custom',
          codec,
          height,
          videoKbps,
          audioKbps,
          audioIndex,
          container: 'mp4',
          subtitleMode,
        },
        recommendedKbps,
        minKbps,
        maxKbps,
        estimateBytes,
      };
    }

    /** 取片源绝对路径；SMB 离线 / 文件不存在都直接给客户端一个明确状态 */
    async function sourceAbsOf(item: DownloadItemRow): Promise<string> {
      const prefixes = await offlineSmbPrefixes(k.db);
      if (isOfflinePath(item.rel_path, prefixes)) {
        throw Object.assign(new Error('source offline'), { statusCode: 409 });
      }
      let abs: string;
      try {
        abs = resolveAnyPath(filesRoot(), item.rel_path);
      } catch {
        throw Object.assign(new Error('source missing'), { statusCode: 404 });
      }
      await fsp.access(abs).catch(() => {
        throw Object.assign(new Error('source missing'), { statusCode: 404 });
      });
      return abs;
    }

    async function loadItemOr404(itemId: string): Promise<DownloadItemRow> {
      const item = await loadDownloadItem(k, itemId);
      if (!item) {
        const err = new Error('item not found') as Error & { statusCode: number };
        err.statusCode = 404;
        throw err;
      }
      return item;
    }

    const seriesKeyOf = (item: DownloadItemRow): string | null =>
      item.series ? `${item.library_id}\u0000${item.series}` : null;

    // ------------------------------------------------------------ 编码任务

    /**
     * 编码任务：把 job 指的片源压成产物。
     *
     * 不自动重试（入队时 maxAttempts=1）：整片编码动辄十几分钟，自动重跑等于
     * 把失败再演一遍。失败就失败，让用户点重试 —— 重试是新的 job。
     */
    k.tasks.register('offline.encode', async (payload, ctx) => {
      const jobId = String((payload as { jobId?: string } | null)?.jobId || '');
      if (!jobId) return 0;
      const job = await getJob(k, jobId);
      if (!job) return 0;
      // 排队期间被取消：直接收手，别开始白烧 CPU
      if (job.state === 'canceled') return 0;

      const item = await loadDownloadItem(k, job.item_id);
      if (!item) {
        await updateJob(k, jobId, { state: 'failed', error: 'source_missing' });
        return 0;
      }

      // 产物已经在了（另一台设备刚编完 / 上次失败前其实已落盘）：直接绑定，不重编
      const existing = await artifactByCacheKey(k, job.cache_key);
      if (existing && (await artifactExists(k, existing))) {
        await sql`
          update offline_artifacts set ref_count = ref_count + 1 where id = ${existing.id}
        `.execute(k.db);
        await updateJob(k, jobId, {
          state: 'ready',
          progress: 100,
          error: null,
          artifactId: existing.id,
        });
        return 1;
      }

      let spec: ArtifactSpec;
      try {
        spec = JSON.parse(job.spec || '{}') as ArtifactSpec;
      } catch {
        await updateJob(k, jobId, { state: 'failed', error: 'bad_spec' });
        return 0;
      }

      const dir = artifactDirOf(k, job.cache_key);
      await updateJob(k, jobId, { state: 'transcoding', progress: 0, error: null });

      try {
        const abs = await sourceAbsOf(item);
        const normalize = await libraryAudioNormalize(k, item.library_id);
        const out = await k.media.encode(
          abs,
          dir,
          {
            preset: spec.preset,
            codec: spec.codec,
            height: spec.height,
            videoKbps: spec.videoKbps,
            audioIndex: spec.audioIndex,
            audioBitrateKbps: spec.audioKbps,
            subtitleMode: spec.subtitleMode === 'embed' ? 'embed' : 'none',
            // 库级响度归一与播放同口径：同一部片看和下载两种音量会让人以为文件坏了
            audioFilter:
              normalize && spec.codec !== 'original' ? 'dynaudnorm=f=200:g=15' : undefined,
            srcVideoCodec: item.video_codec || undefined,
            durationMs: Number(item.duration) || 0,
          },
          (p) => {
            // 进度写库（客户端轮询 GET /jobs/:id 看）与写任务面板各一份
            void updateJob(k, jobId, { progress: Math.round(p.percent) }).catch(() => undefined);
            void ctx.progress(p.percent).catch(() => undefined);
          },
        );

        const stat = await fsp.stat(out.dst);
        const sha = await sha256File(out.dst);
        const relPath = path.relative(k.paths.dataDir, out.dst).split(path.sep).join('/');
        const artifact = await upsertArtifact(k, {
          cacheKey: job.cache_key,
          relPath,
          size: stat.size,
          sha256: sha,
          etag: etagOf(stat.size, stat.mtimeMs),
          container: out.container,
          // 原画 remux 时产物的实际分辨率就是片源分辨率
          width: spec.codec === 'original' ? item.width : null,
          height: spec.codec === 'original' ? item.height : spec.height,
          durationMs: out.durationMs || Number(item.duration) || 0,
          videoCodec: out.codec || item.video_codec,
          audioCodec: 'aac',
          bitrateKbps: spec.codec === 'original' ? null : spec.videoKbps,
        });
        await sql`
          update offline_artifacts set ref_count = ref_count + 1 where id = ${artifact.id}
        `.execute(k.db);
        await updateJob(k, jobId, {
          state: 'ready',
          progress: 100,
          error: null,
          artifactId: artifact.id,
        });
        k.log.info(
          { job: jobId, item: job.item_id, bytes: stat.size, codec: out.codec, ms: out.ms },
          'offline encode done',
        );
        return 1;
      } catch (err) {
        const code = (err as { code?: string }).code;
        const message = String((err as Error)?.message || err);
        if (code === 'E_CANCELED') {
          await updateJob(k, jobId, { state: 'canceled', error: 'canceled' });
          await fsp.rm(dir, { recursive: true, force: true }).catch(() => undefined);
          return 0;
        }
        await updateJob(k, jobId, { state: 'failed', error: message.slice(0, 300) });
        // 失败不留半截产物：孤儿目录由 sweeper 兜底收，这里先主动清掉
        await fsp.rm(dir, { recursive: true, force: true }).catch(() => undefined);
        k.log.warn({ job: jobId, err: message }, 'offline encode failed');
        return 0;
      }
    });

    const stopSweeper = startArtifactSweeper(k);
    app.addHook('onClose', async () => {
      stopSweeper();
    });

    // ------------------------------------------------------------ 路由

    app.post(
      '/api/v1/offline-downloads/quote',
      secured('video:read', {
        schema: {
          operationId: 'offlineQuote',
          tags: TAG,
          summary: '下载参数推荐与校验（编码 / 分辨率 / 码率联动、预估体积）',
          body: ref('OfflineQuoteBody'),
          response: { 200: ref('OfflineQuoteResponse') },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as Record<string, unknown>;
        const itemId = String(body.itemId || '');
        if (!itemId) throw Object.assign(new Error('itemId required'), { statusCode: 400 });
        const item = await loadItemOr404(itemId);
        const resolved = resolveSpec(item, body as SpecInput);
        // 源不可用也照样给参数（用户可以先看预估），能不能提交由 POST /jobs 把关
        const cacheKey = cacheKeyOf(item.id, resolved.spec);
        const cached = await artifactByCacheKey(k, cacheKey);
        const cachedOk = cached ? await artifactExists(k, cached) : false;
        const active = await findActiveJob(k, item.id, cacheKey);
        const durationMs = Number(item.duration) || 0;
        const bytes = Number(item.size) || 0;

        return {
          source: {
            width: Number(item.width) || 0,
            height: Number(item.height) || 0,
            videoCodec: String(item.video_codec || ''),
            audioCodec: String(item.audio_codec || ''),
            durationMs,
            bytes,
            bitrateKbps: durationMs > 0 ? Math.round((bytes * 8) / (durationMs / 1000) / 1000) : 0,
            hasSubtitle: Number(item.has_subtitle) === 1,
          },
          capabilities: {
            codecs: ['original', ...PLAY_CODECS.map((c) => c.key)],
            heights: heightsFor(Number(item.height) || 0),
            maxHeight: Number(item.height) || 0,
          },
          target: resolved.spec,
          limits: {
            minKbps: resolved.minKbps,
            maxKbps: resolved.maxKbps,
            recommendedKbps: resolved.recommendedKbps,
          },
          estimate: { bytes: resolved.estimateBytes },
          cached: cachedOk,
          ...(active ? { activeJobId: active.id } : {}),
        };
      },
    );

    app.post(
      '/api/v1/offline-downloads/jobs',
      secured('video:write', {
        schema: {
          operationId: 'offlineJobCreate',
          tags: TAG,
          summary: '创建下载任务（同参数复用已有产物，同参数活动任务直接返回）',
          body: ref('OfflineCreateJobBody'),
          response: { 200: ref('OfflineJob') },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as Record<string, unknown>;
        const itemId = String(body.itemId || '');
        if (!itemId) throw Object.assign(new Error('itemId required'), { statusCode: 400 });

        // 幂等：同键重复提交只认第一次的结果（客户端重连 / 双击）
        const idem = body.idempotencyKey ? String(body.idempotencyKey) : '';
        if (idem) {
          const hit = await getJobByIdempotency(k, idem);
          if (hit) {
            const art = hit.artifact_id ? await artifactById(k, hit.artifact_id) : null;
            return jobToDto(hit, art && (await artifactExists(k, art)) ? art : null);
          }
        }

        const item = await loadItemOr404(itemId);
        await sourceAbsOf(item); // 源离线 / 不存在：409 / 404，别建一条注定失败的任务
        const resolved = resolveSpec(item, body as SpecInput);
        const cacheKey = cacheKeyOf(item.id, resolved.spec);
        const operation = body.operation === 'replace' ? 'replace' : 'create';

        // 同 item + 同参数已有活动任务：直接返回它，不重复建（需求书 §3.2 场景 B）
        const active = await findActiveJob(k, item.id, cacheKey);
        if (active) {
          const art = active.artifact_id ? await artifactById(k, active.artifact_id) : null;
          return jobToDto(active, art && (await artifactExists(k, art)) ? art : null);
        }

        // 产物已经在：只需一条 ready 的任务行，客户端立刻能下（换设备下同一份片子的常见路径）
        const cachedArtifact = await artifactByCacheKey(k, cacheKey);
        if (cachedArtifact && (await artifactExists(k, cachedArtifact))) {
          const job = await insertJob(k, {
            itemId: item.id,
            libraryId: item.library_id,
            seriesKey: seriesKeyOf(item),
            cacheKey,
            spec: resolved.spec,
            operation,
            idempotencyKey: idem || null,
            state: 'ready',
            progress: 100,
            artifactId: cachedArtifact.id,
          });
          await sql`
            update offline_artifacts set ref_count = ref_count + 1 where id = ${cachedArtifact.id}
          `.execute(k.db);
          return jobToDto(job, cachedArtifact);
        }

        const job = await insertJob(k, {
          itemId: item.id,
          libraryId: item.library_id,
          seriesKey: seriesKeyOf(item),
          cacheKey,
          spec: resolved.spec,
          operation,
          idempotencyKey: idem || null,
          state: 'queued',
        });
        // 单条尝试：整片编码失败自动重跑只是把失败再演一遍，让用户点重试。
        // priority=9（数值越大越靠后）：任务 worker 默认并发 1，一条整片编码要占住
        // 唯一槽位几十分钟，必须让扫描 / 刮削 / 备份这些短任务先跑。
        const taskId = await k.tasks.enqueue(
          'offline.encode',
          { jobId: job.id },
          { maxAttempts: 1, priority: 9 },
        );
        await updateJob(k, job.id, { taskId });
        return jobToDto({ ...job, task_id: taskId }, null);
      },
    );

    app.get(
      '/api/v1/offline-downloads/jobs',
      secured('video:read', {
        schema: {
          operationId: 'offlineJobList',
          tags: TAG,
          summary: '任务列表（详情页按钮状态 / 下载管理页轮询）',
          querystring: ref('OfflineListQuery'),
          response: { 200: ref('OfflineJobList') },
        },
      }),
      async (req) => {
        const q = (req.query || {}) as { itemId?: string; limit?: string };
        const limit = Math.max(1, Math.min(Number(q.limit) || 20, 100));
        const rows = q.itemId
          ? (
              await sql<JobRow>`
                select * from offline_jobs
                 where item_id = ${String(q.itemId)}
                 order by created_at desc limit ${limit}
              `.execute(k.db)
            ).rows
          : (
              await sql<JobRow>`
                select * from offline_jobs order by created_at desc limit ${limit}
              `.execute(k.db)
            ).rows;
        const total = Number(
          (
            await (q.itemId
              ? sql<{ n: number }>`
                  select count(*) as n from offline_jobs where item_id = ${String(q.itemId)}
                `.execute(k.db)
              : sql<{ n: number }>`select count(*) as n from offline_jobs`.execute(k.db))
          ).rows[0]?.n ?? 0,
        );
        const items = [];
        for (const row of rows) {
          const art = row.artifact_id ? await artifactById(k, row.artifact_id) : null;
          items.push(jobToDto(row, art && (await artifactExists(k, art)) ? art : null));
        }
        return { items, total };
      },
    );

    app.get(
      '/api/v1/offline-downloads/jobs/:id',
      secured('video:read', {
        schema: {
          operationId: 'offlineJobGet',
          tags: TAG,
          summary: '单个任务（状态 / 进度 / 产物）',
          response: { 200: ref('OfflineJob') },
        },
      }),
      async (req) => {
        const id = String((req.params as { id?: string }).id || '');
        const found = await getJob(k, id);
        if (!found) throw Object.assign(new Error('job not found'), { statusCode: 404 });
        // 编码任务已经收场的任务不再一直挂在「准备中」
        const job = await failOrphanJob(k, found);
        const art = job.artifact_id ? await artifactById(k, job.artifact_id) : null;
        return jobToDto(job, art && (await artifactExists(k, art)) ? art : null);
      },
    );

    app.post(
      '/api/v1/offline-downloads/jobs/:id/cancel',
      secured('video:write', {
        schema: {
          operationId: 'offlineJobCancel',
          tags: TAG,
          summary: '取消任务（杀掉正在跑的编码，清掉半截产物）',
          response: { 200: ref('OfflineOk') },
        },
      }),
      async (req) => {
        const id = String((req.params as { id?: string }).id || '');
        const job = await getJob(k, id);
        if (!job) throw Object.assign(new Error('job not found'), { statusCode: 404 });
        if (job.state === 'ready' || job.state === 'canceled' || job.state === 'failed') {
          return { ok: true, affected: 0 };
        }
        // 先改库再杀进程：反过来的话，杀掉后 handler 会先写 failed
        await updateJob(k, id, { state: 'canceled', error: 'canceled' });
        if (job.task_id) await k.tasks.cancel(job.task_id).catch(() => undefined);
        // 与 hls 共用 sidecar 的 active 表：按产物目录精确命中这一条 ffmpeg
        await k.media.cancel(artifactDirOf(k, job.cache_key)).catch(() => undefined);
        return { ok: true, affected: 1 };
      },
    );

    /**
     * 服务端转码产物的占用。
     *
     * 产物是「下载用的中转副本」：客户端把文件拿到本机之后，服务端这份留着只是为了
     * 同参数再下一次时免重编，长期留着纯占盘，所以下载页要能看见 + 一键清。
     */
    app.get(
      '/api/v1/offline-downloads/storage',
      secured('video:read', {
        schema: {
          operationId: 'offlineStorage',
          tags: TAG,
          summary: '服务端转码产物占用（个数 / 体积 / 最久天数）',
          response: { 200: ref('OfflineStorageUsage') },
        },
      }),
      async () => storageUsageOf(k),
    );

    app.post(
      '/api/v1/offline-downloads/storage/cleanup',
      secured('video:write', {
        schema: {
          operationId: 'offlineStorageCleanup',
          tags: TAG,
          summary: '清理服务端转码产物（不动原始影片，不动已下载到本机的文件）',
          body: ref('OfflineCleanupBody'),
          response: { 200: ref('OfflineCleanupResult') },
        },
      }),
      async (req) => {
        const body = (req.body || {}) as { olderThanDays?: number };
        const days = Number.isFinite(Number(body.olderThanDays))
          ? Number(body.olderThanDays)
          : 0;
        return cleanupArtifacts(k, days);
      },
    );

    /**
     * 归还引用。客户端下载 + 校验通过后调一次，让产物能按 TTL 自然回收。
     * 幂等：重复调用最多把 ref_count 减到 0，不会变负。
     */
    app.post(
      '/api/v1/offline-downloads/jobs/:id/release',
      secured('video:write', {
        schema: {
          operationId: 'offlineJobRelease',
          tags: TAG,
          summary: '释放任务占用的产物引用（下载完成后调用）',
          response: { 200: ref('OfflineReleaseResult') },
        },
      }),
      async (req) => {
        const id = String((req.params as { id?: string }).id || '');
        const job = await getJob(k, id);
        if (!job || !job.artifact_id) return { ok: true, refCount: 0 };
        const refCount = await releaseArtifact(k, job.artifact_id);
        return { ok: true, refCount };
      },
    );

    app.get(
      '/api/v1/offline-downloads/jobs/:id/artifact',
      secured('video:read', {
        schema: {
          operationId: 'offlineJobArtifact',
          tags: TAG,
          summary: '任务产物的元信息（大小 / sha256 / etag / 规格）',
          response: { 200: ref('OfflineArtifact') },
        },
      }),
      async (req) => {
        const id = String((req.params as { id?: string }).id || '');
        const job = await getJob(k, id);
        if (!job) throw Object.assign(new Error('job not found'), { statusCode: 404 });
        if (job.state !== 'ready' || !job.artifact_id) {
          throw Object.assign(new Error('artifact not ready'), { statusCode: 409 });
        }
        const art = await artifactById(k, job.artifact_id);
        if (!art || !(await artifactExists(k, art))) {
          throw Object.assign(new Error('artifact missing'), { statusCode: 410 });
        }
        const dto = jobToDto(job, art);
        if (!dto.artifact) throw Object.assign(new Error('artifact missing'), { statusCode: 410 });
        return dto.artifact;
      },
    );

    /**
     * 产物下载：Range / ETag / If-Range / 416，语义与 `/files/download` 一致。
     * 唯一的区别是**只认产物 id**，不接受路径参数 —— 少一个穿越面。
     */
    app.get(
      '/api/v1/offline-downloads/artifacts/:id',
      secured('video:read', {
        schema: {
          operationId: 'offlineArtifactDownload',
          tags: TAG,
          summary: '下载产物文件（支持 Range 断点续传）',
        },
      }),
      async (req, reply) => {
        const id = String((req.params as { id?: string }).id || '');
        const row = await artifactById(k, id);
        if (!row || row.state !== 'active') {
          return reply.code(404).send({ error: Err.notFound, message: 'artifact not found' });
        }
        const abs = path.join(k.paths.dataDir, row.rel_path);
        const st = await fsp.stat(abs).catch(() => null);
        if (!st || !st.isFile()) {
          return reply.code(410).send({ error: Err.gone, message: 'artifact file missing' });
        }

        const etag = etagOf(st.size, st.mtimeMs);
        reply.header('ETag', etag);
        reply.header('Last-Modified', st.mtime.toUTCString());
        reply.header('Accept-Ranges', 'bytes');
        reply.header('Cache-Control', 'private, max-age=0');
        // 客户端边下边算 sha256，下完直接比对，不用再读一遍盘
        reply.header('x-artifact-sha256', row.sha256);
        reply.header('Content-Type', row.mime || 'application/octet-stream');
        reply.header(
          'Content-Disposition',
          `attachment; filename="${encodeURIComponent(path.basename(abs))}"`,
        );

        const ifNoneMatch = req.headers['if-none-match'];
        if (typeof ifNoneMatch === 'string' && matchesEtag(ifNoneMatch, etag)) {
          return reply.code(304).send();
        }

        void touchArtifact(k, row.id).catch(() => undefined);

        // 流一旦建出来就登记成「正在下载」，清理时不会把这份删掉
        const streamOf = (opts?: { start: number; end: number }): fs.ReadStream => {
          const stream = opts ? fs.createReadStream(abs, opts) : fs.createReadStream(abs);
          markDownloading(row.id, stream);
          return stream;
        };

        let rangeHeader = req.headers.range;
        const ifRange = req.headers['if-range'];
        if (rangeHeader && typeof ifRange === 'string' && ifRange !== etag) rangeHeader = undefined;

        if (!rangeHeader) {
          reply.header('Content-Length', String(st.size));
          return reply.code(200).send(streamOf());
        }

        const range = parseRange(rangeHeader, st.size);
        if (range === 'unsatisfiable') {
          return reply.code(416).header('Content-Range', `bytes */${st.size}`).send();
        }
        if (range === null) {
          reply.header('Content-Length', String(st.size));
          return reply.code(200).send(streamOf());
        }
        reply
          .code(206)
          .header('Content-Range', `bytes ${range.start}-${range.end}/${st.size}`)
          .header('Content-Length', String(range.end - range.start + 1));
        return reply.send(streamOf({ start: range.start, end: range.end }));
      },
    );

    app.delete(
      '/api/v1/offline-downloads/artifacts/:id',
      secured('video:write', {
        schema: {
          operationId: 'offlineArtifactDelete',
          tags: TAG,
          summary: '删除服务端产物（仅在没有任何引用时；永不碰原始影视文件）',
          response: { 200: ref('OfflineOk') },
        },
      }),
      async (req) => {
        const id = String((req.params as { id?: string }).id || '');
        const row: ArtifactRow | null = await artifactById(k, id);
        if (!row) return { ok: true, affected: 0 };
        if (Number(row.ref_count) > 0) {
          throw Object.assign(new Error('artifact in use'), { statusCode: 409 });
        }
        await fsp
          .rm(path.dirname(path.join(k.paths.dataDir, row.rel_path)), {
            recursive: true,
            force: true,
          })
          .catch(() => undefined);
        await sql`delete from offline_artifacts where id = ${id}`.execute(k.db);
        return { ok: true, affected: 1 };
      },
    );
  },
};
