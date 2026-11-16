import fsp from 'node:fs/promises';
import path from 'node:path';
import {
  filesRoot,
  httpError,
  isAbsoluteInput,
  absoluteInput,
  listBrowsableRoots,
  resolveInRoot,
  toPosix,
} from './fs-root';
import { dirVisible, type Visibility } from './visibility';

export interface ListQuery {
  path?: string;
  cursor?: string;
  limit?: string;
}

export interface Logger {
  debug(obj: unknown, msg: string): void;
}

/** GET /api/v1/files/list：单层列目录，目录优先、名称升序 */
export async function listHandler(q: ListQuery, log: Logger, vis?: Visibility) {
  const root = filesRoot();
  // 绝对路径（`D:/Photos`、`/D:/Photos`、`\\host\share`）= 浏览整机，不属于文件根的
  // 相对语义；相对路径仍走 resolveInRoot 的越界保护。
  const absolute = isAbsoluteInput(q.path);
  const target = absolute
    ? path.resolve(absoluteInput(q.path as string))
    : resolveInRoot(root, q.path);

  let entries;
  try {
    entries = await fsp.readdir(target, { withFileTypes: true });
  } catch (err) {
    const code = (err as NodeJS.ErrnoException).code;
    if (code === 'ENOENT') throw httpError(404, 'path not found');
    if (code === 'ENOTDIR') throw httpError(400, 'not a directory');
    if (code === 'EACCES') throw httpError(403, 'permission denied');
    throw err;
  }

  const limit = Math.max(1, Math.min(Number(q.limit || 200) || 200, 200));
  // 只列出授权目录链上的条目：授权目录本身、它的子目录，以及通往它的祖先目录。
  // 超级管理员 / 未传 vis 时不裁剪。
  const restricted = !!vis && !vis.unrestricted;
  const allowed = restricted
    ? entries.filter((e) => dirVisible(vis as Visibility, path.join(target, e.name)))
    : entries;
  const sorted = allowed.sort((a, b) => {
    if (a.isDirectory() !== b.isDirectory()) return a.isDirectory() ? -1 : 1;
    return a.name.localeCompare(b.name);
  });

  let items = sorted.slice(0, limit).map((e) => ({
    name: e.name,
    dir: e.isDirectory(),
  }));

  // 子账号的文件根里可能一条授权都没有（授权都在 D:/、F:/ 这些别的盘）。
  // 这时把「包含授权目录的盘符」补到根列表里，否则文件页一进来是空的，
  // 也永远走不到被授权的目录（用户 2026-11-14 反馈）。点进去后照常逐层裁剪。
  const atRoot = !absolute && path.resolve(target) === path.resolve(root);
  if (restricted && atRoot) {
    const known = new Set(items.map((i) => i.name.toLowerCase()));
    const drives = listBrowsableRoots()
      .filter((r) => r.kind === 'drive' && dirVisible(vis as Visibility, r.path))
      .filter((r) => !known.has(r.label.toLowerCase()))
      .map((r) => ({ name: r.label, dir: true }));
    items = [...drives, ...items].slice(0, limit);
  }

  log.debug({ root, target, count: items.length }, 'files.list');

  return {
    // 绝对路径原样回（POSIX 风格），前端据此继续往下一层拼；
    // 相对路径到根时回 `/`，前端面包屑才不会拼出 `./D:` 这种走不通的路径。
    path: absolute
      ? toPosix(target) || '/'
      : path.relative(root, target).split(path.sep).join('/') || '/',
    items,
    nextCursor: null,
  };
}
