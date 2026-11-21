import { app, Menu, Tray, dialog, nativeImage, shell, utilityProcess } from 'electron';
import path from 'node:path';
import fs from 'node:fs';
import { WatchdogSupervisor } from '../kernel/watchdog-supervisor';
import type { WatchdogMetrics } from '../kernel/watchdog';
import { isAutostartEnabled, setAutostart, syncAutostart } from './autostart';
import {
  dataDirOf,
  ensureKernelModules,
  nativeModulePaths,
  prepareBoot,
  resolveKernelEntry,
  seedIfNeeded,
  shellLog,
} from './versioned';

/**
 * 「服务端」外壳：**纯托盘 + 内核守护**，不创建任何窗口。
 *
 * 设计取舍（2026-11-10 按用户要求收敛）：
 *   服务端只需要三件事 —— 右下角托盘图标、右键菜单（打开 Web 页面 / 开机自动启动 / 退出）、
 *   以及把内核跑起来并看住它。界面一律用系统浏览器打开 `http://127.0.0.1:<port>`，
 *   不再内嵌 BrowserWindow：省一份 Chromium 渲染进程，也避免「托盘点开是个窗口、
 *   浏览器里又是另一个会话」的两套 UI 问题。
 *
 * 保留的关键能力：
 *   - 单实例锁（第二次启动只打开 Web 页面）
 *   - 内核崩溃自动重启（最多 5 次）+ 进程外看门狗（心跳超时 / CPU 打满）
 *   - 退出前让内核优雅收尾：停种子（发 tracker 的 stopped）→ 停内置 transmission
 */

const PORT = Number(process.env.PORT || 7788);
/** 数据目录：与内核同一口径（`COLORNAS_DATA_DIR` 优先，否则 %APPDATA%\colanas_os_server） */
const dataDir = dataDirOf();
/** 实际监听端口：内核按 config 的 httpPort 监听后通过 `listening` 消息回传 */
let kernelPort = PORT;
const kernelUrl = (): string => `http://127.0.0.1:${kernelPort}`;
const MAX_RESTARTS = 5;

/**
 * 启动阶段日志：Windows GUI 形态下 stdout/stderr 会被丢弃（打包后排查首启失败
 * 只能看到"进程没了"）。设置 `COLANAS_LAUNCH_LOG=<文件>` 即可把关键阶段落盘。
 */
const LAUNCH_LOG = process.env.COLANAS_LAUNCH_LOG;
function trace(stage: string): void {
  if (!LAUNCH_LOG) return;
  try {
    fs.appendFileSync(LAUNCH_LOG, `${new Date().toISOString()} ${stage}\n`);
  } catch {
    /* 日志不可写不影响启动 */
  }
}
trace(`boot pid=${process.pid} packaged=${app.isPackaged}`);

/** 进程外看门狗：内核 5 分钟无心跳（或 always 模式下 CPU 持续打满）即杀进程重启 */
const guard = new WatchdogSupervisor();
let watchdogTimer: NodeJS.Timeout | null = null;
let watchdogGaveUp = false;

let kernel: Electron.UtilityProcess | null = null;
/**
 * 是否启用「版本目录内核 / 播种 / 自愈」。
 *
 * 提成模块级变量：崩溃重启与看门狗重启都要走同一套自愈判定，
 * 而它们是在 `whenReady` 之后才发生的。
 */
let versionedKernel = false;
let tray: Tray | null = null;
let quitting = false;
let crashes = 0;
/** 内核是否已经回传监听端口：没就绪时点「打开 Web 页面」只提示，不打开空白页 */
let kernelReady = false;
/**
 * 「等内核就绪再打开网页」的请求标记。
 *
 * 开机自启、托盘单击、手动双击 exe（撞单实例锁后转发过来）都会在内核还没
 * listen 时就要求打开页面；以前这里直接弹「服务正在启动」，用户每次开机都
 * 得关一个弹窗。现在先记账，内核回传端口后自动打开。
 */
let pendingOpen = false;
let pendingOpenTimer: NodeJS.Timeout | null = null;
/** 内核启动的兜底观察窗口：起不来才提示，不然用户会以为点了没反应 */
const OPEN_DEFER_MS = 20_000;

/**
 * 版本号（`package.json#version`，由 `tool/version.js` 同步）。
 *
 * 托盘菜单第一行和悬停提示都要用：用户报问题时第一句就是「你装的哪个版本」，
 * 以前只能去安装目录看文件名或者翻设置页。
 * 写成函数而不是模块级常量：`app.getVersion()` 在 `whenReady` 之前不保证拿到
 * 应用版本（可能回落到 Electron 自身的版本），托盘/菜单都是 ready 之后才建的。
 */
function appVer(): string {
  return `v${app.getVersion()}`;
}

/** 托盘悬停提示统一带上版本号，省得用户来回找 */
function trayTip(status: string): string {
  return `ColaNasOs 服务端 ${appVer()} — ${status}`;
}

// userData 固定成历史路径：产品名从 `ColaNasOs` 改成 `ColaNasOs 服务端` 后，
// Electron 默认会跟着换目录 —— 数据（SQLite）在 APPDATA\colanas_os_server 不受影响，
// 但单实例锁与 Chromium 缓存按 userData 区分，换了就会和已装的旧实例同时跑。
const baseUserData = path.join(app.getPath('appData'), 'colanas_os_server');
try {
  fs.mkdirSync(baseUserData, { recursive: true });
  app.setPath('userData', baseUserData);
} catch (err) {
  trace(`userData pin failed: ${String(err)}`);
}

// 开发实例与日常实例隔离：锁绑定在 userData 路径上，开发实例用独立 userData，
// 两个实例可以同时在线（不再「必须关掉日常实例才能调试」）。
if (process.env.COLANAS_DEV_INSTANCE === '1') {
  app.setPath('userData', path.join(app.getPath('userData'), 'dev-instance'));
  trace(`userData(dev)=${app.getPath('userData')}`);
}

// 显式覆盖 userData（安装包冒烟 / 运维多实例隔离）：必须在单实例锁之前设置，
// 否则两个进程会抢同一把锁。注意 Electron 不接受 `--user-data-dir` 启动参数；
// `app.setPath` 要求目录存在，这里先建。
const userDataOverride = process.env.COLANAS_USER_DATA_DIR;
if (userDataOverride) {
  const dir = path.resolve(userDataOverride);
  fs.mkdirSync(dir, { recursive: true });
  app.setPath('userData', dir);
  trace(`userData=${dir}`);
}

// 单实例：第二次启动直接把 Web 页面打开（没有窗口可聚焦）
const locked = app.requestSingleInstanceLock();
trace(`singleInstance=${locked}`);
if (!locked) {
  app.quit();
} else {
  app.on('second-instance', () => openWeb());
}

function resourcesDir(): string {
  return app.isPackaged ? process.resourcesPath : path.join(__dirname, '..', '..', 'resources');
}

/** 播种来源：安装目录里的内核 / Web / 契约 / sidecar */
function seedSources(): Parameters<typeof seedIfNeeded>[1] {
  const root = path.join(__dirname, '..', '..');
  return {
    kernelDir: path.join(__dirname, '..', 'kernel'),
    srcDir: path.join(__dirname, '..', 'src'),
    electronHost: path.join(__dirname, 'kernel-host.js'),
    webDir: app.isPackaged
      ? path.join(process.resourcesPath, 'web')
      : path.join(root, 'apps', 'colanas_os', 'build', 'web'),
    contractsDir: app.isPackaged
      ? path.join(process.resourcesPath, 'contracts')
      : path.join(root, 'contracts'),
    sidecarsDir: app.isPackaged
      ? path.join(process.resourcesPath, 'sidecars')
      : path.join(root, 'sidecars'),
  };
}

function startKernel(): void {
  if (quitting) return;
  trace('startKernel');

  // 安装包形态：Flutter Web 产物在 `resources/web`（见 electron-builder.js），
  // 契约在 `resources/contracts`，不能沿用仓库内的相对路径。
  const env: NodeJS.ProcessEnv = { ...process.env };
  // 未显式指定 PORT（运维 / 冒烟）时让内核读取 config 的 httpPort；
  // 显式 PORT 仍然优先，避免破坏测试对固定端口的依赖。
  if (!process.env.PORT) delete env.PORT;

  /**
   * 内核从哪跑：
   *   - 有 `versions/current` → 从版本目录跑（增量更新的前提，见 ADR-0006）；
   *   - 否则退回安装目录里的内核（老安装 / 开发态）。
   * 版本目录里的 web / contracts / sidecars 也一并指过去：一次更新只换版本目录，
   * 安装目录里只剩壳、模型、ffmpeg 这些「不该被更新流程碰」的资产。
   */
  const entry = resolveKernelEntry(dataDir, path.join(__dirname, 'kernel-host.js'));

  if (app.isPackaged) {
    // 安装包形态：模型 / ffmpeg / 地名库等不参与版本，永远从 resources 取
    const geoDir = path.join(process.resourcesPath, 'geo');
    env.COLANAS_GEONAMES = path.join(geoDir, 'geonames.sqlite');
    env.COLANAS_CHINA_DIVISIONS = path.join(geoDir, 'china-divisions.json');
    env.COLANAS_TRANSMISSION_BIN_DIR = path.join(process.resourcesPath, 'transmission-daemon');
    env.COLANAS_TRANSMISSION_WEB_DIR = path.join(process.resourcesPath, 'transmission-web');
    const modelsDir = path.join(process.resourcesPath, 'models');
    if (fs.existsSync(modelsDir)) env.COLANAS_MODEL_DIR = modelsDir;
    const ffmpegExe = path.join(
      process.resourcesPath,
      'ffmpeg',
      process.platform === 'win32' ? 'ffmpeg.exe' : 'ffmpeg',
    );
    if (fs.existsSync(ffmpegExe)) env.COLANAS_FFMPEG = ffmpegExe;
    if (!entry.versioned) {
      env.COLANAS_WEB_DIR = path.join(process.resourcesPath, 'web');
      env.COLANAS_CONTRACTS_DIR = path.join(process.resourcesPath, 'contracts');
      const mediaSidecar = path.join(process.resourcesPath, 'sidecars', 'media', 'main.js');
      if (fs.existsSync(mediaSidecar)) env.COLANAS_MEDIA_SIDECAR = mediaSidecar;
    }
  }

  if (entry.versioned && entry.dir) {
    const web = path.join(entry.dir, 'web');
    if (fs.existsSync(path.join(web, 'index.html'))) env.COLANAS_WEB_DIR = web;
    const contracts = path.join(entry.dir, 'contracts');
    if (fs.existsSync(contracts)) env.COLANAS_CONTRACTS_DIR = contracts;
    // 缩略图 / 转码 sidecar 也在版本目录里：它随内核一起更新
    const mediaSidecar = path.join(entry.dir, 'sidecars', 'media', 'main.js');
    if (fs.existsSync(mediaSidecar)) env.COLANAS_MEDIA_SIDECAR = mediaSidecar;
    else if (app.isPackaged) {
      const packagedSidecar = path.join(process.resourcesPath, 'sidecars', 'media', 'main.js');
      if (fs.existsSync(packagedSidecar)) env.COLANAS_MEDIA_SIDECAR = packagedSidecar;
    }
  }

  // 版本目录里没有 node_modules：原生模块（better-sqlite3 / node-pty …）
  // 按 Electron ABI 编译，住在安装目录里，靠 NODE_PATH 指回去。
  const nodePaths = nativeModulePaths(app.isPackaged, path.join(__dirname, '..', '..'));
  if (nodePaths.length > 0) {
    env.NODE_PATH = [env.NODE_PATH, ...nodePaths].filter(Boolean).join(path.delimiter);
  }
  /**
   * 两个版本号别混：
   *   COLANAS_SHELL_VERSION = **外壳**的产品版本（`app.getVersion()`），
   *     清单里的 `minShell` 就是跟它比 —— 跟 Electron 版本比毫无意义；
   *   COLANAS_APP_VERSION   = **正在跑的内核**版本：拆壳后用版本目录的
   *     `version.json`，没拆壳时等于安装包版本。
   */
  env.COLANAS_SHELL_VERSION = app.getVersion();
  env.COLANAS_ELECTRON_VERSION = process.versions.electron;
  let kernelSemver = app.getVersion();
  if (entry.versioned && entry.dir) {
    try {
      const meta = JSON.parse(fs.readFileSync(path.join(entry.dir, 'version.json'), 'utf8')) as {
        semver?: string;
      };
      if (meta.semver) kernelSemver = meta.semver;
    } catch {
      /* 版本目录缺 version.json：退回安装包版本 */
    }
  }
  env.COLANAS_APP_VERSION = kernelSemver;
  if (entry.id) env.COLANAS_VERSION_ID = entry.id;
  env.COLANAS_DATA_DIR = dataDir;

  kernel = utilityProcess.fork(entry.host, [], {
    // ⛔ 不要用 `stdio: 'inherit'`：打包成 GUI 程序后没有控制台，内核写往
    // stderr 的东西（启动期异常、MODULE_NOT_FOUND、迁移失败）会被直接丢掉。
    // 实测代价：1.3.17 连续 3 次启动失败，`kernel.log` 里一行都没有，
    // 只能靠 boot.json 的 attempts 计数猜，排障基本靠翻。
    // 改成 pipe 后统一落到 `logs/kernel-console.log`。
    stdio: ['ignore', 'pipe', 'pipe'],
    serviceName: 'colanas-kernel',
    env,
  });
  trace(`kernel forked pid=${kernel.pid} host=${entry.host} versioned=${entry.versioned}`);
  attachKernelConsole(kernel);

  kernel.on('message', (msg: unknown) => {
    const payload = msg as { type?: string; metrics?: WatchdogMetrics; port?: number } | null;
    if (payload && payload.type === 'listening') {
      const p = Number(payload.port);
      if (Number.isFinite(p) && p > 0) kernelPort = p;
      kernelReady = true;
      trace(`kernel listening port=${kernelPort}`);
      // 托盘提示里直接给地址：用户鼠标悬停就知道服务在哪
      tray?.setToolTip(trayTip(kernelUrl()));
      // 启动期间攒下的「打开网页」请求：现在真的可以开了
      if (pendingOpen) {
        pendingOpen = false;
        if (pendingOpenTimer) {
          clearTimeout(pendingOpenTimer);
          pendingOpenTimer = null;
        }
        openWeb();
      }
      return;
    }
    if (payload && payload.type === 'heartbeat') {
      guard.beat(Date.now(), payload.metrics ?? {});
    }
  });

  kernel.on('exit', (code) => {
    trace(`kernel exit code=${code}`);
    kernel = null;
    kernelReady = false;
    tray?.setToolTip(trayTip('内核重启中'));
    if (quitting) return;

    /**
     * 退出码 0 = 内核自己要求重启（重启按钮 / 切完版本生效）。
     * 这类重启不该计入「崩溃次数」，否则连续点两次重启就把 5 次额度耗光。
     * 自愈计数在 boot.json 里由壳和内核一起维护，与这个计数器互不干扰。
     */
    if (code === 0) {
      crashes = 0;
      healBeforeRestart();
      setTimeout(startKernel, 300);
      return;
    }

    crashes += 1;
    if (crashes > MAX_RESTARTS) {
      /**
       * 放弃重启之前必须先试一次自愈回滚。
       *
       * 否则用户拿到的是「一台死掉的服务」：boot.json 里明明记着这一版从没健康过，
       * 上一版还好端端躺在 versions/ 里，却因为「不再重启」而永远用不上。
       * 实测 1.3.17 就是这样：连续 3 次失败后指针仍指向坏版本，只能人工改 json。
       */
      const rolledBack = healBeforeRestart();
      if (rolledBack) {
        crashes = 0;
        tray?.setToolTip(trayTip('已回滚到上一版，正在重启'));
        setTimeout(startKernel, 500);
        return;
      }
      const msg =
        `内核连续退出 ${crashes} 次（最后一次退出码 ${code}），已停止自动重启。\n` +
        `诊断日志：${path.join(dataDir, 'logs', 'kernel-console.log')}`;
      console.error('[shell]', msg);
      tray?.setToolTip(trayTip('内核已停止'));
      dialog.showErrorBox('ColaNasOs', msg);
      return;
    }

    const delay = Math.min(1000 * 2 ** (crashes - 1), 8000);
    console.error(`[shell] kernel exited (code=${code}), restart #${crashes} in ${delay}ms`);
    healBeforeRestart();
    setTimeout(startKernel, delay);
  });
}

/**
 * 把内核的 stdout / stderr 落到 `logs/kernel-console.log`。
 *
 * 为什么要单独一个文件：pino 的 `kernel.log` 只记结构化日志，**进程级崩溃
 * （require 失败、native 模块 ABI 不匹配、未捕获异常）走的是 stderr**，在
 * 打包后的 GUI 外壳里原本完全看不见 —— 用户只看到「内核报错」弹框，而我们
 * 连退出原因都拿不到。
 *
 * 只保留最近 2 MB：这是排障用的滚动尾巴，不需要历史。
 */
function attachKernelConsole(proc: Electron.UtilityProcess): void {
  const dir = path.join(dataDir, 'logs');
  const file = path.join(dir, 'kernel-console.log');
  try {
    fs.mkdirSync(dir, { recursive: true });
    if (fs.existsSync(file) && fs.statSync(file).size > 2 * 1024 * 1024) {
      fs.renameSync(file, `${file}.1`);
    }
    const sink = fs.createWriteStream(file, { flags: 'a' });
    const onData = (chunk: Buffer | string) => {
      try {
        sink.write(chunk);
      } catch {
        /* 磁盘满 / 被占用：绝不能因此影响内核 */
      }
    };
    proc.stdout?.on('data', onData);
    proc.stderr?.on('data', onData);
  } catch (err) {
    trace(`attachKernelConsole failed: ${String(err)}`);
    // 落盘失败也必须把管道抽干：pipe 模式的缓冲区满了会把内核**阻塞**，
    // 那比丢日志严重得多。
    proc.stdout?.resume();
    proc.stderr?.resume();
  }
}

/**
 * 重启内核之前先做一次自愈判定。
 *
 * 只在 `whenReady` 评估一次是不够的：切完版本内核主动退出（exit 0）后外壳会
 * 立刻重新 fork，如果新版本起不来，`attempts` 永远不涨，回滚也就永远不会发生 ——
 * 用户看到的是「重启 5 次后弹个错误框」，而不是「自动退回上一版」。
 */
/** 重启内核之前先做一次自愈判定。返回是否真的发生了回滚。 */
function healBeforeRestart(): boolean {
  if (!versionedKernel) return false;
  try {
    const decision = prepareBoot(dataDir);
    if (decision.message) console.log(`[shell] 重启判定：${decision.message}`);
    trace(`heal action=${decision.action} id=${decision.id ?? '-'}`);
    if (decision.action === 'rollback') {
      tray?.setToolTip(trayTip(`已回滚到 ${decision.id}`));
      dialog.showErrorBox(
        'ColaNasOs',
        `新版本连续启动失败，已自动回滚到 ${decision.id}。\n` +
          '更新包与旧版本目录都保留着，排查后可在「设置 → 更新」里重试。',
      );
      return true;
    }
  } catch (err) {
    trace(`heal failed: ${String(err)}`);
  }
  return false;
}

function stopKernel(): void {
  if (!kernel) return;
  kernel.kill();
  kernel = null;
  kernelReady = false;
}

/**
 * 退出应用前让内核优雅收尾：停种子（向 tracker 发 stopped）→ 杀内置 transmission。
 *
 * 为什么必须由外壳发起：daemon 是 detached 常驻进程，内核被 kill（开发期重启、
 * 崩溃重启）时**故意不动它**，否则每次重启都是一次新的 tracker 请求，PT 站会
 * 累计成「多个做种位置」。只有用户真的退出应用，才需要把下载器一起停掉 ——
 * 「因为软件才拉起来的，退软件就该一起退」。
 *
 * 内核回 `shutdown-done` 后立刻退出；最多等 4s（发 stopped + 落日志足够），
 * 超时就直接杀，别把退出流程卡死。
 */
async function shutdownKernelGracefully(timeoutMs = 4000): Promise<void> {
  const proc = kernel;
  if (!proc) return;
  await new Promise<void>((resolve) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve();
    };
    const timer = setTimeout(finish, timeoutMs);
    proc.once('message', (msg: unknown) => {
      if ((msg as { type?: string } | null)?.type === 'shutdown-done') finish();
    });
    proc.once('exit', finish);
    try {
      proc.postMessage({ type: 'shutdown' });
    } catch {
      finish();
    }
  });
}

/** 用系统默认浏览器打开服务端 Web 页面（服务端自己没有窗口） */
function openWeb(): void {
  if (!kernelReady) {
    // 内核还没回传端口时不要弹窗：托盘单击、开机自启的第二实例都会走到这里，
    // 而开机那一刻内核必然还没起好 —— 每次都弹「服务正在启动」只能手动点掉。
    // 改成记下这次请求，等内核 listen 后自动打开。
    if (pendingOpen) return;
    pendingOpen = true;
    trace('openWeb deferred: kernel not ready');
    pendingOpenTimer = setTimeout(() => {
      pendingOpenTimer = null;
      if (!pendingOpen) return;
      pendingOpen = false;
      // 真的起不来（崩溃重启失败 / 端口被占）才提示，免得用户以为点了没反应
      void dialog.showMessageBox({
        type: 'info',
        title: 'ColaNasOs 服务端',
        message: '服务正在启动，请稍候再试',
        detail: `端口 ${kernelPort}，就绪后会自动更新托盘提示。`,
        buttons: ['好'],
      });
    }, OPEN_DEFER_MS);
    pendingOpenTimer.unref();
    return;
  }
  void shell.openExternal(`${kernelUrl()}/`);
}

function createTray(): void {
  // 托盘图标 = 品牌图单独渲染的 16/32 两档，按 DPI 交给系统挑：
  // 100% 缩放用 16×16 原始像素，150%/200% 用 32×32，不会把大图缩放糊掉。
  // 以前这里是脚本画的「紫底白圈」，跟安装包图标完全不是一套。
  const dir = resourcesDir();
  const trayIcon = ((): ReturnType<typeof nativeImage.createEmpty> => {
    const img = nativeImage.createEmpty();
    for (const [scaleFactor, name] of [
      [1, 'tray16.png'],
      [2, 'tray.png'],
    ] as const) {
      try {
        const file = path.join(dir, name);
        if (fs.existsSync(file)) {
          img.addRepresentation({ scaleFactor, buffer: fs.readFileSync(file) });
        }
      } catch (err) {
        trace(`tray icon ${name} failed: ${String(err)}`);
      }
    }
    if (img.isEmpty() || img.getScaleFactors().length === 0) {
      const fallback = nativeImage.createFromPath(path.join(dir, 'tray.png'));
      return fallback.isEmpty() ? nativeImage.createEmpty() : fallback;
    }
    return img;
  })();
  tray = new Tray(trayIcon);
  tray.setToolTip(trayTip('启动中'));
  rebuildTrayMenu();
  // 左键单击 = 打开 Web 页面（托盘程序的习惯动作）
  tray.on('click', () => openWeb());
  // Windows 上双击也走一次：有人习惯双击托盘
  tray.on('double-click', () => openWeb());
}

function rebuildTrayMenu(): void {
  if (!tray) return;
  const startOnBoot = isAutostartEnabled();
  tray.setContextMenu(
    Menu.buildFromTemplate([
      // 第一行直接给版本号：用户排查问题 / 报 bug 时第一句就要问「你是哪个版本」，
      // 以前只能去安装目录看文件名，或者翻设置页。
      { label: `ColaNasOs 服务端 ${appVer()}`, enabled: false },
      { type: 'separator' },
      { label: '打开 Web 页面', click: () => openWeb() },
      {
        label: '开机自动启动',
        type: 'checkbox',
        checked: startOnBoot,
        click: (item) => {
          // 落盘到数据目录 config.json（默认 false），再按当前 exe 写系统启动项。
          // 开发态只记状态、不动注册表，免得把安装版的启动项改成 electron.exe。
          setAutostart(item.checked);
          trace(`autostart=${item.checked}`);
          rebuildTrayMenu();
        },
      },
      { type: 'separator' },
      {
        label: '退出',
        click: () => {
          // 别在这里置 quitting：before-quit 靠它判断「第一次退出」，
          // 提前置 true 会把停种子 / 停内置下载器的优雅关闭整段跳过。
          app.quit();
        },
      },
    ]),
  );
}

app.whenReady().then(() => {
  trace('app ready');
  // 托盘勾选状态来源是数据目录里的设置；顺带按当前 exe 路径对账系统启动项
  const autostart = syncAutostart();
  console.log(`[shell] ColaNasOs 服务端 ${app.getVersion()} 启动（开机自启=${autostart ? '开' : '关'}）`);

  /**
   * 拆壳播种 + 自愈判定（只在打包态，或显式 `COLONAS_VERSIONED_KERNEL=1` 时启用）。
   *
   * 开发态不启用：`dist/` 每次 tsc 都会变，从版本目录跑会让开发循环失效。
   */
  // 托盘先建：播种要拷 50 MB（Web 产物），HDD 上要几秒，不能让人以为点了没反应
  createTray();

  versionedKernel = app.isPackaged || process.env.COLANAS_VERSIONED_KERNEL === '1';
  if (versionedKernel) {
    /**
     * 先把依赖摊到数据目录，再播种 / 判定。
     * 版本目录里的内核靠父目录找 `node_modules`，而依赖压在 app.asar 里 ——
     * 顺序反了就是 `Cannot find module 'fastify'`，内核直接起不来（实测）。
     */
    if (app.isPackaged) {
      try {
        ensureKernelModules(dataDir, process.resourcesPath, app.getVersion());
      } catch (err) {
        // 打包后没有控制台，console 只有开发者能看到；必须落盘，否则又是黑盒。
        shellLog(dataDir, `[shell] 内核依赖准备失败：${String(err)}`);
        console.error('[shell] 内核依赖准备失败，仍尝试从安装目录启动', err);
      }
    }
    try {
      seedIfNeeded(dataDir, seedSources());
    } catch (err) {
      trace(`seed failed: ${String(err)}`);
      console.error('[shell] 版本目录播种失败，本次仍从安装目录启动', err);
    }
    const decision = prepareBoot(dataDir);
    if (decision.message) console.log(`[shell] 启动判定：${decision.message}`);
    trace(`boot=${decision.action} id=${decision.id ?? '-'}`);
  }

  startKernel();

  // 进程外看门狗：内核「端口还在听但卡死」时也能拉回来
  watchdogTimer = setInterval(() => {
    const decision = guard.check(Date.now());
    if (decision.action === 'restart' && !watchdogGaveUp) {
      console.error('[watchdog] kernel unresponsive, restart:', decision);
      crashes = 0;
      stopKernel();
      healBeforeRestart();
      startKernel();
    } else if (decision.action === 'giveup' && !watchdogGaveUp) {
      watchdogGaveUp = true;
      const msg = '内核多次无响应，已停止自动重启（详见 watchdog.log）。';
      console.error('[watchdog]', msg);
      dialog.showErrorBox('ColaNasOs', msg);
    }
  }, 5000);
  watchdogTimer.unref?.();

  // macOS 点 Dock 图标：打开 Web 页面
  app.on('activate', () => openWeb());
});

app.on('before-quit', (e) => {
  if (quitting) return;
  // 先拦住这次退出，等内核把下载器停干净（最多 4s）再真正退出。
  // 不拦的话 Electron 会立刻走进程销毁，内核来不及发 tracker 的 stopped。
  e.preventDefault();
  quitting = true;
  if (watchdogTimer) clearInterval(watchdogTimer);
  void (async () => {
    try {
      await shutdownKernelGracefully();
    } catch {
      /* 内核已崩/已退：忽略 */
    }
    stopKernel();
    app.exit(0);
  })();
});
