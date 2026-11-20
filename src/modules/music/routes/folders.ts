import { sql } from 'kysely';
import { pathVisible, pathWhere, visibilityOf } from '../../files/visibility';
import { secured } from '../../../../kernel/route';
import { Err } from '../../../../kernel/errors';
import { TAG, TrackRow, toTrack } from '../util';
import type { FastifyInstance } from 'fastify';
import type { KernelApi } from '../../../../kernel/types';
import type { MusicHelpers } from '../helpers';

/**
 * 文件夹浏览。
 *
 * 目录树直接由 `music_tracks.rel_path` 反推：音乐库里没有「目录表」，
 * 曲目是唯一的真相来源，也顺带保证「列出来的目录一定点得进去」——
 * 空目录、只有歌词/封面的目录不会出现在列表里。
 *
 * 只返回两层信息：当前目录下的**子目录**（含递归曲目数）和**直属曲目**。
 * 歌词（.lrc）、封面（cover.jpg）不在 `music_tracks` 里，自然不会出现。
 */
function normalizeDir(raw: unknown): string {
  return String(raw ?? '')
    .replace(/\\/g, '/')
    .split('/')
    .filter((seg) => seg.length > 0 && seg !== '.' && seg !== '..')
    .join('/');
}

export async function registerMusicFolders(
  app: FastifyInstance,
  k: KernelApi,
  h: MusicHelpers,
): Promise<void> {
  app.get(
    '/api/v1/music/folders',
    secured('music:read', {
      schema: {
        operationId: 'musicFolders',
        tags: TAG,
        summary: '文件夹浏览：子目录 + 当前目录下的曲目',
        querystring: h.ref('MusicFoldersQuery'),
        response: { 200: h.ref('MusicFoldersResponse'), 400: h.ref('MusicErrorResponse') },
      },
    }),
    async (req, reply) => {
      const q = (req.query || {}) as { libraryId?: string; dir?: string };
      const libraryId = String(q.libraryId ?? '').trim();
      if (!libraryId) {
        return reply.code(400).send({ error: Err.badRequest, message: 'libraryId required' });
      }

      const lib = (
        await sql<{ id: string; root_path: string }>`
          select id, root_path from music_libraries where id = ${libraryId} limit 1
        `.execute(k.db)
      ).rows[0];
      if (!lib) {
        return reply.code(404).send({ error: Err.notFound, message: 'library not found' });
      }

      const vis = visibilityOf(k.config, req.user);
      if (!pathVisible(vis, lib.root_path)) {
        return reply.code(403).send({ error: Err.forbidden, message: 'library not readable' });
      }

      const dir = normalizeDir(q.dir);
      const root = lib.root_path.replace(/^\/+|\/+$/g, '');
      const base = root ? (dir ? `${root}/${dir}` : root) : dir;
      if (!base) {
        return reply.code(400).send({ error: Err.badRequest, message: 'empty library root' });
      }

      const like = `${base}/%`;
      const visWhere = pathWhere(vis, 'rel_path');
      // 去掉 `<base>/` 前缀后的剩余部分：`instr(rest,'/') = 0` 即「本层文件」
      const rest = sql`substr(rel_path, ${base.length + 2})`;

      const files = await sql<TrackRow>`
        select * from music_tracks
         where library_id = ${libraryId}
           and rel_path like ${like}
           and instr(${rest}, '/') = 0
           and (${visWhere})
         order by coalesce(track_no, 9999), title
         limit 2000
      `.execute(k.db);

      const dirs = await sql<{ seg: string; tracks: number }>`
        select substr(rest, 1, instr(rest, '/') - 1) as seg, count(*) as tracks
          from (
            select substr(rel_path, ${base.length + 2}) as rest
              from music_tracks
             where library_id = ${libraryId}
               and rel_path like ${like}
               and (${visWhere})
          )
         where instr(rest, '/') > 0
         group by seg
         order by seg
      `.execute(k.db);

      return {
        dir,
        items: dirs.rows.map((r) => ({
          name: String(r.seg),
          path: dir ? `${dir}/${r.seg}` : String(r.seg),
          tracks: Number(r.tracks) || 0,
        })),
        files: files.rows.map(toTrack),
      };
    },
  );
}
