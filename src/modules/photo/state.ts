import { sql } from 'kysely';

/**
 * 照片的「个人状态」：收藏 / 回收站 / 永久移出。
 *
 * 同源目录复用后 `photo_items` 是多个账号共用的一份（缩略图 / 人脸 / 场景 / 活动
 * 都按 photo_id 挂一次），因此这些东西**不能**再存在照片行上，否则 A 收藏或删除
 * 会直接改变 B 看到的结果。这里统一按 `(owner_id, item_id)` 落到
 * `photo_item_user_state`，缺行即「未收藏、未进回收站、未移出」。
 *
 * 所有对外的读取都应走 `favoriteOf` / `notTrashed`，写入走 setFavorite / trashItems。
 */

/** 收藏标记（0/1），可直接当 select 的列用 */
export function favoriteOf(idExpr: string, uid: string) {
  return sql<number>`coalesce((
    select s.favorite from photo_item_user_state s
     where s.owner_id = ${uid} and s.item_id = ${sql.raw(idExpr)}
  ), 0)`;
}

/** 回收站标记（0/1） */
export function trashedOf(idExpr: string, uid: string) {
  return sql<number>`coalesce((
    select s.in_trash from photo_item_user_state s
     where s.owner_id = ${uid} and s.item_id = ${sql.raw(idExpr)}
  ), 0)`;
}

/** 进入回收站的时间（未删除为 null） */
export function deletedAtOf(idExpr: string, uid: string) {
  return sql<number | null>`(
    select s.deleted_at from photo_item_user_state s
     where s.owner_id = ${uid} and s.item_id = ${sql.raw(idExpr)}
  )`;
}

/** 删除批次（回收站按批次分组用） */
export function deleteBatchOf(idExpr: string, uid: string) {
  return sql<string | null>`(
    select s.delete_batch_id from photo_item_user_state s
     where s.owner_id = ${uid} and s.item_id = ${sql.raw(idExpr)}
  )`;
}

/** 当前账号能看到这张照片（未进回收站、未被永久移出） */
export function notTrashed(idExpr: string, uid: string) {
  return sql`not exists (
    select 1 from photo_item_user_state s
     where s.owner_id = ${uid} and s.item_id = ${sql.raw(idExpr)}
       and (s.in_trash = 1 or s.removed = 1)
  )`;
}

/** 只看当前账号的收藏 */
export function onlyFavorite(idExpr: string, uid: string) {
  return sql`exists (
    select 1 from photo_item_user_state s
     where s.owner_id = ${uid} and s.item_id = ${sql.raw(idExpr)} and s.favorite = 1
  )`;
}

/** 当前账号的可见照片 id 子查询（给派生数据接口补作用域） */
export function visibleItemIds(uid: string) {
  return sql`select i.id from photo_items i
    where i.library_id in (select id from photo_library_scope where owner_id = ${uid})
      and ${notTrashed('i.id', uid)}`;
}

function idList(ids: string[]) {
  return sql.join(
    ids.map((id) => sql`${id}`),
    sql`, `,
  );
}

const now = () => Math.floor(Date.now() / 1000);

/** 只改「属于当前账号可见范围」的照片，避免把状态写到别人库里的行上 */
export async function setFavorite(
  db: any,
  uid: string,
  ids: string[],
  favorite: boolean,
): Promise<number> {
  if (ids.length === 0) return 0;
  const visible = (
    await sql<{ id: string }>`
      select i.id from photo_items i
       where i.id in (${idList(ids)})
         and i.library_id in (select id from photo_library_scope where owner_id = ${uid})
    `.execute(db)
  ).rows.map((r) => r.id);
  if (visible.length === 0) return 0;
  const fav = favorite ? 1 : 0;
  const ts = now();
  for (const id of visible) {
    await sql`
      insert into photo_item_user_state (owner_id, item_id, favorite, updated_at)
      values (${uid}, ${id}, ${fav}, ${ts})
      on conflict(owner_id, item_id) do update set
        favorite = excluded.favorite,
        updated_at = excluded.updated_at
    `.execute(db);
  }
  return visible.length;
}

/** 移入回收站（一个批次），返回实际改动的数量 */
export async function trashItems(
  db: any,
  uid: string,
  ids: string[],
  batchId: string,
): Promise<{ count: number; visible: string[] }> {
  if (ids.length === 0) return { count: 0, visible: [] };
  const visible = (
    await sql<{ id: string }>`
      select i.id from photo_items i
       where i.id in (${idList(ids)})
         and i.library_id in (select id from photo_library_scope where owner_id = ${uid})
         and ${notTrashed('i.id', uid)}
    `.execute(db)
  ).rows.map((r) => r.id);
  const ts = now();
  for (const id of visible) {
    await sql`
      insert into photo_item_user_state
        (owner_id, item_id, in_trash, deleted_at, delete_batch_id, removed, updated_at)
      values (${uid}, ${id}, 1, ${ts}, ${batchId}, 0, ${ts})
      on conflict(owner_id, item_id) do update set
        in_trash = 1,
        deleted_at = excluded.deleted_at,
        delete_batch_id = excluded.delete_batch_id,
        removed = 0,
        updated_at = excluded.updated_at
    `.execute(db);
  }
  return { count: visible.length, visible };
}

/** 从回收站还原（按照片，或按批次） */
export async function restoreItems(
  db: any,
  uid: string,
  opts: { ids?: string[]; batchId?: string },
): Promise<number> {
  const cond = opts.ids
    ? sql`item_id in (${idList(opts.ids)})`
    : sql`delete_batch_id = ${opts.batchId || ''}`;
  const res = await sql`
    update photo_item_user_state
       set in_trash = 0, deleted_at = null, delete_batch_id = null, updated_at = ${now()}
     where owner_id = ${uid} and removed = 0 and in_trash = 1 and ${cond}
  `.execute(db);
  return Number(res.numAffectedRows || 0);
}

/** 永久移出：只对当前账号隐藏，照片行与派生数据仍留给其他共享账号 */
export async function removeItemsForUser(db: any, uid: string, ids: string[]): Promise<number> {
  if (ids.length === 0) return 0;
  const ts = now();
  // 这里不排除「已在回收站」的照片：清空回收站正是从回收站里永久移出。
  const visible = (
    await sql<{ id: string }>`
      select i.id from photo_items i
       where i.id in (${idList(ids)})
         and i.library_id in (select id from photo_library_scope where owner_id = ${uid})
    `.execute(db)
  ).rows.map((r) => r.id);
  for (const id of visible) {
    await sql`
      insert into photo_item_user_state
        (owner_id, item_id, in_trash, deleted_at, delete_batch_id, removed, updated_at)
      values (${uid}, ${id}, 0, null, null, 1, ${ts})
      on conflict(owner_id, item_id) do update set
        in_trash = 0,
        deleted_at = null,
        delete_batch_id = null,
        removed = 1,
        updated_at = excluded.updated_at
    `.execute(db);
  }
  return visible.length;
}
