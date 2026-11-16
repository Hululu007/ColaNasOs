import { sql } from 'kysely';
import type { KernelApi } from '../../../kernel/types';
import { recordDeletedFingerprints } from './deleted-fp';
import { removeItemsForUser } from './state';

/**
 * 相册永久删除与回收站保留策略。
 *
 * 口径（与现有「清空回收站只删索引、不动磁盘文件」一致）：
 *   - 永久删除 = 删 `photo_items` + 所有派生数据（场景/活动/OCR/向量/人脸/相册成员/GPS 候选），
 *     磁盘原图不动；
 *   - 回收站保留 **30 天**，超过后由定时任务按同一套级联逻辑清理。
 *
 * 同源目录复用后：
 *   - 回收站 / 收藏是**账号私有**状态（photo_item_user_state）；
 *   - 同一个来源被多个账号共享时，某个账号「永久删除」只对他自己隐藏，
 *     真正的行级删除只发生在「该来源没有任何其他共享账号」的情况，
 *     否则会把别人的照片索引一起删掉。
 */
export const TRASH_RETENTION_DAYS = 30;

/** 以 photo_id 关联的表 */
const PHOTO_ID_TABLES = [
  'photo_scenes',
  'photo_activities',
  'photo_ocr',
  'photo_embeddings',
  'photo_faces',
  'photo_gps_candidates',
];

/** 以 item_id 关联的表。
 *
 * 集合并入相册后 `photo_collection_items` 已经不存在（迁移 169 删掉了）——
 * 留在这里会让「彻底删除」在 `delete from` 一张不存在的表时直接抛错，
 * 表现是清空回收站失败。 */
const ITEM_ID_TABLES = ['photo_album_items', 'photo_item_user_state'];

function idList(ids: string[]) {
  return sql.join(
    ids.map((id) => sql`${id}`),
    sql`, `,
  );
}

async function deleteRows(db: any, ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  const list = idList(ids);
  for (const table of PHOTO_ID_TABLES) {
    await sql`delete from ${sql.table(table)} where photo_id in (${list})`.execute(db);
  }
  for (const table of ITEM_ID_TABLES) {
    await sql`delete from ${sql.table(table)} where item_id in (${list})`.execute(db);
  }
  await sql`delete from photo_items where id in (${list})`.execute(db);
}

/** 这些照片所在来源是否还有「别的账号也在看」 */
async function sharedFlags(
  db: any,
  ids: string[],
): Promise<Map<string, { library_id: string; shared: boolean }>> {
  const out = new Map<string, { library_id: string; shared: boolean }>();
  if (ids.length === 0) return out;
  const rows = (
    await sql<{ id: string; library_id: string; n: number }>`
      select i.id, i.library_id,
             (select count(*) from photo_library_shares s where s.library_id = i.library_id) as n
        from photo_items i
       where i.id in (${idList(ids)})
    `.execute(db)
  ).rows;
  for (const r of rows) out.set(r.id, { library_id: r.library_id, shared: Number(r.n) > 0 });
  return out;
}

/** 永久删除：只删索引与派生数据，磁盘文件保留 */
export async function deletePhotosPermanently(
  k: KernelApi,
  owner: string,
  ids: string[],
): Promise<number> {
  if (ids.length === 0) return 0;
  return k.db.transaction().execute(async (trx: any) => {
    const rows = (
      await sql<{ id: string }>`
        select id from photo_items
         where id in (${idList(ids)})
           and library_id in (select id from photo_library_scope where owner_id = ${owner})
      `.execute(trx)
    ).rows;
    const owned = rows.map((r) => r.id);
    if (owned.length === 0) return 0;
    // 先留指纹再删行：删完就再也算不出这张照片原来是什么内容了，
    // 手机下次备份会把它当新照片再传一遍。
    await recordDeletedFingerprints(trx, owner, owned);

    const flags = await sharedFlags(trx, owned);
    const physical = owned.filter((id) => !flags.get(id)?.shared);
    const personal = owned.filter((id) => flags.get(id)?.shared);
    await deleteRows(trx, physical);
    // 共享来源：只对当前账号隐藏，照片行与派生数据留给其他账号继续用。
    if (personal.length > 0) await removeItemsForUser(trx, owner, personal);
    return owned.length;
  });
}

/** 超过保留期的回收站条目：按 500 一批清理（跨用户，由后台定时任务调用） */
export async function purgeExpiredTrash(
  k: KernelApi,
  days = TRASH_RETENTION_DAYS,
): Promise<number> {
  const cutoff = Math.floor(Date.now() / 1000) - days * 86400;
  let total = 0;
  for (let round = 0; round < 20; round += 1) {
    const rows = (
      await sql<{
        owner_id: string;
        item_id: string;
        library_id: string;
        n: number;
      }>`
        select s.owner_id, s.item_id, i.library_id,
               (select count(*) from photo_library_shares sh where sh.library_id = i.library_id) as n
          from photo_item_user_state s
          join photo_items i on i.id = s.item_id
         where s.in_trash = 1 and s.removed = 0
           and s.deleted_at is not null and s.deleted_at < ${cutoff}
         limit 500
      `.execute(k.db)
    ).rows;
    if (rows.length === 0) break;

    const physical = rows.filter((r) => Number(r.n) === 0).map((r) => r.item_id);
    const personal = rows.filter((r) => Number(r.n) > 0);
    await k.db.transaction().execute(async (trx: any) => {
      // 跨用户批处理：owner 传空串，按每条记录自己的 owner 落墓碑
      if (physical.length > 0) {
        await recordDeletedFingerprints(trx, '', physical);
        await deleteRows(trx, physical);
      }
      for (const r of personal) {
        await sql`
          update photo_item_user_state
             set in_trash = 0, deleted_at = null, delete_batch_id = null,
                 removed = 1, updated_at = ${Math.floor(Date.now() / 1000)}
           where owner_id = ${r.owner_id} and item_id = ${r.item_id}
        `.execute(trx);
      }
    });
    total += rows.length;
  }
  return total;
}
