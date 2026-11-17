#!/usr/bin/env node
/**
 * 片源能力解析（纯函数，可被 smoke 直接 require）。
 *
 * 运行时只有 ffmpeg、没有 ffprobe：`ffmpeg -hide_banner -loglevel info -i <src>`
 * 会以 1 退出，但 stderr 里带完整流信息，够用了。解析结果用来决定：
 *   - Dolby Vision（尤其 Profile 5 / IPT-PQ）不能按普通 HDR10 处理；
 *   - H.264 10-bit（Hi10P）三家硬解都不支持，必须软解；
 *   - 没有标准色彩元数据时，CPU 的 `zscale=t=linear` 链会直接失败。
 */
'use strict';

const EMPTY_SOURCE = Object.freeze({
  codec: '',
  profile: '',
  pixFmt: '',
  width: 0,
  height: 0,
  durationMs: 0,
  tenBit: false,
  hi10p: false,
  dvProfile: 0,
  hasHdrMeta: false,
  hdrKind: 'none',
});

/**
 * @param {string} stderr `ffmpeg -i` 的 stderr
 * @returns {{codec:string,profile:string,pixFmt:string,width:number,height:number,
 *   tenBit:boolean,hi10p:boolean,dvProfile:number,hasHdrMeta:boolean,hdrKind:string}}
 */
function parseSource(stderr) {
  const text = String(stderr || '');
  const lines = text.split(/\r?\n/);
  const vline = lines.find((l) => /Stream\s+#\d+:\d+.*Video:/.test(l)) || '';

  const codec = (/Video:\s*([^\s,(]+)/.exec(vline) || [])[1] || '';
  const profile = (/Video:\s*\S+\s*\(([^)]+)\)/.exec(vline) || [])[1] || '';
  const pixFmt = (/,\s*((?:yuv|nv|p0|rgb|gbrp)[a-z0-9_]*)\b/i.exec(vline) || [])[1] || '';
  const dim = /(\d{3,5})x(\d{3,5})/.exec(vline) || [];
  const width = Number(dim[1]) || 0;
  const height = Number(dim[2]) || 0;

  const tenBit = /10(?:le|be)|p010|12(?:le|be)/i.test(pixFmt) || /10-bit|Main 10|High 10/i.test(profile);
  // H.264 10-bit (Hi10P)：Intel / NVIDIA / AMD 的硬解单元全都不吃，只能软解。
  const hi10p = /^(?:h264|avc)$/i.test(codec) && tenBit;

  const dovi =
    /DOVI configuration record[^\n]*profile:\s*(\d+)/i.exec(text) ||
    /dv_profile[^\d]*(\d+)/i.exec(text);
  const dvProfile = Number((dovi || [])[1]) || 0;

  // `Stream ... Video:` 行里的色彩标记；DV P5 通常一个都没有（色彩在 RPU 里）。
  const hlg = /arib-std-b67|\bhlg\b/i.test(vline);
  const hdr10 = /smpte2084|bt2020|Mastering display metadata/i.test(vline);
  const hasHdrMeta = hlg || hdr10;

  // `Duration: 01:58:32.45`：离线下载要拿它算编码进度百分比，不能按文件大小估
  // （VBR 片源按字节算出来的进度会跳着走，用户看着像卡住）。
  const dur = /Duration:\s*(\d+):(\d{2}):(\d{2})\.(\d{2})/.exec(text);
  const durationMs = dur
    ? Math.round(
        (Number(dur[1]) * 3600 + Number(dur[2]) * 60 + Number(dur[3]) + Number(dur[4]) / 100) *
          1000,
      )
    : 0;

  return {
    codec,
    profile,
    pixFmt,
    width,
    height,
    durationMs,
    tenBit,
    hi10p,
    dvProfile,
    hasHdrMeta,
    hdrKind: dvProfile ? 'dv' : hlg ? 'hlg' : hdr10 ? 'hdr10' : 'none',
  };
}

module.exports = { EMPTY_SOURCE, parseSource };
