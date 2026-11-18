import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { app } from 'electron';

/**
 * 「开机自动启动」开关。
 *
 * 两件事分开：
 *   - **状态**存在数据目录的 `config.json`（`autostart` 字段），默认不勾选。
 *     设置页 / 托盘都读这一份，重装、便携版挪目录都不会把状态弄丢。
 *   - **生效**交给系统：Windows 写 `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`
 *     （`app.setLoginItemSettings`），安装版与便携版都对当前 exe 生效。
 *
 * 便携版的 exe 路径会变，所以每次启动都按当前 `process.execPath` 重写一遍；
 * 开发态（`electron .`）不写 —— 否则会把真实安装版的启动项覆盖成 electron.exe。
 */

export function dataDir(): string {
  const base = process.env.APPDATA || path.join(os.homedir(), '.config');
  return process.env.COLANAS_DATA_DIR || path.join(base, 'colanas_os_server');
}

function configPath(): string {
  return path.join(dataDir(), 'config.json');
}

function readConfig(): Record<string, unknown> {
  try {
    return JSON.parse(fs.readFileSync(configPath(), 'utf-8')) as Record<string, unknown>;
  } catch {
    return {};
  }
}

/** 默认关闭：只有显式写入 `autostart: true` 才算开启 */
export function isAutostartEnabled(): boolean {
  return readConfig().autostart === true;
}

/**
 * 去掉「指向当前 exe 的多余启动项」，只留一条。
 *
 * Windows 的启动项是 `HKCU\...\Run` 下的一个值，值名固定为
 * `electron.app.<app.getName()>`。应用改过名字之后（服务端从 `ColaNasOs` 改成
 * `ColaNasOs 服务端`），**旧名字那条不会自己消失**：注册表里同时躺着两条指向
 * 同一个 exe 的启动项，开机被拉起两次 —— 第二次撞上单实例锁，转发给第一个进程
 * 去「打开网页」，于是每次都弹一句「服务正在启动」。
 *
 * 为什么整段交给 PowerShell 而不是 `reg query` + 文本解析：`reg query` 的输出走
 * 控制台代码页（简中 GBK），Node 按 UTF-8 解出来中文值名就是乱码，再拿乱码去
 * `reg delete` 根本找不到那一项。这里路径与值名都用环境变量传（Windows 环境块
 * 是 UTF-16，不会错码），匹配和删除都在 PowerShell 里用 .NET 注册表 API 完成，
 * 回给 Node 的只有 ASCII 的 `removed <base64>`。
 *
 * `enabled = false` 时全删：用户刚关掉开关，旧名字那条留着照样会被拉起来。
 */
const DEDUPE_PS = `
$ErrorActionPreference = 'SilentlyContinue'
$key = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
$item = Get-Item -LiteralPath $key
if (-not $item) { exit 0 }
function Norm([string]$p) {
  try { return [IO.Path]::GetFullPath($p).ToLowerInvariant() } catch { return $p.ToLowerInvariant() }
}
function ExeOf([string]$v) {
  if ($v.StartsWith('"')) {
    $i = $v.IndexOf('"', 1)
    if ($i -gt 1) { return $v.Substring(1, $i - 1) }
  }
  $i = $v.ToLowerInvariant().IndexOf('.exe')
  if ($i -lt 0) { return $null }
  return $v.Substring(0, $i + 4)
}
$target = Norm $env:COLANAS_EXE
$mine = @()
foreach ($n in $item.GetValueNames()) {
  $e = ExeOf ([string]$item.GetValue($n))
  if ($e -and (Norm $e) -eq $target) { $mine += $n }
}
if ($mine.Count -eq 0) { exit 0 }
$keep = ''
if ($env:COLANAS_ENABLED -eq '1') {
  if ($mine -contains $env:COLANAS_KEEP) { $keep = $env:COLANAS_KEEP } else { $keep = $mine[0] }
}
foreach ($n in $mine) {
  if ($n -ne $keep) {
    try {
      Remove-ItemProperty -LiteralPath $key -Name $n -Force -ErrorAction Stop
      $b = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($n))
      Write-Output ('removed ' + $b)
    } catch { }
  }
}
`;

function powershellExe(): string {
  const sysRoot = process.env.SystemRoot || 'C:\\Windows';
  const full = path.join(sysRoot, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return fs.existsSync(full) ? full : 'powershell.exe';
}

function dedupeLoginItems(enabled: boolean): void {
  if (process.platform !== 'win32') return;
  let out: string;
  try {
    out = execFileSync(powershellExe(), ['-NoProfile', '-NonInteractive', '-Command', DEDUPE_PS], {
      encoding: 'utf-8',
      windowsHide: true,
      env: {
        ...process.env,
        COLANAS_EXE: process.execPath,
        // 优先保住 Electron 刚按当前应用名写的那条；名字对不上就留第一条 ——
        // 它们启动的是同一个 exe，留哪条都能开机自启。
        COLANAS_KEEP: `electron.app.${app.getName()}`,
        COLANAS_ENABLED: enabled ? '1' : '0',
      },
    });
  } catch (err) {
    console.error('[shell] 清理重复开机启动项失败：', err);
    return;
  }
  for (const line of out.split(/\r?\n/)) {
    const m = /^removed (\S+)$/.exec(line.trim());
    if (!m) continue;
    const name = Buffer.from(m[1], 'base64').toString('utf-8');
    console.log(`[shell] 已清除重复的开机启动项：${name}`);
  }
}

function applyLoginItem(enabled: boolean): void {
  try {
    app.setLoginItemSettings({
      openAtLogin: enabled,
      path: process.execPath,
      args: [],
    });
  } catch (err) {
    console.error('[shell] setLoginItemSettings 失败：', err);
  }
  // 起一个 PowerShell 要几百毫秒，别卡在启动路径上；对账本身也不急。
  setImmediate(() => dedupeLoginItems(enabled));
}

/** 用户切换开关：先落盘，再写系统启动项 */
export function setAutostart(enabled: boolean): void {
  const cfg = readConfig();
  cfg.autostart = enabled;
  try {
    fs.mkdirSync(dataDir(), { recursive: true });
    fs.writeFileSync(configPath(), JSON.stringify(cfg, null, 2), 'utf-8');
  } catch (err) {
    console.error('[shell] 写入开机自启设置失败：', err);
  }
  if (app.isPackaged) applyLoginItem(enabled);
}

/**
 * 启动时对账：按配置把启动项同步成当前 exe 路径（便携版最需要）。
 * 返回当前是否开启，托盘菜单用它打勾。
 */
export function syncAutostart(): boolean {
  const enabled = isAutostartEnabled();
  if (app.isPackaged) applyLoginItem(enabled);
  return enabled;
}
