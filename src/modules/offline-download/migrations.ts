import { sql } from 'kysely';
import type { Migration } from '../../../kernel/migrator';

/**
 * 离线下载：任务行 + 产物行。
 *
 * 为什么单独建表而不是复用 `tasks`（内核任务队列）：
 *   - `tasks` 是**服务端自己跑的活**，30 天就被 prune 掉；客户端要按 itemId 查
 *     「我下过没有」「有没有正在跑的任务」，需要长期存在且能被索引的实体；
 *   - 产物还要单独算 sha256 / 引用计数 / TTL，跟任务的生命周期不是一条线
 *     （产物可以被多个任务复用，也可以在任务删掉之后继续被下载）。
 *
 * 为什么不在这里存任何客户端状态（已下载字节 / 本地路径）：
 *   离线副本是**设备级**数据，服务端不知道也不该知道某台机器上有没有这份文件。
 */
export const OFFLINE_MIGRATIONS: Migration[] = [
  {
    id: '180_offline_download',
    async up(db) {
      await sql`
        create table if not exists offline_jobs (
          id text primary key,
          task_id text not null default '',
          item_id text not null,
          library_id text not null default '',
          series_key text,
          cache_key text not null default '',
          spec text not null default '{}',
          operation text not null default 'create',
          idempotency_key text,
          artifact_id text,
          state text not null default 'queued',
          progress real not null default 0,
          error text,
          created_at integer not null,
          updated_at integer not null
        )
      `.execute(db);

      // 面板按「最近的在前」翻页
      await sql`
        create index if not exists idx_offline_jobs_created
        on offline_jobs (state, created_at desc)
      `.execute(db);

      // 同一源视频 + 同一套参数，只允许一条活动任务。
      //
      // 注意唯一性口径是 (item_id, cache_key) 而**不是** item_id：
      // 「同一部电影只留一个本地版本」是**设备级**约束（由客户端保证）；
      // 服务端这里只负责「别为同一份产物重复转码」。两台设备同时要 1080p 和 720p
      // 是合理需求，按 item_id 唯一会直接 409 掉第二台。
      await sql`
        create unique index if not exists ux_offline_jobs_active
        on offline_jobs (item_id, cache_key)
        where state in ('queued', 'transcoding')
      `.execute(db);

      // 幂等键：同一个 idempotencyKey 重复 POST 只落一行（客户端重试 / 重连不会翻倍）
      await sql`
        create unique index if not exists ux_offline_jobs_idem
        on offline_jobs (idempotency_key)
        where idempotency_key is not null
      `.execute(db);

      await sql`
        create table if not exists offline_artifacts (
          id text primary key,
          cache_key text not null unique,
          rel_path text not null,
          size integer not null default 0,
          sha256 text not null default '',
          etag text not null default '',
          mime text not null default 'video/mp4',
          width integer,
          height integer,
          duration integer,
          video_codec text,
          audio_codec text,
          bitrate integer,
          container text not null default 'mp4',
          state text not null default 'active',
          ref_count integer not null default 0,
          created_at integer not null,
          last_hit_at integer not null
        )
      `.execute(db);

      // 回收扫描：引用计数为 0 且久未命中的产物
      await sql`
        create index if not exists idx_offline_artifacts_sweep
        on offline_artifacts (state, ref_count, last_hit_at)
      `.execute(db);
    },
  },
];
