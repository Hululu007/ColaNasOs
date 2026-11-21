import fs from 'node:fs';
import path from 'node:path';

/**
 * 崩溃自愈记账（`<dataDir>/boot.json`）。
 *
 * 这一段决定「敢不敢自动更新」：新版本切了指针但起不来时，必须能自动退回上一版，
 * 而不是让 NAS 停在「进程活着、端口不监听」的半死状态。
 *
 * 字段：
 *   id          本次启动的是哪个版本目录（D10314）
 *   attempts    连续启动尝试次数（健康后清零）
 *   firstBootAt 第一次尝试的时间
 *   healthyAt   内核上报健康的时间（null = 还没健康过）
 */
export interface BootState {
  id: string;
  attempts: number;
  firstBootAt: number;
  healthyAt: number | null;
}

/** 连续 3 次起不来就判定新版本坏 —— 与方案 §7 一致 */
export const MAX_BOOT_ATTEMPTS = 3;

export function bootPath(dataDir: string): string {
  return path.join(dataDir, 'boot.json');
}

export function readBoot(dataDir: string): BootState | null {
  try {
    const raw = JSON.parse(fs.readFileSync(bootPath(dataDir), 'utf8')) as Partial<BootState>;
    if (!raw || typeof raw.id !== 'string' || !raw.id) return null;
    return {
      id: raw.id,
      attempts: Number(raw.attempts) || 0,
      firstBootAt: Number(raw.firstBootAt) || Date.now(),
      healthyAt: raw.healthyAt === null ? null : Number(raw.healthyAt) || null,
    };
  } catch {
    return null;
  }
}

export function writeBoot(dataDir: string, state: BootState): void {
  const file = bootPath(dataDir);
  const tmp = `${file}.tmp`;
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), 'utf8');
  fs.renameSync(tmp, file);
}

export type BootAction = 'ok' | 'reset' | 'rollback' | 'retry';

/**
 * 纯函数：给出「这次启动该怎么办」。外壳只负责按结论执行。
 *
 * - `rollback` 由调用方去找上一版目录并切指针，然后把 boot.json 重置；
 * - `retry` 只把 attempts +1 后继续 fork 当前指针。
 */
export function evaluateBoot(
  previous: BootState | null,
  currentId: string | null,
): { action: BootAction; state: BootState | null } {
  if (!currentId) return { action: 'ok', state: previous };
  if (!previous) {
    return { action: 'ok', state: { id: currentId, attempts: 0, firstBootAt: Date.now(), healthyAt: null } };
  }
  // 指针变了（正常更新 / 手动切版本）：重新计数
  if (previous.id !== currentId) {
    return { action: 'reset', state: { id: currentId, attempts: 0, firstBootAt: Date.now(), healthyAt: null } };
  }
  // 上次已经健康过：正常启动，不再累计
  if (previous.healthyAt !== null) {
    return { action: 'ok', state: { ...previous, attempts: 0 } };
  }
  if (previous.attempts >= MAX_BOOT_ATTEMPTS) {
    return { action: 'rollback', state: previous };
  }
  return { action: 'retry', state: { ...previous, attempts: previous.attempts + 1 } };
}

/** 内核 listen 成功后调用：记一笔健康，之后不再累计 attempts */
export function markHealthy(dataDir: string, id: string | null): void {
  if (!id) return;
  const prev = readBoot(dataDir);
  writeBoot(dataDir, {
    id,
    attempts: 0,
    firstBootAt: prev?.id === id ? prev.firstBootAt : Date.now(),
    healthyAt: Date.now(),
  });
}
