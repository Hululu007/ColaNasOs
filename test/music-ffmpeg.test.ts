import assert from 'node:assert/strict';
import test from 'node:test';
import { parseContainerTags } from '../src/modules/music/ffmpeg';

/**
 * wav 元数据乱码回归测试。
 *
 * 背景：部分 wav 头部 ID3v2 标签是 UTF-8 正常中文，尾部 RIFF INFO 块是 GBK 字节。
 * ffmpeg -i 的 stderr 里同名 tag 出现两次（正常值在前、GBK 乱码在后），GBK 字节经
 * UTF-8 解码后变成含 U+FFFD 的乱码。解析若后写覆盖前写，正常中文就被乱码顶掉，
 * 存进 music_tracks 后界面显示成问号（2026-11-20，程璧《早生的铃虫》）。
 */

const gbkMojibake = '\ufffdx (\ufffd\ufffd\ufffd\ufffd)'; // GBK「序曲 (虫声)」被误解码的后果

test('同名 tag：跳过乱码值，保留前面的正常 UTF-8 值', () => {
  const stderr = [
    'Input #0, wav, from ...:',
    '  Metadata:',
    '    title           : 蟲聲 (序曲)',
    '    artist          : 程璧',
    '    album           : 早生的鈴蟲',
    '    date            : 2016',
    `    artist          : ${gbkMojibake}`, // 尾部 GBK，乱码
    `    title           : ${gbkMojibake}`,
    `    album           : ${gbkMojibake}`,
    '  Duration: 00:03:12.00',
  ].join('\n');
  const tags = parseContainerTags(stderr);
  assert.equal(tags.title, '蟲聲 (序曲)');
  assert.equal(tags.artist, '程璧');
  assert.equal(tags.album, '早生的鈴蟲');
  assert.equal(tags.date, '2016');
});

test('只有乱码值时该字段留空，不写入 U+FFFD', () => {
  const stderr = [
    'Input #0, wav:',
    '  Metadata:',
    `    title           : ${gbkMojibake}`,
    '    track           : 1/12',
    '  Duration: 00:01:00.00',
  ].join('\n');
  const tags = parseContainerTags(stderr);
  assert.equal(tags.title, undefined);
  assert.equal(tags.track, '1/12');
});

test('流级第二个 Metadata 块不覆盖容器级', () => {
  const stderr = [
    'Input #0, wav:',
    '  Metadata:',
    '    title           : 正常标题',
    '  Duration: 00:01:00.00',
    '    Stream #0:0: Audio: pcm_s16le',
    '    Metadata:',
    '      title         : 流级标题不应覆盖',
    '      language      : chi',
  ].join('\n');
  const tags = parseContainerTags(stderr);
  assert.equal(tags.title, '正常标题');
});
