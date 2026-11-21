import fs from 'node:fs';
import path from 'node:path';
import { Updater, versionId, parseVersionId } from '../updater';
import { DownloadError, downloadAsset, fetchText, type ProgressEvent } from './downloader';
import { assembleVersion, cleanStaging, verifyTree, AssembleError } from './assemble';
import { unpackBundle } from './bundle';
import { SourceMemo } from './sources';
import { writeBoot } from './boot';
import { knownKeyIds } from './pubkey';
import {
  UpdateVerifyError,
  verifyBytes,
  verifySignedFile,
  verifyVersionManifest,
  sha256File,
  sha256,
} from './verify';
import {
  compareSemver,
  semverToVersion,
  validateManifest,
  versionToSemver,
  type AssetRef,
  type ClientAssetKind,
  type ClientComponent,
  type ComponentId,
  type DeltaRef,
  type UpdateManifest,
} from './protocol';

/**
 * 服务端增量更新编排：检查 → 下载 → 校验 → 组装 → 切指针。
 *
 * 内核发起这一切（有网、有磁盘、知道任务队列空不空），**壳只负责最后重启** ——
 * 内核没法替换自己正在跑的文件，切完指针得由外壳重新 fork。
 */

const MB = 1024 * 1024;

export interface UpdateSettings {
  /** 清单地址，顺序即优先级；默认 GitCode → GitHub → Gitee */
  manifestUrls: string[];
  channel: string;
  /** 服务端「主动轮询」开关，默认关（被动检查见 §13.2） */
  autoCheck: boolean;
}

/**
 * 清单地址：**仓库里的 `release/update.json`**（raw 直链），不是 Release 资产。
 *
 * 为什么不用 `releases/latest/download/update.json`：2026-11-21 实测
 * `gitcode.com/.../releases/latest/download/<文件>` 返回的是 **text/html 的页面**
 * （3575 字节），拿不到文件；而 `raw.gitcode.com/<owner>/<repo>/raw/main/<path>`
 * 是真正的 text/plain。raw 直链还天然稳定：地址不随 tag 变，每次发版只提交一次清单。
 *
 * 顺序即优先级：GitCode（国内快，实测 8.6 MB/s）→ GitHub（境外兜底，
 * 国内可能需要设置代理）。
 */
/** GitCode 公开仓库 contents API 根 */
const GITCODE_CONTENTS = 'https://api.gitcode.com/api/v5/repos/cocacola23/ColaNasOs/contents';
const GITCODE_REF = 'main';

export const DEFAULT_MANIFEST_URLS = [
  // GitCode 的 raw 直链**不可用**：请求会被网页预览逻辑接管，返回 403
  // 「暂不支持预览」，而且不同边缘节点行为不一致（偶尔能拿到真文件，
  // 过一会儿又 403），当更新源等于随机失效。
  //
  // 公开仓库的 contents API 反而稳定且**不需要令牌**，返回
  // `{encoding:'base64', content:'…'}`。写法是 `<API 根>@@<仓库内路径>?ref=<分支>`：
  // `@@` 左边是 API 根，右边是要取的文件，签名文件按 `<路径>.sig.json` 派生。
  `${GITCODE_CONTENTS}@@release/update.json?ref=${GITCODE_REF}`,
  'https://raw.githubusercontent.com/colaKot/ColaNasOs/main/release/update.json',
];

/** 老版本内置过的 raw 地址：读到就换掉，否则这些机器永远停在坏源上 */
const LEGACY_MANIFEST_URLS = new Set([
  'https://raw.gitcode.com/cocacola23/ColaNasOs/raw/main/release/update.json',
  'https://raw.gitcode.com/cocacola23/ColaNasOs/raw/main/release/update.json?inline=false',
]);

/**
 * 把设置里存的清单源迁移到当前可用地址。
 *
 * 老版本内置过 GitCode 的 raw 直链（现在稳定 403）。用户的 settings.json 一旦
 * 落过那个地址就会一直用它 —— 表现是「检查更新永远失败」，而程序本身升级了
 * 也不管用。这里按地址精确匹配替换，不认识的地址原样保留（用户自建源）。
 */
function migrateManifestUrls(urls: string[]): string[] {
  const out = urls.map((u) =>
    LEGACY_MANIFEST_URLS.has(u.trim()) ? DEFAULT_MANIFEST_URLS[0] : u,
  );
  return Array.from(new Set(out));
}

/**
 * 清单签名文件的地址，从清单地址派生。
 *
 * `.sig.json`（内容 `{"keyId":…,"sig":…}`）是主路径：GitCode 上 `.sig` 这类
 * 未知扩展名取不到（403）。这里只在第一个 `.json` 后面插 `.sig.json`，
 * 这样 `update.json?ref=main` 与普通直链两种写法都能正确派生。
 */
function sigSpecOf(spec: string): string {
  const i = spec.indexOf('.json');
  if (i === -1) return `${spec}.sig.json`;
  return `${spec.slice(0, i + 5)}.sig.json${spec.slice(i + 5)}`;
}

/** 老格式签名地址（纯 base64 文本）：`update.json.sig.json` → `update.json.sig` */
function legacySigSpecOf(sigSpec: string): string {
  return sigSpec.replace(/\.sig\.json(?=\?|$)/, '.sig');
}

/** 签名文本统一成 base64：新格式是 JSON，老格式是裸 base64 */
function parseSignature(raw: string): string {
  const t = raw.trim();
  if (!t) return '';
  if (t.startsWith('{')) {
    try {
      return String((JSON.parse(t) as { sig?: string }).sig || '').trim();
    } catch {
      return '';
    }
  }
  return t;
}

/**
 * 取一个仓库文本文件。
 *
 * - 普通 URL：直接 GET。
 * - `<apiRoot>@@<path>?ref=<ref>`：GitCode 公开仓库 contents API，解 base64。
 */
async function fetchRepoText(spec: string, signal?: AbortSignal): Promise<string> {
  const at = spec.indexOf('@@');
  // `@@` 两边都要归一化斜杠：少一个就是 `contentsrelease/update.json`，
  // 平台照样返回 404，而错误信息里只看到「全部更新源失败」。
  const url =
    at === -1
      ? spec
      : `${spec.slice(0, at).replace(/\/+$/, '')}/${spec.slice(at + 2).replace(/^\/+/, '')}`;
  const res = await fetchText([url], { maxBytes: 1024 * 1024, signal });
  if (at === -1) return res.text;
  let body: { encoding?: string; content?: string };
  try {
    body = JSON.parse(res.text) as { encoding?: string; content?: string };
  } catch {
    throw new DownloadError('E_MANIFEST', 'contents API 返回的不是 JSON');
  }
  if (String(body.encoding) !== 'base64' || !body.content) {
    throw new DownloadError('E_MANIFEST', 'contents API 返回格式不符（缺 content）');
  }
  return Buffer.from(body.content, 'base64').toString('utf8');
}

/**
 * 取清单签名。
 *
 * **只在「取不到」时回落到老格式 `.sig`**；取到了但验签失败必须当场报错，
 * 不能换个地址再试 —— 否则等于给攻击者留了「塞个坏签名让我回退到弱校验」的口子。
 */
async function fetchManifestSignature(spec: string, signal?: AbortSignal): Promise<string> {
  const sigSpec = sigSpecOf(spec);
  const errors: string[] = [];
  try {
    const sig = parseSignature(await fetchRepoText(sigSpec, signal));
    if (sig) return sig;
    errors.push('.sig.json 里没有 sig 字段');
  } catch (err) {
    errors.push(`.sig.json: ${(err as Error).message}`);
  }
  try {
    const sig = parseSignature(await fetchRepoText(legacySigSpecOf(sigSpec), signal));
    if (sig) return sig;
    errors.push('.sig 内容为空');
  } catch (err) {
    errors.push(`.sig: ${(err as Error).message}`);
  }
  throw new DownloadError('E_MANIFEST', `取清单签名失败（${errors.join('；')}）`);
}

export type JobPhase =
  | 'idle'
  | 'preparing'
  | 'downloading'
  | 'verifying'
  | 'assembling'
  | 'activating'
  | 'ready'
  | 'failed'
  | 'cancelled';

export interface JobStatus {
  phase: JobPhase;
  /** 0~100（未知总量时按「已下字节」显示，不给假进度） */
  percent: number;
  loaded: number;
  total: number;
  speed: number;
  /** 当前资产名，给界面显示「正在下载 web/main.dart.js」 */
  asset: string;
  source: string;
  message: string;
  error: string;
  /** 失败时能做什么：retry / full / manual */
  hint: string;
  startedAt: number;
  updatedAt: number;
  targetId: string;
  mode: 'delta' | 'full' | '';
}

export interface CurrentVersion {
  id: string | null;
  semver: string;
  version: number | null;
  dir: string | null;
  /** 版本目录是否可用（false = 还在「未拆壳」状态，只能全量更新） */
  managed: boolean;
}

export interface ServerCheck {
  component: 'server';
  hasUpdate: boolean;
  current: CurrentVersion;
  latest: {
    semver: string;
    version: number;
    notes: Record<string, string>;
    releasedAt: string;
    critical: boolean;
  } | null;
  /** delta = 只下变化文件；full = 下整包；none = 只能手动 */
  mode: 'delta' | 'full' | 'none';
  /** 增量包预计字节数（压缩后），给界面显示「约 3 MB」 */
  deltaBytes: number;
  /** 需要重装服务端（壳版本不足）时的提示 */
  needsReshell: boolean;
  /** 清单要求的最低壳版本（空串 = 没要求） */
  minShell: string;
}

export interface ClientCheck {
  component: 'client_pc' | 'client_android';
  hasUpdate: boolean;
  latest: { semver: string; version: number; versionCode: number; notes: Record<string, string> } | null;
  assets: { kind: ClientAssetKind; size: number; sha256: string; br?: { size?: number; sha256?: string }; urls: string[] }[];
}

export interface UpdateServiceOptions {
  dataDir: string;
  /** 服务端自身的 semver（外壳通过环境变量传进来） */
  currentSemver?: string;
  /** 外壳（Electron）版本，用于 minShell 判定 */
  shellVersion?: string;
  log?: (msg: string, extra?: Record<string, unknown>) => void;
  /** 切指针前给内核一次做 DB 快照的机会（SQLite VACUUM INTO） */
  beforeActivate?: (targetId: string) => Promise<void>;
}

function readJson<T>(file: string): T | null {
  try {
    return JSON.parse(fs.readFileSync(file, 'utf8')) as T;
  } catch {
    return null;
  }
}

function writeJsonAtomic(file: string, data: unknown): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = `${file}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(data, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

function dirSize(dir: string): number {
  let total = 0;
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch {
    return 0;
  }
  for (const e of entries) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) total += dirSize(abs);
    else {
      try {
        total += fs.statSync(abs).size;
      } catch {
        /* 占用中忽略 */
      }
    }
  }
  return total;
}

export class UpdateService {
  readonly dataDir: string;
  readonly versionsDir: string;
  readonly updateDir: string;
  readonly cacheDir: string;
  readonly workDir: string;
  readonly assetDir: string;
  private readonly memo: SourceMemo;
  private job: JobStatus = UpdateService.idleJob();
  /**
   * 上次拉清单失败的时间与原因。
   *
   * 离线 NAS 上每个源都要等满 8s 首字节超时（3 个源 = 24s），而「登录时检查」
   * 和设置页「检查更新」会反复触发。失败后 5 分钟内直接返回同一个错误，
   * 不再空等 —— 用户点「检查更新」时也能立刻看到「更新源不可达」。
   */
  private lastFailureAt = 0;
  private lastFailure = '';
  private static readonly FAILURE_TTL_MS = 5 * 60 * 1000;
  private busy = false;
  private abort: AbortController | null = null;
  private lastCheckedAt = 0;

  constructor(private readonly opts: UpdateServiceOptions) {
    this.dataDir = opts.dataDir;
    this.versionsDir = path.join(opts.dataDir, 'versions');
    this.updateDir = path.join(opts.dataDir, 'update');
    this.cacheDir = path.join(this.updateDir, 'cache');
    this.workDir = path.join(this.updateDir, 'work');
    this.assetDir = path.join(this.updateDir, 'assets');
    this.memo = new SourceMemo(path.join(this.updateDir, 'source-memo.json'));
  }

  private static idleJob(): JobStatus {
    return {
      phase: 'idle',
      percent: 0,
      loaded: 0,
      total: 0,
      speed: 0,
      asset: '',
      source: '',
      message: '',
      error: '',
      hint: '',
      startedAt: 0,
      updatedAt: 0,
      targetId: '',
      mode: '',
    };
  }

  // ---------------------------------------------------------------- 设置 / 现状

  settings(): UpdateSettings {
    const saved = readJson<Partial<UpdateSettings>>(path.join(this.updateDir, 'settings.json')) ?? {};
    const envUrls = (process.env.COLANAS_UPDATE_MANIFEST || '')
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    return {
      manifestUrls:
        envUrls.length > 0
          ? envUrls
          : Array.isArray(saved.manifestUrls) && saved.manifestUrls.length > 0
            ? migrateManifestUrls(saved.manifestUrls.map(String))
            : DEFAULT_MANIFEST_URLS,
      channel: String(saved.channel || 'stable'),
      autoCheck: saved.autoCheck === true,
    };
  }

  saveSettings(patch: Partial<UpdateSettings>): UpdateSettings {
    const next: UpdateSettings = { ...this.settings(), ...patch };
    next.manifestUrls = (next.manifestUrls || []).map((s) => String(s).trim()).filter(Boolean);
    writeJsonAtomic(path.join(this.updateDir, 'settings.json'), next);
    return next;
  }

  /** 当前版本：指针 + 版本目录里的 version.json（`managed` 表示已拆壳） */
  current(): CurrentVersion {
    const versions = this.versionsDir;
    const id: string | null = (() => {
      try {
        const ptr = JSON.parse(fs.readFileSync(path.join(versions, 'current.json'), 'utf8')) as { id?: string };
        return ptr?.id ? String(ptr.id) : null;
      } catch {
        return null;
      }
    })();
    const dir = id ? path.join(versions, id) : null;
    const meta = dir ? readJson<{ semver?: string; version?: number }>(path.join(dir, 'version.json')) : null;
    const version = meta?.version ?? (id ? parseVersionId(id) : null);
    const semver =
      meta?.semver ||
      this.opts.currentSemver ||
      (version ? versionToSemver(version) : '') ||
      '';
    return {
      id,
      semver,
      version,
      dir: dir && fs.existsSync(path.join(dir, 'electron', 'kernel-host.js')) ? dir : null,
      managed: Boolean(dir && fs.existsSync(path.join(dir, 'version.json'))),
    };
  }

  jobStatus(): JobStatus {
    return { ...this.job };
  }

  isBusy(): boolean {
    return this.busy;
  }

  // ---------------------------------------------------------------- 清单

  private manifestCachePath(): { json: string; sig: string } {
    return {
      json: path.join(this.cacheDir, 'update.json'),
      sig: path.join(this.cacheDir, 'update.json.sig'),
    };
  }

  /**
   * 拉清单并验签。`force=false` 且缓存 6 小时内有效时直接用缓存。
   *
   * 缓存也走验签 —— 磁盘上的文件同样可能是被改过的，一致性比省一次 IO 重要。
   */
  async loadManifest(opts: { force?: boolean; maxAgeMs?: number } = {}): Promise<UpdateManifest> {
    const { json, sig } = this.manifestCachePath();
    // 刚失败过：直接抛同一个错误（`force` 才算「我再试一次」）
    if (
      !opts.force &&
      this.lastFailureAt > 0 &&
      Date.now() - this.lastFailureAt < UpdateService.FAILURE_TTL_MS
    ) {
      throw new DownloadError('E_MANIFEST', this.lastFailure || '拉取更新清单失败');
    }
    const maxAge = opts.maxAgeMs ?? 6 * 60 * 60 * 1000;
    const fresh =
      !opts.force &&
      fs.existsSync(json) &&
      fs.existsSync(sig) &&
      Date.now() - fs.statSync(json).mtimeMs < maxAge;
    if (fresh) {
      try {
        return this.parseManifest({
          data: fs.readFileSync(json),
          sig: fs.readFileSync(sig, 'utf8'),
        });
      } catch {
        /* 缓存坏了：走网络 */
      }
    }

    const settings = this.settings();
    const urls = settings.manifestUrls;
    // 签名与清单必须来自同一个源，所以先按源成对取（而不是两个独立的 fetchText）
    const errors: string[] = [];
    for (const base of urls) {
      try {
        const raw = Buffer.from(await fetchRepoText(base), 'utf8');
        const sigText = await fetchManifestSignature(base);
        const manifest = this.parseManifest({ data: raw, sig: sigText });
        fs.mkdirSync(this.cacheDir, { recursive: true });
        fs.writeFileSync(json, raw);
        fs.writeFileSync(sig, sigText);
        this.lastCheckedAt = Date.now();
        this.lastFailureAt = 0;
        this.lastFailure = '';
        return manifest;
      } catch (err) {
        errors.push(`${base}: ${(err as Error).message}`);
        // 源不给 .sig（老源还没升级）→ 明确报出来，便于判断是缺文件还是验签失败
        if (err instanceof UpdateVerifyError) break;
      }
    }
    this.lastFailureAt = Date.now();
    this.lastFailure = `拉取更新清单失败（${errors.slice(0, 1).join('') || '无可用源'}）`;
    throw new DownloadError('E_MANIFEST', this.lastFailure, { errors });
  }

  private parseManifest(input: { data: Buffer; sig: string }): UpdateManifest {
    // keyId 在清单里，必须先解析再看用哪把公钥。
    // 解析失败或 keyId 缺失 → 视为不可信，不做「先信任再校验」。
    const keyId = (() => {
      try {
        return String((JSON.parse(input.data.toString('utf8')) as { keyId?: string }).keyId || '');
      } catch {
        throw new UpdateVerifyError('E_MANIFEST', 'update.json 不可解析');
      }
    })();
    if (!keyId) throw new UpdateVerifyError('E_MANIFEST', 'update.json 缺 keyId（拒绝未签名清单）');
    // 逐字节验签（签名覆盖文件原文，不做二次序列化）
    verifyBytes(input.data, input.sig, keyId);
    const parsed = validateManifest(JSON.parse(input.data.toString('utf8')));
    if (!parsed.ok || !parsed.manifest) {
      throw new UpdateVerifyError('E_MANIFEST', `清单结构不合法: ${parsed.errors.join('; ')}`);
    }
    return parsed.manifest;
  }

  // ---------------------------------------------------------------- 检查

  async checkServer(opts: { force?: boolean } = {}): Promise<ServerCheck> {
    const current = this.current();
    const manifest = await this.loadManifest({ force: opts.force });
    const server = manifest.components.server ?? null;
    if (!server) {
      return {
        component: 'server',
        hasUpdate: false,
        current,
        latest: null,
        mode: 'none',
        deltaBytes: 0,
        needsReshell: false,
        minShell: '',
      };
    }

    const latestVersion = server.version || semverToVersion(server.semver) || 0;
    // 清单写坏了（version 0 / semver 不合法）：当成「没有可用更新」，
    // 绝不能让它走到 versionId(0) 那条会抛异常的路径上
    if (latestVersion < 1) {
      return {
        component: 'server',
        hasUpdate: false,
        current,
        latest: null,
        mode: 'none',
        deltaBytes: 0,
        needsReshell: false,
        minShell: String(manifest.minShell || ''),
      };
    }
    const newer =
      compareSemver(server.semver, current.semver) > 0 &&
      (current.version === null || latestVersion > current.version);

    const delta = server.delta ?? null;
    const canDelta =
      newer &&
      Boolean(current.dir) &&
      Boolean(delta) &&
      Boolean(delta!.from.includes(current.semver)) &&
      Boolean(current.managed);
    const mode: ServerCheck['mode'] = !newer ? 'none' : canDelta ? 'delta' : server.full ? 'full' : 'none';

    const needsReshell = Boolean(
      manifest.minShell &&
        this.opts.shellVersion &&
        compareSemver(manifest.minShell, this.opts.shellVersion) > 0,
    );

    return {
      component: 'server',
      hasUpdate: newer,
      current,
      latest: {
        semver: server.semver,
        version: latestVersion,
        notes: manifest.notes ?? {},
        releasedAt: manifest.releasedAt,
        critical: server.critical === true,
      },
      mode: needsReshell ? 'full' : mode,
      deltaBytes: canDelta ? deltaBytes(delta!) : 0,
      needsReshell,
      minShell: String(manifest.minShell || ''),
    };
  }

  /**
   * 客户端检查（PC / 安卓）。
   *
   * `lanBase` 由路由传入（`http://192.168.x.x:7788`），服务端已缓存的资产会插到
   * URLs 最前面 —— 局域网满速，且不消耗公网流量。
   */
  async checkClient(
    component: 'client_pc' | 'client_android',
    opts: { currentSemver?: string; currentVersionCode?: number; lanBase?: string; force?: boolean },
  ): Promise<ClientCheck> {
    const manifest = await this.loadManifest({ force: opts.force });
    const c = manifest.components[component] as ClientComponent | undefined;
    if (!c) {
      return { component, hasUpdate: false, latest: null, assets: [] };
    }
    const currentSemver = String(opts.currentSemver || '');
    const newerSemver = currentSemver ? compareSemver(c.semver, currentSemver) > 0 : true;
    const newerCode =
      typeof opts.currentVersionCode === 'number' && typeof c.versionCode === 'number'
        ? c.versionCode > opts.currentVersionCode
        : true;
    const hasUpdate = component === 'client_android' ? newerCode || newerSemver : newerSemver;

    const assets = Object.entries(c.assets ?? {}).map(([kind, ref]) => ({
      kind: kind as ClientAssetKind,
      size: Number((ref as AssetRef).size) || 0,
      sha256: String((ref as AssetRef).sha256 || ''),
      br: (ref as AssetRef).br,
      urls: this.withLanUrls(kind as ClientAssetKind, ref as AssetRef, opts.lanBase),
    }));

    return {
      component,
      hasUpdate,
      latest: {
        semver: c.semver,
        version: c.version || semverToVersion(c.semver) || 0,
        versionCode: Number(c.versionCode) || 0,
        notes: manifest.notes ?? {},
      },
      assets,
    };
  }

  /** 本地已缓存的资产插到 URL 列表最前面 */
  private withLanUrls(kind: ClientAssetKind, ref: AssetRef, lanBase?: string): string[] {
    const urls = [...(ref.urls ?? [])];
    if (!lanBase) return urls;
    const file = this.cachedAssetPath(ref.sha256);
    if (!file) return urls;
    const name = path.basename(file);
    return [`${lanBase.replace(/\/+$/, '')}/api/v1/system/update/asset/${ref.sha256}/${encodeURIComponent(name)}`, ...urls];
  }

  /** 资产缓存里按 sha256 找文件（下载过一次就有） */
  cachedAssetPath(sha256Hex: string): string | null {
    if (!sha256Hex) return null;
    try {
      const hit = fs
        .readdirSync(this.assetDir)
        .find((n) => n.startsWith(`${sha256Hex.slice(0, 16)}-`));
      return hit ? path.join(this.assetDir, hit) : null;
    } catch {
      return null;
    }
  }

  // ---------------------------------------------------------------- 安装

  /**
   * 启动一次安装任务。立刻返回，进度用 `jobStatus()` 轮询。
   *
   * 只允许一个任务在跑：并发下载会互相抢带宽，还会抢同一个 staging 目录。
   */
  async install(opts: { force?: boolean } = {}): Promise<JobStatus> {
    if (this.busy) return this.jobStatus();
    this.busy = true;
    this.abort = new AbortController();
    this.job = {
      ...UpdateService.idleJob(),
      phase: 'preparing',
      message: '正在检查新版本',
      startedAt: Date.now(),
      updatedAt: Date.now(),
    };
    void this.runInstall(opts).finally(() => {
      this.busy = false;
      this.abort = null;
    });
    return this.jobStatus();
  }

  cancel(): JobStatus {
    if (this.abort) this.abort.abort();
    if (this.busy) this.setJob({ phase: 'cancelled', message: '已取消', hint: '' });
    return this.jobStatus();
  }

  private setJob(patch: Partial<JobStatus>): void {
    this.job = { ...this.job, ...patch, updatedAt: Date.now() };
  }

  private fail(err: unknown, hint = 'retry'): void {
    const message = err instanceof Error ? err.message : String(err);
    const detail =
      err instanceof DownloadError && err.detail?.errors
        ? ` (${(err.detail.errors as string[]).slice(0, 2).join('; ')})`
        : '';
    this.setJob({ phase: 'failed', message: '更新失败', error: `${message}${detail}`, hint });
    this.log('update failed', { message, hint });
  }

  private log(msg: string, extra?: Record<string, unknown>): void {
    this.opts.log?.(msg, extra);
  }

  private async runInstall(opts: { force?: boolean }): Promise<void> {
    const signal = this.abort!.signal;
    try {
      const check = await this.checkServer({ force: opts.force });
      if (!check.hasUpdate || !check.latest) {
        this.setJob({ phase: 'idle', message: '已是最新版本' });
        return;
      }
      const targetId = versionId(check.latest.version);
      this.setJob({ targetId, mode: check.mode === 'delta' ? 'delta' : 'full' });

      if (check.needsReshell) {
        this.fail(
          new Error(
            `需要重装服务端（当前外壳 ${this.opts.shellVersion || '未知'}，` +
              `该版本要求 ≥ ${check.minShell || '更新的外壳'}）`,
          ),
          'manual',
        );
        return;
      }

      /**
       * 磁盘预检。增量只落变化文件（硬链接不占空间），按「增量体积 x4 + 100 MB」算；
       * 全量要落一份完整安装包 + 解压，按 1.2 GB 算。一律按 1.1 GB 卡，会把
       * 快满的 NAS 直接挡在更新之外，而它其实只差几 MB。
       */
      const need =
        check.mode === 'delta' ? Math.max(300 * MB, check.deltaBytes * 4 + 100 * MB) : 1200 * MB;
      const free = freeSpace(this.dataDir);
      if (free > 0 && free < need) {
        this.fail(
          new Error(`磁盘空间不足（剩余 ${Math.round(free / MB)} MB，至少需要 ${Math.round(need / MB)} MB）`),
          'manual',
        );
        return;
      }

      if (check.mode === 'delta') {
        try {
          await this.installDelta(check, targetId, signal);
        } catch (err) {
          if (signal.aborted) throw err;
          /**
           * 增量失败自动降级全量（方案 §9.6）：基线被用户改过、包缺文件、
           * 摘要对不上……都只说明「这份增量用不了」，不代表不能更新。
           * 没有全量包时才把错误抛给用户。
           */
          // 这次读清单失败不能盖掉原始错误（它才是用户需要看的）
          const full = (await this.loadManifest({}).catch(() => null))?.components.server?.full;
          if (!full?.urls?.length) throw err;
          this.log('delta failed, fallback to full', { err: (err as Error).message });
          this.setJob({
            phase: 'preparing',
            percent: 0,
            loaded: 0,
            message: '增量包不可用，改用完整安装包',
            error: '',
            mode: 'full',
          });
          await this.installFull(check, signal);
        }
      } else if (check.mode === 'full') {
        await this.installFull(check, signal);
      } else {
        this.fail(new Error('这个版本没有可用的增量包，也没有全量包'), 'manual');
      }
    } catch (err) {
      if ((err as Error)?.name === 'AbortError' || (err instanceof DownloadError && err.code === 'E_ABORTED')) {
        this.setJob({ phase: 'cancelled', message: '已取消' });
        return;
      }
      this.fail(err);
    }
  }

  private async installDelta(check: ServerCheck, targetId: string, signal: AbortSignal): Promise<void> {
    const manifest = await this.loadManifest({ force: true });
    const server = manifest.components.server;
    const delta = server?.delta;
    if (!delta) throw new Error('清单里没有增量描述');

    // 1. 版本目录清单（整体签名，防「悄悄少一个文件」）
    this.setJob({ phase: 'downloading', asset: 'manifest.json', message: '正在获取版本清单' });
    const manifestFiles = await this.downloadVersionManifest(delta, signal);

    // 2. 下载变化文件 + 小文件包
    const payloadDir = path.join(this.workDir, `${targetId}-payload`);
    fs.rmSync(payloadDir, { recursive: true, force: true });
    fs.mkdirSync(payloadDir, { recursive: true });

    const totalBytes =
      delta.files.reduce((s, f) => s + (f.br?.size ?? f.size), 0) +
      delta.bundles.reduce((s, b) => s + b.size, 0);
    this.setJob({ total: totalBytes, loaded: 0, percent: 0, message: '正在下载增量包' });

    // 资产名是扁平的唯一名字（见 tool/release/release.js）：既有显式 urls 就用它，
    // 否则退回 `urlBase + 名字` 的老口径（自建 OSS 按目录摆包时仍然可用）。
    const urlsFor = (asset: { urls?: string[] }, fallbackName: string): string[] =>
      asset.urls && asset.urls.length > 0
        ? asset.urls
        : delta.urlBase.map((b) => `${b.replace(/\/+$/, '')}/${fallbackName}`);

    let doneBytes = 0;
    for (const f of delta.files) {
      if (signal.aborted) throw new DownloadError('E_ABORTED', '已取消');
      const dest = path.join(payloadDir, f.path);
      const name = f.path.split('/').pop() || 'file';
      await downloadAsset({
        urls: urlsFor(f, f.br ? `${path.basename(f.path)}.br` : path.basename(f.path)),
        dest,
        size: f.size,
        sha256: f.sha256,
        br: f.br,
        memo: this.memo,
        memoKey: f.sha256,
        signal,
        onProgress: (p) =>
          this.onDownloadProgress(p, name, doneBytes, totalBytes),
      });
      doneBytes += f.br?.size ?? f.size;
    }

    for (const b of delta.bundles) {
      if (signal.aborted) throw new DownloadError('E_ABORTED', '已取消');
      const bundlePath = path.join(payloadDir, b.name);
      await downloadAsset({
        urls: urlsFor(b, b.name),
        dest: bundlePath,
        size: b.size,
        sha256: b.sha256,
        memo: this.memo,
        memoKey: b.sha256,
        signal,
        onProgress: (p) => this.onDownloadProgress(p, b.name, doneBytes, totalBytes),
      });
      this.setJob({ phase: 'verifying', asset: b.name, message: '正在解包小文件' });
      unpackBundle(bundlePath, payloadDir);
      fs.rmSync(bundlePath, { force: true });
      doneBytes += b.size;
    }

    // 3. 组装
    this.setJob({ phase: 'assembling', message: '正在组装新版本目录' });
    cleanStaging(this.versionsDir);
    const staging = path.join(this.versionsDir, `.staging-${targetId}`);
    fs.rmSync(staging, { recursive: true, force: true });
    const baselineDir = this.current().dir;
    const assembled = assembleVersion({
      baselineDir,
      targetDir: staging,
      payloadDir,
      files: manifestFiles.files,
      manifestText: manifestFiles.text,
      manifestSig: manifestFiles.sig,
      onProgress: (d, t) => this.setJob({ percent: Math.round((d / Math.max(1, t)) * 100), message: `正在组装 ${d}/${t}` }),
    });

    // 4. 全量校验 + 收尾
    this.setJob({ phase: 'verifying', message: '正在校验新版本文件' });
    const verify = verifyTree(staging, manifestFiles.files);
    if (!verify.ok) throw new AssembleError('E_VERIFY', `新版本校验失败: ${verify.errors.slice(0, 3).join('; ')}`);

    this.writeVersionMeta(staging, server!.semver, manifestFiles.version);
    await this.promote(staging, targetId);
    this.log('delta install done', { targetId, ...assembled, verified: verify.ok });
    fs.rmSync(payloadDir, { recursive: true, force: true });
  }

  private onDownloadProgress(p: ProgressEvent, asset: string, baseBytes: number, totalBytes: number): void {
    const loaded = baseBytes + p.loaded;
    this.setJob({
      phase: 'downloading',
      asset,
      source: p.source,
      loaded,
      total: totalBytes || p.total,
      percent: totalBytes > 0 ? Math.min(99, Math.round((loaded / totalBytes) * 100)) : 0,
      speed: p.speed,
      message: `正在下载 ${asset}`,
    });
  }

  private async downloadVersionManifest(
    delta: DeltaRef,
    signal: AbortSignal,
  ): Promise<{ text: Buffer; sig: string; files: Record<string, string>; version: number }> {
    const m = delta.manifest;
    const urls = m.urls.length > 0 ? m.urls : delta.urlBase.map((b) => `${b.replace(/\/+$/, '')}/manifest.json`);
    const jsonRes = await fetchText(urls, { signal, memo: this.memo, memoKey: m.sha256 });
    const text = Buffer.from(jsonRes.text, 'utf8');
    if (m.sha256 && sha256(text) !== m.sha256) throw new Error('版本清单摘要不符');
    // 签名同样走 `.sig.json`：`.sig` 在 GitCode raw 上取不到（见 fetchManifestSignature）。
    // 多镜像里只要有一个能给出签名就用它 —— 签名内容对所有镜像都一样。
    const sigRes = await fetchManifestSignature(urls[0], signal);
    const sig = sigRes.trim();
    // keyId 从 update.json 拿不到（manifest 里没带），按「当前所有已内置公钥」逐个试
    let lastErr: unknown = null;
    for (const keyId of knownKeyIds()) {
      try {
        const parsed = verifyVersionManifest(text, sig, keyId);
        return { text, sig, files: parsed.files, version: parsed.version };
      } catch (err) {
        lastErr = err;
      }
    }
    throw new UpdateVerifyError('E_SIGNATURE', `版本清单验签失败: ${(lastErr as Error)?.message ?? ''}`);
  }

  /** 全量兜底：下载安装包，交给外壳/用户执行 */
  private async installFull(check: ServerCheck, signal: AbortSignal): Promise<void> {
    const manifest = await this.loadManifest({ force: true });
    const full = manifest.components.server?.full;
    if (!full) throw new Error('清单里没有全量包');
    const name = (full.urls[0] || '').split('/').pop() || 'ColaNasOs-Server-Setup.exe';
    const dest = path.join(this.cacheDir, name);
    this.setJob({ phase: 'downloading', total: full.br?.size ?? full.size, asset: name, message: '正在下载完整安装包' });
    await downloadAsset({
      urls: full.urls,
      dest,
      size: full.size,
      sha256: full.sha256,
      br: full.br,
      memo: this.memo,
      memoKey: full.sha256,
      signal,
      onProgress: (p) => this.onDownloadProgress(p, name, 0, full.br?.size ?? full.size),
    });
    // 全量走安装器：它自己会关掉旧进程（installer.nsh 的 STOP_RUNNING_APP）
    this.setJob({
      phase: 'ready',
      percent: 100,
      message: '安装包已就绪',
      hint: dest,
      mode: 'full',
    });
  }

  /**
   * 写 version.json（内核 / 客户端判断新旧都用它）。
   *
   * 已经存在就**不覆盖**：发布产物的 version.json 是清单里的一员，
   * 重新写一遍（字段顺序/内容不同）会让「切指针前的全量校验」对不上。
   */
  private writeVersionMeta(dir: string, semver: string, version: number): void {
    if (fs.existsSync(path.join(dir, 'version.json'))) return;
    writeJsonAtomic(path.join(dir, 'version.json'), {
      semver,
      version,
      buildNumber: version % 100,
      versionCode: version,
    });
  }

  /** staging → 正式目录 → 切指针 → 写 boot.json */
  private async promote(staging: string, targetId: string): Promise<void> {
    const dest = path.join(this.versionsDir, targetId);
    if (fs.existsSync(dest)) fs.rmSync(dest, { recursive: true, force: true });
    fs.renameSync(staging, dest);

    this.setJob({ phase: 'activating', message: '正在切换版本' });
    await this.opts.beforeActivate?.(targetId);

    const versions = new Updater(this.dataDir);
    versions.activate(parseVersionId(targetId) ?? 0, { forceDowngrade: true });
    writeBoot(this.dataDir, { id: targetId, attempts: 0, firstBootAt: Date.now(), healthyAt: null });
    // 只保留当前与上一版：回滚够用，磁盘不会越滚越大（一个版本约 60 MB）
    const pruned = pruneVersions(this.versionsDir, 2);
    if (pruned.length) this.log('pruned versions', { pruned });
    this.setJob({ phase: 'ready', percent: 100, message: '更新完成，重启后生效' });
  }

  // ---------------------------------------------------------------- 回滚 / 离线

  /** 回滚到上一版（允许降级）；返回目标版本 id */
  rollback(): { id: string } {
    const up = new Updater(this.dataDir);
    const entry = up.rollback();
    writeBoot(this.dataDir, { id: entry.id, attempts: 0, firstBootAt: Date.now(), healthyAt: null });
    this.setJob({ phase: 'ready', message: `已回滚到 ${entry.id}`, hint: 'restart' });
    this.log('rolled back', { id: entry.id });
    return { id: entry.id };
  }

  /**
   * 离线包导入（`<dataDir>/update/inbox/<名字>/`）。
   *
   * 断网 NAS 的场景：把整个目录从 U 盘拷进 `inbox`，然后在设置页点导入。
   * 目录结构就是**一个完整的版本目录** + 它自己的签名清单：
   *
   *   colanas-offline-1.3.14/
   *     update.json  update.json.sig      ← 证明「这是官方发的这一版」
   *     files/manifest.json .sig          ← 逐文件摘要 + 整体签名
   *     files/kernel/... web/...
   *
   * 之所以用目录而不是 zip：解 zip 要引依赖，而「拷文件夹」对用户来说一样简单，
   * 而且导入走的校验、组装、切指针与在线路径**完全相同**。
   */
  async importOffline(name: string): Promise<{ targetId: string; files: number }> {
    if (this.busy) throw new Error('有更新任务正在进行');
    const dir = path.join(this.updateDir, 'inbox', path.basename(name));
    const updatePath = path.join(dir, 'update.json');
    const sigPath = `${updatePath}.sig`;
    if (!fs.existsSync(updatePath) || !fs.existsSync(sigPath)) {
      throw new Error(`离线包不完整（缺 update.json / .sig）：${path.basename(name)}`);
    }
    // 与在线路径同一套验签
    const manifest = this.parseManifest({
      data: fs.readFileSync(updatePath),
      sig: fs.readFileSync(sigPath, 'utf8'),
    });
    const server = manifest.components.server;
    if (!server) throw new Error('离线包里没有服务端组件');

    const filesDir = path.join(dir, 'files');
    const mfPath = path.join(filesDir, 'manifest.json');
    const mfSigPath = `${mfPath}.sig`;
    if (!fs.existsSync(mfPath) || !fs.existsSync(mfSigPath)) {
      throw new Error('离线包里缺 files/manifest.json 或其签名');
    }
    const mfText = fs.readFileSync(mfPath);
    const mfSig = fs.readFileSync(mfSigPath, 'utf8').trim();
    let parsed: { version: number; files: Record<string, string> } | null = null;
    let lastErr: unknown = null;
    for (const keyId of knownKeyIds()) {
      try {
        parsed = verifyVersionManifest(mfText, mfSig, keyId);
        break;
      } catch (err) {
        lastErr = err;
      }
    }
    if (!parsed) throw new Error(`离线包清单验签失败: ${(lastErr as Error)?.message ?? ''}`);
    if (parsed.version !== server.version) {
      throw new Error(`离线包版本不一致：update.json=${server.version} manifest=${parsed.version}`);
    }

    const targetId = versionId(server.version);
    const staging = path.join(this.versionsDir, `.staging-${targetId}`);
    fs.rmSync(staging, { recursive: true, force: true });
    const assembled = assembleVersion({
      // 离线包是完整目录，不需要基线
      baselineDir: null,
      targetDir: staging,
      payloadDir: filesDir,
      files: parsed.files,
      manifestText: mfText,
      manifestSig: mfSig,
    });
    const verify = verifyTree(staging, parsed.files);
    if (!verify.ok) {
      fs.rmSync(staging, { recursive: true, force: true });
      throw new Error(`离线包校验失败: ${verify.errors.slice(0, 3).join('; ')}`);
    }
    this.writeVersionMeta(staging, server.semver, server.version);
    const dest = path.join(this.versionsDir, targetId);
    fs.rmSync(dest, { recursive: true, force: true });
    fs.renameSync(staging, dest);
    await this.opts.beforeActivate?.(targetId);
    const up = new Updater(this.dataDir);
    up.activate(server.version, { forceDowngrade: true });
    writeBoot(this.dataDir, { id: targetId, attempts: 0, firstBootAt: Date.now(), healthyAt: null });
    return { targetId, files: assembled.files };
  }

  /** 扫描 inbox，列出可导入的离线包（目录形态） */
  listOffline(): { name: string; size: number; mtime: number }[] {
    const inbox = path.join(this.updateDir, 'inbox');
    try {
      return fs
        .readdirSync(inbox, { withFileTypes: true })
        .filter((e) => e.isDirectory() && fs.existsSync(path.join(inbox, e.name, 'update.json')))
        .map((e) => {
          const abs = path.join(inbox, e.name);
          return { name: e.name, size: dirSize(abs), mtime: fs.statSync(abs).mtimeMs };
        });
    } catch {
      return [];
    }
  }

  /** 缓存占用（设置页「清理」用） */
  cacheUsage(): { bytes: number; files: number } {
    const bytes = dirSize(this.cacheDir) + dirSize(this.assetDir);
    const files = countFiles(this.cacheDir) + countFiles(this.assetDir);
    return { bytes, files };
  }

  clearCache(): { bytes: number; files: number } {
    const before = this.cacheUsage();
    fs.rmSync(this.cacheDir, { recursive: true, force: true });
    fs.rmSync(this.assetDir, { recursive: true, force: true });
    return before;
  }

  /**
   * 把客户端资产下载到本地缓存（客户端来要时走局域网满速）。
   * 失败不算错：公网 URL 仍然可用，只是慢一点。
   */
  async cacheClientAsset(ref: AssetRef): Promise<string | null> {
    const existing = this.cachedAssetPath(ref.sha256);
    if (existing) return existing;
    const name = (ref.urls[0] || '').split('/').pop() || `asset-${ref.sha256.slice(0, 8)}`;
    const dest = path.join(this.assetDir, `${ref.sha256.slice(0, 16)}-${name}`);
    try {
      await downloadAsset({
        urls: ref.urls,
        dest,
        size: ref.size,
        sha256: ref.sha256,
        br: ref.br,
        memo: this.memo,
        memoKey: ref.sha256,
      });
      return dest;
    } catch (err) {
      this.log('asset cache failed', { name, err: (err as Error).message });
      return null;
    }
  }

  /**
   * 预取客户端安装包到本机缓存。
   *
   * 目的：客户端下次来问时，`urls` 的第一条就是局域网地址 —— 内网满速、
   * 不消耗公网流量。失败完全无害（公网 URL 仍然可用），所以静默吞掉错误。
   */
  private readonly prefetching = new Set<string>();

  async prefetchClientAsset(component: 'client_pc' | 'client_android'): Promise<void> {
    try {
      const m = await this.loadManifest({});
      const c = m.components[component];
      if (!c) return;
      const refs = Object.values(c.assets ?? {});
      for (const ref of refs.slice(0, 1)) {
        if (!ref || !ref.urls?.length) continue;
        if (this.cachedAssetPath(ref.sha256)) continue;
        // 同一份资产并发预取会各下一遍（多端同时登录很常见）
        if (this.prefetching.has(ref.sha256)) continue;
        this.prefetching.add(ref.sha256);
        try {
          await this.cacheClientAsset(ref);
        } finally {
          this.prefetching.delete(ref.sha256);
        }
      }
    } catch {
      /* 预取失败不影响任何功能 */
    }
  }

}

function deltaBytes(delta: DeltaRef): number {
  const files = delta.files.reduce((s, f) => s + (f.br?.size ?? f.size), 0);
  const bundles = delta.bundles.reduce((s, b) => s + b.size, 0);
  return files + bundles;
}

function countFiles(dir: string): number {
  let n = 0;
  try {
    for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
      if (e.isDirectory()) n += countFiles(path.join(dir, e.name));
      else n += 1;
    }
  } catch {
    return n;
  }
  return n;
}

/** 递归列目录内文件（POSIX 分隔符，与清单口径一致） */
function listRelFiles(dir: string, rel = ''): string[] {
  const out: string[] = [];
  let entries: fs.Dirent[];
  try {
    entries = fs.readdirSync(path.join(dir, rel), { withFileTypes: true });
  } catch {
    return out;
  }
  for (const e of entries) {
    const child = rel ? `${rel}/${e.name}` : e.name;
    if (e.isDirectory()) out.push(...listRelFiles(dir, child));
    else if (e.isFile()) out.push(child);
  }
  return out;
}
/** 数据目录所在卷剩余空间（拿不到返 0，不做拦截） */
export function freeSpace(dir: string): number {
  try {
    const st = fs.statfsSync(dir);
    return Number(st.bavail) * Number(st.bsize);
  } catch {
    return 0;
  }
}

/**
 * 首次启动的「拆壳播种」：把安装目录里的内核/Web 落成一个版本目录。
 *
 * 没有这一步，已装的老版本永远只会走全量 —— 因为它们根本没有 `versions/`。
 * 播种出来的目录不带 manifest（文件来自本次安装，已被信任），第一次增量更新时
 * 会用**网络清单**做全量校验，该有的保证一点不少。
 */
export function seedVersionDir(opts: {
  versionsDir: string;
  seed: {
    kernelDir: string;
    /**
     * **必须**有：`kernel/modules.ts` 编译后是 `require("../src/modules/…")`，
     * 少这一份，版本目录里的内核一启动就 MODULE_NOT_FOUND。
     */
    srcDir: string;
    electronHost: string;
    webDir: string | null;
    contractsDir: string | null;
    sidecarsDir: string | null;
  };
  semver: string;
  version: number;
}): { id: string; files: number } | null {
  const id = versionId(opts.version);
  const dest = path.join(opts.versionsDir, id);
  if (fs.existsSync(path.join(dest, 'version.json'))) return null;

  fs.mkdirSync(dest, { recursive: true });
  let files = 0;
  /**
   * 逐文件复制（不用 `fs.cpSync`）：播种的源在打包态位于 `app.asar` 内，
   * 走 Node 的 `readFileSync` / `writeFileSync` 才能被 Electron 的 asar 补丁接管。
   */
  const copyDir = (src: string | null, rel: string): void => {
    if (!src || !fs.existsSync(src)) return;
    const walk = (from: string, to: string): void => {
      fs.mkdirSync(to, { recursive: true });
      for (const e of fs.readdirSync(from, { withFileTypes: true })) {
        const a = path.join(from, e.name);
        const b = path.join(to, e.name);
        if (e.isDirectory()) walk(a, b);
        else if (e.isFile()) {
          fs.writeFileSync(b, fs.readFileSync(a));
          files += 1;
        }
      }
    };
    walk(src, path.join(dest, rel));
  };

  copyDir(opts.seed.kernelDir, 'kernel');
  copyDir(opts.seed.srcDir, 'src');
  copyDir(opts.seed.webDir, 'web');
  copyDir(opts.seed.contractsDir, 'contracts');
  copyDir(opts.seed.sidecarsDir, 'sidecars');
  fs.mkdirSync(path.join(dest, 'electron'), { recursive: true });
  if (fs.existsSync(opts.seed.electronHost)) {
    fs.copyFileSync(opts.seed.electronHost, path.join(dest, 'electron', 'kernel-host.js'));
    files += 1;
  }
  writeJsonAtomic(path.join(dest, 'version.json'), {
    semver: opts.semver,
    version: opts.version,
    buildNumber: opts.version % 100,
    versionCode: opts.version,
  });
  // 指针只在不存时才写：已有 current.json 说明是升级后的正常启动
  const ptr = path.join(opts.versionsDir, 'current.json');
  if (!fs.existsSync(ptr)) writeJsonAtomic(ptr, { id, at: Date.now() });
  return { id, files };
}

/** 彻底移除一个版本目录（保留当前与上一版，其余按需清理） */
export function pruneVersions(versionsDir: string, keep = 2): string[] {
  const up = new Updater(path.dirname(versionsDir));
  const all = up.list();
  const cur = up.current();
  const removed: string[] = [];
  const keepIds = new Set<string>();
  if (cur) keepIds.add(cur.id);
  // 保留版本号最大的 keep 个（回滚只需要上一版）
  for (const v of [...all].reverse()) {
    if (keepIds.size >= keep && cur && !keepIds.has(v.id)) break;
    keepIds.add(v.id);
  }
  for (const v of all) {
    if (keepIds.has(v.id)) continue;
    try {
      fs.rmSync(v.dir, { recursive: true, force: true });
      removed.push(v.id);
    } catch {
      /* 占用中：下次再清 */
    }
  }
  return removed;
}

export { DownloadError } from './downloader';
export { UpdateVerifyError } from './verify';
export type { AssetRef, ComponentId, UpdateManifest };
