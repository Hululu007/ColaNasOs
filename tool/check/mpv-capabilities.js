#!/usr/bin/env node
/**
 * 检查桌面客户端实际使用的 libmpv 有没有「正确的 HDR / 杜比视界」能力。
 *
 * 为什么要单独一个脚本：客户端色不对时，第一反应总是「显卡不行」。
 * 实际上 Windows 客户端用的是 media_kit 自带的 libmpv-2.dll，它的构建参数
 * 决定了一切：
 *
 *   - `-Dlibplacebo=disabled` → 没有 gpu-next、没有动态色调映射、没有 DV RPU；
 *   - 没有 `gpu-next` 这个 VO → 连尝试都没有机会；
 *   - 即使换成带 libplacebo 的构建，`media_kit_video` 也是用 libmpv 的
 *     render API 出纹理（`vo=libmpv`），DV 仍然走不通 —— 要真直连 DV
 *     必须换渲染后端，不是换个 dll 就行。
 *
 * 用法：
 *   node tool/check/mpv-capabilities.js
 *   npm run mpv:check
 *
 * 找不到 dll 时按「未构建」处理并退出 0：这个检查是诊断工具，不是门禁。
 */
'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.join(__dirname, '..', '..');

const candidates = [
  path.join(root, 'apps', 'colanas_os', 'build', 'windows', 'x64', 'libmpv', 'libmpv-2.dll'),
  path.join(root, 'apps', 'colanas_os', 'build', 'windows', 'x64', 'runner', 'Release', 'libmpv-2.dll'),
  path.join(root, 'vendor', 'mpv', 'win64', 'libmpv-2.dll'),
];

function findDll() {
  for (const p of candidates) {
    if (fs.existsSync(p)) return p;
  }
  // media_kit 构建期缓存（只在 build 目录被清掉时才有用）
  const cache = path.join(os.tmpdir(), 'media_kit');
  try {
    for (const name of fs.readdirSync(cache)) {
      const dir = path.join(cache, name, 'libmpv');
      const dll = path.join(dir, 'libmpv-2.dll');
      if (fs.existsSync(dll)) return dll;
    }
  } catch {
    /* 没有缓存目录 */
  }
  return null;
}

/** 在二进制里找 ASCII 字符串（dll 里这些都是明文字面量）。 */
function has(buf, needle) {
  return buf.includes(Buffer.from(needle, 'ascii'));
}

function readVersion(buf) {
  // 二进制里是 `mpv v0.36.0`（`--version` 的第一行）
  const m = /mpv v?(\d+\.\d+\.\d+)/.exec(buf.toString('latin1'));
  return m ? `mpv ${m[1]}` : 'unknown';
}

function main() {
  const dll = findDll();
  if (!dll) {
    console.log('[mpv] 没找到 libmpv-2.dll（还没构建过 Windows 客户端）');
    console.log('      先跑 build-pc.bat，或把带 libplacebo 的构建放到 vendor/mpv/win64/');
    return 0;
  }

  const buf = fs.readFileSync(dll);
  const gpuNext = has(buf, 'gpu-next');
  const libplaceboDisabled = has(buf, 'libplacebo=disabled');
  const dolbyVision = has(buf, 'dolbyvision');

  console.log(`[mpv] ${path.relative(root, dll)}`);
  console.log(`[mpv] 版本           ${readVersion(buf)}`);
  console.log(`[mpv] gpu-next       ${gpuNext ? '有' : '没有'}`);
  console.log(`[mpv] libplacebo     ${libplaceboDisabled ? '构建时被禁用' : '已编入（未检测到禁用标记）'}`);
  console.log(`[mpv] dolbyvision    ${dolbyVision ? '有相关串' : '无'}`);
  console.log('');

  if (gpuNext && !libplaceboDisabled) {
    console.log('[mpv] 结论：这个构建有 gpu-next / libplacebo，DV 与 HDR 的动态色调映射链路存在。');
    console.log('      但 media_kit_video 仍固定 vo=libmpv 出纹理；要真正吃到 gpu-next');
    console.log('      需要替换渲染后端（见 docs/播放链路与架构-2026-11-13.md）。');
  } else {
    console.log('[mpv] 结论：这个构建没有 libplacebo，DV 直连一定偏色（P5 发紫 / 荧光绿），');
    console.log('      HDR10 只能靠 mpv 自带的 bt.2390 + hdr-compute-peak 近似。');
    console.log('      客户端现在的做法：DV 一律走服务端色调映射转码（色彩正确），');
    console.log('      HDR10 / HLG 直连并把 hdr-compute-peak 打开。');
  }
  return 0;
}

process.exitCode = main();
