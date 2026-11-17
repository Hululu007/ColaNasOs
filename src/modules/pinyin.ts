import { sql } from 'kysely';
import { pinyin } from 'pinyin-pro';
import type { KernelApi } from '../../kernel/types';

/**
 * 搜索用的拼音键：原文 + 全拼 + 首字母，小写、空格分隔。
 *
 * 为什么不存原始拼音数组：搜索侧只需要一个可以 `like '%关键词%'` 的字符串，
 * 拆列反而让查询要拼好几个条件。一个词包三样写法：
 *
 * ```
 * 我爱台妹 → "我爱台妹 woaitaimei watm"
 * ```
 *
 * 于是「woai」「watm」「台妹」三种输入都能命中同一条。
 *
 * 只在**写入时**算一次（扫描入库 / 回填），查询时零开销 —— 拼音转换要走完整
 * 字典，放在每键一次的搜索里必卡。
 */
export function pinyinKey(...parts: Array<string | null | undefined>): string {
  const seen = new Set<string>();
  const words: string[] = [];
  for (const raw of parts) {
    const text = String(raw ?? '').trim();
    if (!text) continue;
    // 原文本身也算一个词：中文直搜命中「原文」这一份
    for (const piece of [text, ...text.split(/\s+/)]) {
      const value = piece.trim().toLowerCase();
      if (value && !seen.has(value)) {
        seen.add(value);
        words.push(value);
      }
    }
    // 没汉字就不用算拼音（纯英文 / 数字的标题算出来跟原文一样）
    if (!/[\u3400-\u9fff\uf900-\ufaff]/.test(text)) continue;
    try {
      const full = pinyin(text, { toneType: 'none', type: 'array', nonZh: 'consecutive' })
        .join('')
        .toLowerCase();
      const first = pinyin(text, {
        pattern: 'first',
        toneType: 'none',
        type: 'array',
        nonZh: 'consecutive',
      })
        .join('')
        .toLowerCase();
      for (const value of [full, first]) {
        if (value && !seen.has(value)) {
          seen.add(value);
          words.push(value);
        }
      }
    } catch {
      // 转换失败就只留原文：宁可搜不到拼音，也不能让入库挂掉
    }
  }
  return words.join(' ');
}


/**
 * 拼音键回填：加列之前入库的老数据没有 search_pinyin，后台慢慢补齐。
 *
 * 不放进迁移里：迁移是同步阻塞启动的，两万首曲子的拼音转换会把启动拖成十几秒。
 * 也不放任务队列：它跟用户操作无关，抢占扫描 / 转码的槽位不划算。
 */
export async function backfillPinyin(
  k: KernelApi,
  label: string,
  opts: {
    /** 按 id 游标取一批待补行（`after` 传上一批最后一个 id，空串表示从头发） */
    select: (limit: number, after: string) => Promise<Array<Record<string, any>>>;
    build: (row: Record<string, any>) => string;
    update: (id: string, key: string) => Promise<unknown>;
  },
): Promise<void> {
  const BATCH = 200;
  // 用 id 游标一轮轮往后走，而不是「每轮都从头查同一个条件」：
  // 万一某行的键补完仍然不满足判定条件（脏数据 / 判断条件写错），
  // 从头查的写法会永远捞到同一批行、在后台空转。
  const MAX_ROUNDS = 2000;
  let done = 0;
  let after = '';
  try {
    for (let round = 0; round < MAX_ROUNDS; round += 1) {
      const rows = await opts.select(BATCH, after);
      if (rows.length === 0) break;
      for (const row of rows) {
        after = String(row.id);
        await opts.update(after, opts.build(row));
        done += 1;
      }
      if (rows.length < BATCH) break;
    }
  } catch (err) {
    if (done > 0) k.log.warn(`[${label}] 拼音回填中断（已补 ${done} 条）：${err}`);
    return;
  }
  if (done > 0) k.log.info(`[${label}] 拼音搜索键回填完成：${done} 条`);
}

/** 回填某张表的 search_pinyin 列 */
export function backfillTablePinyin(
  k: KernelApi,
  label: string,
  table: 'video_items' | 'music_tracks',
  columns: string[],
  /** 待补判定；缺省「列还是空的」。必须是可重复执行不报错的布尔表达式。 */
  needsWork = 'search_pinyin is null',
): void {
  const select = async (limit: number, after: string) =>
    (
      await sql<Record<string, any>>`
        select id, ${sql.raw(columns.join(', '))} from ${sql.table(table)}
        where (${sql.raw(needsWork)}) and id > ${after}
        order by id limit ${limit}
      `.execute(k.db)
    ).rows;
  void backfillPinyin(k, label, {
    select,
    build: (row) => pinyinKey(...columns.map((c) => row[c])),
    update: (id, key) =>
      sql`update ${sql.table(table)} set search_pinyin = ${key} where id = ${id}`.execute(k.db),
  });
}
