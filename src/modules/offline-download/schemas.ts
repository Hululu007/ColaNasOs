import { Type } from '@sinclair/typebox';
import { PLAY_CODECS, PLAY_QUALITY_PRESETS } from '../videoPlayer/play-quality.generated';

/** offline-download（离线下载）路由契约 */

const PresetUnion = Type.Union(
  PLAY_QUALITY_PRESETS.map((p) => Type.Literal(p.key)) as any,
  { description: '画质档位 key（来自 contracts/play-quality.json）；`original` = 不重编码' },
);

/**
 * 目标编码。比播放侧多一个 `original`：
 * 播放的「原画」是跟着会话 codec 走的直通，下载的「原画」是**换封装、不重编码**。
 */
const CodecUnion = Type.Union(
  [
    Type.Literal('original'),
    ...PLAY_CODECS.map((c) => Type.Literal(c.key)),
  ] as any,
  { description: '目标编码；original = remux（mkv，保留全部音轨与内嵌字幕）' },
);

const QualityUnion = Type.Union(
  [Type.Literal('saver'), Type.Literal('standard'), Type.Literal('high')] as any,
  { description: '画质档位：省空间 / 标准 / 高画质，只影响推荐码率' },
);

const SubtitleUnion = Type.Union(
  [Type.Literal('none'), Type.Literal('embed')] as any,
  { description: '字幕处理：none = 不带；embed = 内挂（mp4 内嵌 mov_text）' },
);

const JobStateUnion = Type.Union(
  [
    Type.Literal('queued'),
    Type.Literal('transcoding'),
    Type.Literal('ready'),
    Type.Literal('failed'),
    Type.Literal('canceled'),
  ] as any,
  { description: '任务状态；ready 之后才能下载产物' },
);

/** 目标参数（客户端弹窗里那一组选择，服务端原样回传） */
export const OfflineSpec = Type.Object(
  {
    preset: Type.String({ description: '画质档位 key' }),
    codec: Type.String({ description: '目标编码：original / h264 / h265 / av1' }),
    height: Type.Integer({ description: '目标高度（像素）；0 = 跟随片源' }),
    videoKbps: Type.Integer({ description: '目标视频码率（kbps）；0 = 不控码率' }),
    audioKbps: Type.Integer({ description: '目标音频码率（kbps）' }),
    audioIndex: Type.Integer({ description: '选第几条音轨' }),
    container: Type.String({ description: '产物封装：mp4 / mkv' }),
    subtitleMode: Type.String({ description: 'none / embed' }),
  },
  { $id: 'OfflineSpec' },
);

export const QuoteBody = Type.Object(
  {
    itemId: Type.String({ minLength: 1, description: '影视条目 id（剧集就是该集的 id）' }),
    preset: Type.Optional(PresetUnion),
    codec: Type.Optional(CodecUnion),
    /** 目标高度：只接受校验通过的档位（片源够高才允许） */
    height: Type.Optional(Type.Integer({ minimum: 0, maximum: 4320 })),
    qualityMode: Type.Optional(QualityUnion),
    /** 手填码率：给了就原样采信（只做合法区间夹取） */
    videoKbps: Type.Optional(Type.Integer({ minimum: 0, maximum: 200_000 })),
    audioIndex: Type.Optional(Type.Integer({ minimum: 0 })),
    audioBitrateKbps: Type.Optional(Type.Integer({ minimum: 32, maximum: 640 })),
    subtitleMode: Type.Optional(SubtitleUnion),
  },
  { $id: 'OfflineQuoteBody' },
);

export const QuoteResponse = Type.Object(
  {
    source: Type.Object({
      width: Type.Integer(),
      height: Type.Integer(),
      videoCodec: Type.String(),
      audioCodec: Type.String(),
      durationMs: Type.Integer(),
      bytes: Type.Integer(),
      /** 整片平均码率（size ÷ duration），库表里没有码率列 */
      bitrateKbps: Type.Integer(),
      hasSubtitle: Type.Boolean(),
    }),
    capabilities: Type.Object({
      codecs: Type.Array(Type.String(), { description: '可选输出编码（original 在最前）' }),
      heights: Type.Array(Type.Integer(), { description: '片源能支撑的档位高度（降序）' }),
      maxHeight: Type.Integer(),
    }),
    target: OfflineSpec,
    limits: Type.Object({
      minKbps: Type.Integer(),
      maxKbps: Type.Integer(),
      recommendedKbps: Type.Integer(),
    }),
    estimate: Type.Object({
      /** 预估产物字节数（视频 + 音频 + 2% 封装开销） */
      bytes: Type.Integer(),
    }),
    /** 该参数组合的产物已经存在：提交后秒完成，不用重新编码 */
    cached: Type.Boolean(),
    /** 同一 item + 同一参数已有活动任务 */
    activeJobId: Type.Optional(Type.String()),
  },
  { $id: 'OfflineQuoteResponse' },
);

export const CreateJobBody = Type.Object(
  {
    itemId: Type.String({ minLength: 1 }),
    preset: PresetUnion,
    codec: Type.Optional(CodecUnion),
    height: Type.Optional(Type.Integer({ minimum: 0, maximum: 4320 })),
    qualityMode: Type.Optional(QualityUnion),
    videoKbps: Type.Optional(Type.Integer({ minimum: 0, maximum: 200_000 })),
    audioIndex: Type.Optional(Type.Integer({ minimum: 0 })),
    audioBitrateKbps: Type.Optional(Type.Integer({ minimum: 32, maximum: 640 })),
    subtitleMode: Type.Optional(SubtitleUnion),
    /**
     * create = 首次下载；replace = 用户已确认覆盖本机旧版本。
     * 服务端两者行为一致（都不碰客户端文件），只为让任务列表能看出意图。
     */
    operation: Type.Optional(
      Type.Union([Type.Literal('create'), Type.Literal('replace')] as any, {
        description: 'create / replace',
      }),
    ),
    /** 幂等键：同键重复提交只落一条任务（客户端重连 / 双击） */
    idempotencyKey: Type.Optional(Type.String({ maxLength: 128 })),
  },
  { $id: 'OfflineCreateJobBody' },
);

export const OfflineArtifact = Type.Object(
  {
    id: Type.String(),
    size: Type.Integer(),
    sha256: Type.String({ description: '产物整文件校验值；客户端边下边算，下完比对' }),
    etag: Type.String({ description: '尺寸 + mtime，用于断点续传的 If-Range' }),
    mime: Type.String(),
    width: Type.Integer(),
    height: Type.Integer(),
    durationMs: Type.Integer(),
    videoCodec: Type.String(),
    container: Type.String({ description: 'mp4 / mkv' }),
    bitrateKbps: Type.Integer(),
  },
  { $id: 'OfflineArtifact' },
);

export const OfflineJob = Type.Object(
  {
    id: Type.String(),
    itemId: Type.String(),
    libraryId: Type.String(),
    /** 剧集聚合键（libraryId + series）；电影为空 */
    seriesKey: Type.Optional(Type.String()),
    spec: OfflineSpec,
    operation: Type.String(),
    state: JobStateUnion,
    /** 0~100；编码中来自 ffmpeg 的 out_time，不是估的 */
    progress: Type.Number(),
    error: Type.Optional(Type.String()),
    createdAt: Type.Integer(),
    updatedAt: Type.Integer(),
    artifact: Type.Optional(OfflineArtifact),
  },
  { $id: 'OfflineJob' },
);

export const ListQuery = Type.Object(
  {
    itemId: Type.Optional(Type.String({ description: '只看某个影视条目的任务（详情页按钮状态用）' })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100, default: 20 })),
  },
  { $id: 'OfflineListQuery' },
);

export const JobListResponse = Type.Object(
  { items: Type.Array(OfflineJob), total: Type.Integer() },
  { $id: 'OfflineJobList' },
);

export const OkResponse = Type.Object(
  { ok: Type.Boolean(), affected: Type.Optional(Type.Integer()) },
  { $id: 'OfflineOk' },
);
