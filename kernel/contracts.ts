import fs from 'node:fs';
import path from 'node:path';

/**
 * 契约文件定位（安装包形态修复，SP4-03）。
 *
 * 开发态契约在仓库根 `contracts/`；安装包里它在 `resources/contracts/`。
 * 只认 `process.cwd()/contracts` 不行 —— 打包后 cwd 是 exe 所在目录，
 * 内核启动即 `ENOENT`（安装包完全起不来，只有跑过运行冒烟才能发现）。
 *
 * 查找顺序：
 *   1. `COLANAS_CONTRACTS_DIR`（外壳在打包态注入 `resources/contracts` 或版本目录的 `contracts/`）
 *   2. `<cwd>/contracts`（开发态：仓库根启动）
 *   3. `<__dirname>/../../contracts`（dist/kernel → 仓库根，兜底）
 *   4. `<__dirname>/../contracts`（版本目录：`versions/D<NNN>/kernel` → `versions/D<NNN>/contracts`）
 *
 * 第 4 条是为版本目录补的兜底：拆壳后内核住在 `versions/D<NNN>/kernel/`，
 * 契约在同级 `contracts/`。外壳正常会注入环境变量，但注入缺失时（老外壳、
 * 手工起内核、冒烟脚本）第 3 条只会算到 `versions/contracts`，直接 fatal。
 */
export function resolveContractFile(name: string): string {
  const candidates = [
    process.env.COLANAS_CONTRACTS_DIR,
    path.join(process.cwd(), 'contracts'),
    path.resolve(__dirname, '..', '..', 'contracts'),
    path.resolve(__dirname, '..', 'contracts'),
  ].filter((p): p is string => Boolean(p));

  for (const dir of candidates) {
    const file = path.join(dir, name);
    if (fs.existsSync(file)) return file;
  }

  throw new Error(
    `契约文件 ${name} 不存在（已查找：${candidates.join(' | ')}）；` +
      '安装包请确认 resources/contracts 随包分发，或用 COLANAS_CONTRACTS_DIR 指定目录',
  );
}