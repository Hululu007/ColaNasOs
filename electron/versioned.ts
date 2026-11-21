import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Updater, versionId, resolvePackageVersion } from '../kernel/updater';
import { evaluateBoot, readBoot, writeBoot } from '../kernel/update/boot';
import { seedVersionDir } from '../kernel/update/service';

/**
 * 「壳 + 版本目录」的装配逻辑（方案 §3-D1）。
 *
 * 壳只做四件事：找 `versions/current.json`、fork 内核、托盘/开窗、执行更新。
 * 业务代码全部在 `<dataDir>/versions/D<ver>/` 里 —— 这样内核和 Web 才能增量更新，
 * 而不用每次重装 551 MB 的整包。
 *
 * 首次启动（老安装包升级上来）没有 `versions/` → 从安装目录「播种」出第一版：
 * 文件取自本次安装（已被信任），不带 manifest；第一次增量更新时会用网络清单全量校验。
 */

export function dataDirOf(): string {
  if (process.env.COLANAS_DATA_DIR) return path.resolve(process.env.COLANAS_DATA_DIR);
  const base = process.env.APPDATA || path.join(os.homedir(), '.colanas');
  return path.join(base, 'colanas_os_server');
}

/**
 * 把安装包里的 `node_modules` 摊到数据目录一次。
 *
 * 拆壳后内核从 `versions/D<NNN>/kernel/` 启动，`require('fastify')` 会沿父目录找
 * `node_modules`；而依赖被压在 `resources/app.asar` 这个**单文件**里，
 * 外壳注入的 `NODE_PATH` 在 Electron 的 utilityProcess 里不生效。实测后果：
 *
 *   Error: Cannot find module 'fastify'
 *     requireStack: versions/D10317/kernel/index.js
 *
 * 摊到 `<dataDir>/node_modules` 后，解析链
 * `versions/D10317/kernel → D10317 → versions → <dataDir>` 天然命中，
 * 不依赖任何环境变量，且对之后每个新版本目录都生效。
 *
 * asar 里只有纯 JS；原生模块（.node）被 electron-builder 拆到
 * `app.asar.unpacked/node_modules`，必须合并两层。带版本戳跳过重复拷贝。
 */
export function ensureKernelModules(dataDir: string, resourcesPath: string, appVersion: string): void {
  const dest = path.join(dataDir, 'node_modules');
  const marker = path.join(dataDir, '.kernel-modules.json');
  try {
    const prev = JSON.parse(fs.readFileSync(marker, 'utf8')) as { app?: string };
    if (prev.app === appVersion && fs.existsSync(path.join(dest, 'fastify', 'package.json'))) return;
  } catch {
    /* 没有标记：照做一次 */
  }

  const asar = path.join(resourcesPath, 'app.asar');
  if (!fs.existsSync(asar)) return;

  const head = Buffer.alloc(16);
  const fd = fs.openSync(asar, 'r');
  let header: { files?: Record<string, AsarNode> };
  let base = 0;
  try {
    fs.readSync(fd, head, 0, 16, 0);
    // asar: [u32=4][u32=headerPickleSize][u32=headerSize][u32=jsonLen] + json
    const pickle = head.readUInt32LE(4);
    const jsonLen = head.readUInt32LE(12);
    const hb = Buffer.alloc(jsonLen);
    fs.readSync(fd, hb, 0, jsonLen, 16);
    header = JSON.parse(hb.toString('utf8')) as { files?: Record<string, AsarNode> };
    base = 8 + pickle;
  } finally {
    fs.closeSync(fd);
  }

  const root = header.files?.node_modules;
  if (!root?.files) return;

  fs.rmSync(dest, { recursive: true, force: true });
  fs.mkdirSync(dest, { recursive: true });

  const src = fs.openSync(asar, 'r');
  let bytes = 0;
  try {
    const emit = (rel: string, node: AsarNode): void => {
      const out = path.join(dest, rel);
      if (node.files) {
        fs.mkdirSync(out, { recursive: true });
        for (const [name, child] of Object.entries(node.files)) emit(path.join(rel, name), child);
        return;
      }
      if (node.unpacked || !node.size) {
        fs.mkdirSync(path.dirname(out), { recursive: true });
        if (!node.size) fs.writeFileSync(out, '');
        return; // 原生模块在 app.asar.unpacked 里，下面统一覆盖
      }
      const buf = Buffer.allocUnsafe(node.size);
      fs.readSync(src, buf, 0, node.size, base + Number(node.offset));
      fs.mkdirSync(path.dirname(out), { recursive: true });
      fs.writeFileSync(out, buf);
      bytes += node.size;
    };
    emit('', root);
  } finally {
    fs.closeSync(src);
  }

  // 覆盖原生模块（better-sqlite3 / node-pty / onnxruntime-node / @napi-rs）
  const unpacked = path.join(resourcesPath, 'app.asar.unpacked', 'node_modules');
  if (fs.existsSync(unpacked)) {
    const overlay = (dir: string, rel: string): void => {
      for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
        const from = path.join(dir, e.name);
        const to = path.join(dest, rel, e.name);
        if (e.isDirectory()) {
          fs.mkdirSync(to, { recursive: true });
          overlay(from, path.join(rel, e.name));
        } else {
          fs.mkdirSync(path.dirname(to), { recursive: true });
          fs.copyFileSync(from, to);
        }
      }
    };
    overlay(unpacked, '');
  }

  fs.writeFileSync(marker, JSON.stringify({ app: appVersion, at: Date.now(), bytes }), 'utf8');
  console.log(`[shell] 内核依赖已摊到 ${dest}（asar 内 ${(bytes / 1048576).toFixed(1)} MB + 原生模块）`);
}

interface AsarNode {
  size?: number;
  offset?: string;
  unpacked?: boolean;
  files?: Record<string, AsarNode>;
}

export interface SeedSources {
  kernelDir: string;
  /** `dist/src`（kernel 的模块实现都在这里），少它内核起不来 */
  srcDir: string;
  electronHost: string;
  webDir: string | null;
  contractsDir: string | null;
  sidecarsDir: string | null;
}

export function seedIfNeeded(dataDir: string, seed: SeedSources): { id: string; files: number } | null {
  const versionsDir = path.join(dataDir, 'versions');
  const pointer = path.join(versionsDir, 'current.json');
  if (fs.existsSync(pointer)) return null;
  const { semver, version } = resolvePackageVersion();
  if (!version) return null;
  const created = seedVersionDir({ versionsDir, seed, semver, version });
  if (created) {
    console.log(
      `[shell] 版本目录已播种：${created.id}（${semver}），之后内核从这里启动`,
    );
  }
  return created;
}

export interface KernelEntry {
  host: string;
  versioned: boolean;
  id: string | null;
  /** 版本目录（versioned 时有值），内核的 web/contracts/sidecars 都从它取 */
  dir: string | null;
}

/** 有可用版本目录就用它，否则退回安装目录里的内核 */
export function resolveKernelEntry(dataDir: string, localHost: string): KernelEntry {
  const up = new Updater(dataDir);
  const cur = up.current();
  if (cur) {
    const host = path.join(cur.dir, 'electron', 'kernel-host.js');
    /**
     * 三件套齐了才算「可用版本目录」：
     *   electron/kernel-host.js  入口
     *   kernel/index.js          内核本体
     *   src/modules/system       模块实现（`kernel/modules.ts` 编译后 require 它）
     * 少任何一个都退回安装目录内核 —— 宁可用旧代码，也不能让 NAS 起不来。
     */
    const complete =
      fs.existsSync(host) &&
      fs.existsSync(path.join(cur.dir, 'kernel', 'index.js')) &&
      fs.existsSync(path.join(cur.dir, 'src', 'modules', 'system', 'index.js'));
    if (complete) return { host, versioned: true, id: cur.id, dir: cur.dir };
    console.error(`[shell] 版本目录 ${cur.id} 不完整（缺 kernel/src/electron），本次用安装目录内核`);
  }
  return { host: localHost, versioned: false, id: null, dir: null };
}

export interface BootDecision {
  action: 'ok' | 'reset' | 'rollback' | 'retry' | 'local';
  id: string | null;
  message: string;
}

/**
 * 启动前自愈判定：连续 3 次起不来 → 切回上一版，并把当前坏版本目录改名留档。
 *
 * 返回 id 表示「这次应该 fork 哪个版本」（回滚后是上一版）。
 */
export function prepareBoot(dataDir: string): BootDecision {
  const up = new Updater(dataDir);
  const cur = up.current();
  const prev = readBoot(dataDir);
  const { action, state } = evaluateBoot(prev, cur?.id ?? null);

  if (action === 'rollback') {
    try {
      const rolled = up.rollback();
      writeBoot(dataDir, { id: rolled.id, attempts: 0, firstBootAt: Date.now(), healthyAt: null });
      console.error(`[shell] 新版本 ${cur?.id ?? '?'} 连续启动失败，已回滚到 ${rolled.id}`);
      return { action, id: rolled.id, message: `已回滚到 ${rolled.id}` };
    } catch (err) {
      // 没有更老的版本可退（首次拆壳后第一版就坏了）：把指针改名留档，
      // 本次退回安装目录里的内核 —— 宁可用旧代码，也不能让 NAS 起不来。
      const pointer = path.join(dataDir, 'versions', 'current.json');
      try {
        fs.renameSync(pointer, path.join(dataDir, 'versions', `current.bad-${Date.now()}.json`));
      } catch {
        /* 改不了名就继续尝试当前版本 */
      }
      console.error(`[shell] 回滚失败（${String((err as Error).message)}），本次退回安装目录内核`);
      return { action: 'local', id: null, message: '已退回安装目录内核' };
    }
  }

  if (state) writeBoot(dataDir, state);
  return {
    action,
    id: cur?.id ?? null,
    message:
      action === 'retry'
        ? `第 ${state?.attempts ?? 1} 次启动 ${cur?.id ?? ''}`
        : action === 'reset'
          ? `指针指向 ${cur?.id ?? ''}，重新计数`
          : '',
  };
}

/** 内核要能找到原生模块：版本目录里没有 node_modules，靠 NODE_PATH 指回安装目录 */
export function nativeModulePaths(packaged: boolean, repoRoot: string): string[] {
  const list: string[] = [];
  if (process.resourcesPath) list.push(path.join(process.resourcesPath, 'app.asar', 'node_modules'));
  if (!packaged) list.push(path.join(repoRoot, 'node_modules'));
  return list.filter((p) => {
    try {
      return fs.existsSync(p);
    } catch {
      return false;
    }
  });
}

/** 目标版本号（用于播种）：`package.json` 可能在被 asar 压住时读不到，由调用方兜底 */
export function expectedVersionId(): string {
  return versionId(resolvePackageVersion().version || 1);
}
