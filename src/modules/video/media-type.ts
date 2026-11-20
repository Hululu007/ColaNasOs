import path from 'node:path';

/**
 * 影视库类型与日本电影库的文件名解析。
 *
 * 库类型**创建后不可改**（类型即行为）：movie / jp_movie / tv / short_tv / image / mixed。
 * 「日本电影」是独立类型而不是开关：索引、扫描、列表、字幕与角标全按 jp_movie 走。
 * 「短剧」的扫描 / 列表 / 详情 / 刮削与电视剧完全一致，唯一区别是播放器支持上下切集。
 */
export type LibType = 'movie' | 'jp_movie' | 'tv' | 'short_tv' | 'image' | 'mixed';

export const LIB_TYPES: LibType[] = ['movie', 'jp_movie', 'tv', 'short_tv', 'image', 'mixed'];

export function normalizeLibType(input: unknown): LibType {
  const text = String(input || '')
    .trim()
    .toLowerCase();
  return (LIB_TYPES as string[]).includes(text) ? (text as LibType) : 'movie';
}

/** 兼容老库：jp_movie=1 等价于 lib_type='jp_movie' */
export function libTypeOf(
  lib: { lib_type?: string | null; jp_movie?: number | null } | null,
): LibType {
  if (Number(lib?.jp_movie) === 1) return 'jp_movie';
  return normalizeLibType(lib?.lib_type);
}

const PREFIX_BLACKLIST = new Set([
  'S',
  'EP',
  'E',
  'PART',
  'PT',
  'VOL',
  'DISC',
  'CD',
  'CH',
  'WEB',
  'BD',
  'HD',
  'FHD',
  'UHD',
  'SD',
  'MP4',
  'MKV',
  'AVI',
  'X264',
  'X265',
  'H264',
  'H265',
  'HEVC',
  'AV1',
  'AAC',
  'DTS',
  'AC3',
  'FLAC',
  'HDR',
  'REMUX',
  'BLURAY',
  'XXX',
]);

/**
 * 从文件名里解析日本作品番号。
 *
 * 四种形态：
 *   FC2      FC2-PPV-1234567
 *   HEYZO    heyzo_hd_1031 → HEYZO-1031
 *   日期式    無码/素人：MMDDYY_001 / MMDDYY-820（1pondo / carib / 10musume）
 *   标准番号  ABC-123 / ABCD-12345（2~6 位字母 + 2~5 位数字）
 *
 * 分辨率与编码标记不算番号，但**只认带 P 后缀或 2160/4K/8K 的**：
 * `PGD-720-UC`、`SONE-720` 里的 720 是真番号号段，早先按「分辨率黑名单」整段跳过，
 * 导致这两个片子 code 为空、连搜索都不会发出去。
 */
export function parseJpCode(relPath: string): string | null {
  const base = (relPath.split('/').pop() || '')
    .replace(/\.[^.]+$/, '')
    .replace(/[[\]()（）【】]/g, ' ')
    .toUpperCase();

  // FC2-PPV-1234567
  const fc2 = /(FC2)[-_ ]*(PPV)?[-_ ]*(\d{5,8})/.exec(base);
  if (fc2) return `FC2-PPV-${fc2[3]}`;

  // HEYZO：heyzo_hd_1031 / heyzo-1031
  const heyzo = /(HEYZO)[-_ ]*(?:HD[-_ ]*)?(\d{3,5})(?![0-9])/.exec(base);
  if (heyzo) return `HEYZO-${heyzo[2]}`;

  // 日期式（無码/素人）：MMDDYY 后接 3 位序号，分隔符按原样保留（源站认 _ 也认 -）
  const dated = /(?:^|[^0-9])(\d{6})([_\-. ])(\d{3})(?![0-9])/.exec(base);
  if (dated) return `${dated[1]}${dated[2] === ' ' ? '_' : dated[2]}${dated[3]}`;

  const re = /(?:^|[^A-Z0-9])([A-Z]{2,6})[-_ ]?(\d{2,5})(?![0-9])/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(base)) !== null) {
    const prefix = m[1];
    const num = m[2];
    if (PREFIX_BLACKLIST.has(prefix)) continue;
    // 2160 / 4K / 8K 从不是番号号段
    if (/^(2160|4K|8K)$/.test(num)) continue;
    // 「ABCD 1080P」这种带 P 后缀的才是分辨率
    if (/^\d{3,4}$/.test(num) && /^P(?![A-Z0-9])/.test(base.slice(m.index + m[0].length))) continue;
    return `${prefix}-${num}`;
  }
  return null;
}

export function isUncensoredName(relPath: string): boolean {
  const text = relPath.toLowerCase();
  return /无码|無碼|無修正|uncensored|uncut|leak|流出/.test(text);
}

export function hasChineseSubName(relPath: string): boolean {
  const text = relPath.toLowerCase();
  return /中字|中文|中文字幕|简中|繁中|chs|cht|-c\b|ch\b/.test(text);
}

/**
 * 文件名后缀标记：`-U`（无码）/ `-C`（中字）/ `-UC`（两者）。
 * 允许标记后继续带 `.ltx`、`.4K` 等已知发布后缀。
 * 标记优先于关键词判断：文件名里写死的标记是用户显式表达，不再靠猜。
 * 返回去掉标记后的名字（供 NFO 猜测 / 标题显示）。
 */
export function parseJpTagsFromName(relPath: string): {
  uncensored: number;
  chineseSub: number;
  cleaned: string;
} {
  const base = path.basename(relPath);
  const ext = path.extname(base);
  const stem = ext ? base.slice(0, -ext.length) : base;
  const m =
    /-(UC|U|C)(?=$|(?:[._-](?:ltx|4k|2160p?|1080p?|720p?|chs|cht))*$)/i.exec(stem);
  if (!m) return { uncensored: 0, chineseSub: 0, cleaned: relPath };
  const tag = m[1].toUpperCase();
  const cleanedStem = stem.slice(0, stem.length - m[0].length);
  return {
    uncensored: tag === 'U' || tag === 'UC' ? 1 : 0,
    chineseSub: tag === 'C' || tag === 'UC' ? 1 : 0,
    cleaned: relPath.replace(stem + ext, cleanedStem + ext),
  };
}

/** 去掉结尾标记，避免它污染标题 / NFO 名匹配 */
export function normalizeNameForNfoGuess(relPath: string): string {
  return parseJpTagsFromName(relPath).cleaned;
}

/** 日本库角标 + 番号（非日本库返回 code=null）；结尾标记与关键词取「或」 */
export function jpMetaOf(
  relPath: string,
  ...metadataNames: Array<string | null | undefined>
): {
  code: string | null;
  uncensored: number;
  chineseSub: number;
} {
  const tags = parseJpTagsFromName(relPath);
  const nameText = [relPath, ...metadataNames].filter(Boolean).join(' ');
  return {
    code: parseJpCode(tags.cleaned),
    uncensored: tags.uncensored || (isUncensoredName(nameText) ? 1 : 0),
    chineseSub: tags.chineseSub || (hasChineseSubName(relPath) ? 1 : 0),
  };
}

/** 图片标题：去掉扩展名，保留文件夹层级里的最后一段 */
export function imageTitleOf(relPath: string): string {
  const base = path.basename(relPath);
  return base.replace(/\.[^.]+$/, '');
}
