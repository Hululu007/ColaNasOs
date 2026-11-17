#!/usr/bin/env node
/**
 * 把 docs/wiki/*.md 同步到 GitHub Wiki 仓库。
 *
 * 用法：
 *   node tool/sync-wiki.js              # 同步并推送
 *   node tool/sync-wiki.js --dry-run    # 只看会推什么
 *
 * 约定：
 *   - 源文件在 docs/wiki/，文件名即 wiki 页面名（_Sidebar / _Footer 是 GitHub 的特殊页）。
 *   - 目标仓库 https://github.com/<owner>/<repo>.wiki.git
 *   - 认证走系统 git credential（Windows 上的 Git Credential Manager），不落盘明文。
 *
 * ⚠️ wiki 仓库在仓库创建后的第一次推送时才会被 GitHub 建出来。克隆报
 * 「Repository not found」时，先用 GitHub API 建一个页面（见 README 的说明），
 * 之后本脚本就能正常克隆了。
 */
const fs = require('fs');
const path = require('path');
const os = require('os');
const { execFileSync } = require('child_process');

const root = path.resolve(__dirname, '..');
const srcDir = path.join(root, 'docs', 'wiki');
const owner = process.env.WIKI_OWNER || 'colaKot';
const repo = process.env.WIKI_REPO || 'ColaNasOs';
const remote = `https://github.com/${owner}/${repo}.wiki.git`;
const dryRun = process.argv.includes('--dry-run');

function git(args, cwd) {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function fail(msg) {
  console.error(`[sync-wiki] ${msg}`);
  process.exit(1);
}

if (!fs.existsSync(srcDir)) fail(`找不到源目录：${srcDir}`);
// README.md 是仓库内的维护说明，不发布成 wiki 页面
const files = fs
  .readdirSync(srcDir)
  .filter((f) => f.endsWith('.md') && f !== 'README.md');
if (files.length === 0) fail(`${srcDir} 里没有 .md 文件`);

const work = path.join(os.tmpdir(), `colanas-wiki-${process.pid}`);
fs.rmSync(work, { recursive: true, force: true });

try {
  // 克隆（或更新）wiki 仓库
  try {
    git(['clone', remote, work]);
  } catch (e) {
    const msg = String(e.stderr || e.message || '');
    if (msg.includes('Repository not found')) {
      fail(
        `wiki 仓库还不存在（${remote}）。\n` +
          `  首次需要先建一个页面让 GitHub 把 wiki 仓库初始化出来，例如：\n` +
          `  curl -X PUT -H "Authorization: Bearer $TOKEN" \\\n` +
          `    -H "Accept: application/vnd.github+json" \\\n` +
          `    https://api.github.com/repos/${owner}/${repo}/wiki/pages/Home \\\n` +
          `    -d '{"title":"ColaNasOs","body":"init"}'`
      );
    }
    fail(`克隆失败：${msg.trim()}`);
  }

  // 拷贝页面文件
  let changed = 0;
  for (const f of files) {
    const dst = path.join(work, f);
    const before = fs.existsSync(dst) ? fs.readFileSync(dst, 'utf8') : null;
    const after = fs.readFileSync(path.join(srcDir, f), 'utf8');
    if (before !== after) {
      fs.writeFileSync(dst, after, 'utf8');
      changed += 1;
    }
  }

  // 删掉源目录里已经没有的页面（保留 .git）
  for (const f of fs.readdirSync(work)) {
    if (f === '.git' || f.endsWith('.md')) continue;
    const srcHas = files.includes(f);
    if (!srcHas) {
      fs.rmSync(path.join(work, f), { recursive: true, force: true });
      changed += 1;
    }
  }

  console.log(`[sync-wiki] 页面 ${files.length} 个，变更 ${changed} 个`);
  if (changed === 0) {
    console.log('[sync-wiki] 没有变化，跳过推送');
    process.exit(0);
  }
  if (dryRun) {
    console.log('[sync-wiki] --dry-run：不提交不推送');
    process.exit(0);
  }

  git(['add', '-A'], work);
  git(['commit', '-m', `docs(wiki): 同步 ${changed} 个页面（${new Date().toISOString().slice(0, 10)}）`], work);
  git(['push', 'origin', 'HEAD'], work);
  console.log(`[sync-wiki] 已推送 → ${remote}`);
} finally {
  fs.rmSync(work, { recursive: true, force: true });
}
