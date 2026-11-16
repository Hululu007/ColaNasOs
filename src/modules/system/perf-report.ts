import type { FastifyInstance, FastifyRequest } from 'fastify';
import fs from 'node:fs';
import path from 'node:path';
import type { KernelApi } from '../../../kernel/types';

/**
 * 客户端性能诊断上报（`设置 → 其他 → 性能诊断` 打开后每 30s 一条）。
 *
 * 为什么要落到独立文件而不是只写 kernel.log：
 *   - 一条报告含帧耗时分布、按页面的分项、每个接口的 p95/字节数、显卡与刷新率，
 *     混在 kernel.log 的文本行里没法做对比分析；
 *   - 用户只需要回传 `<数据目录>/logs/perf/client-perf-<日期>.jsonl` 一个文件。
 * 同时仍然往 kernel.log 写一行 `[perf]`，方便在设置页日志里看到「确实上报了」。
 *
 * 不计入契约（hide:true），也不生成客户端方法：客户端用原始 HTTP POST，
 * 避免为一个诊断通道改动 openapi / SDK / Dart 契约产物。
 *
 * 防刷：每进程每分钟最多 40 条、单条 256KB、每天最多 256MB。
 */
const MAX_PER_MINUTE = 40;
const MAX_BODY = 256 * 1024;
const MAX_BYTES_PER_DAY = 256 * 1024 * 1024;

export function registerPerfReport(app: FastifyInstance, k: KernelApi): void {
  const window: number[] = [];
  let dayStart = Date.now();
  let bytesToday = 0;
  let dirReady = false;

  const dir = path.join(k.paths.dataDir, 'logs', 'perf');

  app.post(
    '/api/v1/system/perf-report',
    { schema: { hide: true, tags: ['system'] } },
    async (req: FastifyRequest) => {
      const now = Date.now();
      if (now - dayStart > 86_400_000) {
        dayStart = now;
        bytesToday = 0;
      }
      while (window.length > 0 && now - window[0] > 60_000) window.shift();
      if (window.length >= MAX_PER_MINUTE) return { ok: true, dropped: true };

      const raw = req.body;
      const text = typeof raw === 'string' ? raw : JSON.stringify(raw ?? {});
      if (!text || text.length > MAX_BODY) return { ok: true, dropped: true };
      if (bytesToday + text.length > MAX_BYTES_PER_DAY) {
        return { ok: true, dropped: true };
      }

      if (!dirReady) {
        fs.mkdirSync(dir, { recursive: true });
        dirReady = true;
      }
      const day = new Date().toISOString().slice(0, 10);
      const file = path.join(dir, `client-perf-${day}.jsonl`);
      fs.appendFileSync(file, `${text}\n`, 'utf-8');

      window.push(now);
      bytesToday += text.length;

      // 只写一行摘要：具体数值都在 jsonl 里，日志页不必再铺开
      let summary = '';
      try {
        const parsed = JSON.parse(text) as {
          device?: { app?: string; platform?: string };
          window?: { fps?: number; frames?: number; totalP95?: number; rasterP95?: number };
        };
        const w = parsed.window ?? {};
        summary = `fps=${w.fps ?? '?'} frames=${w.frames ?? '?'} rasterP95=${w.rasterP95 ?? '?'}ms`;
        k.log.info(
          {
            perf: true,
            app: parsed.device?.app,
            platform: parsed.device?.platform,
            file,
          },
          `[perf] ${summary} → ${file}`,
        );
      } catch {
        k.log.warn({ perf: true, file }, '[perf] 客户端诊断报告解析失败（已落盘）');
      }

      return { ok: true, file, summary };
    },
  );

  // 方便排查：列出当前已有的诊断文件与大小（仅本机管理端读日志时用）
  app.get(
    '/api/v1/system/perf-report',
    { schema: { hide: true, tags: ['system'] } },
    async () => {
      try {
        const files = fs.existsSync(dir) ? fs.readdirSync(dir) : [];
        return {
          dir,
          files: files.map((name) => {
            const abs = path.join(dir, name);
            let size: number;
            try {
              size = fs.statSync(abs).size;
            } catch {
              size = 0;
            }
            return { name, size };
          }),
        };
      } catch {
        return { dir, files: [] };
      }
    },
  );
}
