import test from 'node:test';
import assert from 'node:assert/strict';
import { ignoredBy, parseIgnore } from '../src/modules/files/ignore';

test('colanasignore: old/ 排除任意层级的 old 目录及其内容', () => {
  const r = parseIgnore('old/\n');
  assert.equal(ignoredBy(r, '立花里子/old', true), true);
  assert.equal(ignoredBy(r, '立花里子/old/ABP-123.mkv', false), true);
  assert.equal(ignoredBy(r, 'a/b/old/c/d.mkv', false), true);
  assert.equal(ignoredBy(r, 'Old', true), true, 'Windows 下不分大小写');
  // 名字里带 old 但不是一个 old 段，不能误伤
  assert.equal(ignoredBy(r, '立花里子/oldies/ABP-123.mkv', false), false);
  assert.equal(ignoredBy(r, '立花里子/ABP-123.mkv', false), false);
  // 带尾斜杠只作用于目录
  assert.equal(ignoredBy(r, 'old', false), false);
});

test('colanasignore: 通配符 / 锚定 / 注释 / 反选', () => {
  const r = parseIgnore(['# 注释忽略', '', '*.iso', '/预告/', '!预告/保留.iso', 'Sample/*.mkv'].join('\n'));
  assert.equal(ignoredBy(r, '电影/a.iso', false), true);
  assert.equal(ignoredBy(r, '预告/a.mkv', false), true);
  assert.equal(ignoredBy(r, 'x/预告/a.mkv', false), false, '前导斜杠锚定根目录');
  assert.equal(ignoredBy(r, '预告/保留.iso', false), false, '反选后一条生效');
  assert.equal(ignoredBy(r, 'Sample/a.mkv', false), true);
  assert.equal(ignoredBy(r, 'x/Sample/a.mkv', false), false);
});

test('colanasignore: 空文件 / 全是注释时不排除任何东西', () => {
  for (const text of ['', '\n\n', '# old/\n']) {
    assert.equal(ignoredBy(parseIgnore(text), '立花里子/old/a.mkv', false), false);
  }
});
