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
