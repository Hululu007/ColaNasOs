import assert from 'node:assert/strict';
import test, { describe } from 'node:test';
import { duplicateKey, extractDupCode, hasWord, seqToken } from '../src/modules/video/routes/duplicates';

describe('video · 重复片名归一化', () => {
  test('画质 / 编码 / 发布组 / 日系标记都归一到同一个 key', () => {
    const key = 'alpha';
    for (const title of [
      'Alpha',
      'Alpha 1080p x264-GROUP',
      'Alpha 2160p HDR10+HDR',
      'Alpha 4K HEVC 10bit',
      'Alpha-UC',
      'Alpha [2020]',
      'Alpha WEB-DL',
    ]) {
      assert.equal(duplicateKey(title), key, title);
    }
  });

  test('不同片子不被合并', () => {
    assert.notEqual(duplicateKey('Alpha'), duplicateKey('Beta'));
  });

  test('只有噪声的文件名归一化为空（不参与分组）', () => {
    assert.equal(duplicateKey('1080p x264'), '');
  });
});

describe('video · 同名不同序号不算重复', () => {
  test('括号里的纯数字序号要单独识别出来', () => {
    assert.equal(seqToken('街拍2023 (55).mp4'), 'seq55');
    assert.equal(seqToken('街拍2023（57）'), 'seq57');
    assert.equal(seqToken('街拍2023 (6).mp4'), 'seq6');
    // 同一部片的不同序号必须能区分开（否则会被并成一组「重复」）
    assert.notEqual(seqToken('街拍2023 (55)'), seqToken('街拍2023 (57)'));
    assert.notEqual(seqToken('街拍2023 (6)'), seqToken('街拍2023 (60)'));
  });

  test('年份 / 分辨率 / 技术标记不是序号', () => {
    assert.equal(seqToken('Alpha (2020)'), '');
    assert.equal(seqToken('Alpha [2024]'), '');
    assert.equal(seqToken('Alpha (1080)'), '');
    assert.equal(seqToken('Alpha (2160)'), '');
    assert.equal(seqToken('Alpha (720p)'), '');
    assert.equal(seqToken('Alpha 1080p x264'), '');
    assert.equal(seqToken('IPZ-947-C'), '');
  });

  test('归一化本身仍然剥掉括号，序号由 seqToken 单独承载', () => {
    assert.equal(duplicateKey('街拍2023 (55)'), duplicateKey('街拍2023 (57)'));
    assert.equal(duplicateKey('街拍2023 (55)'), '街拍2023');
  });
});

describe('video · 排重四钥匙辅助', () => {
  test('番号必须带分隔符，且数字不能是年份', () => {
    assert.equal(extractDupCode('IPZ-947.mkv'), 'IPZ-947');
    assert.equal(extractDupCode('abc_123.mp4'), 'ABC-123');
    // 年份不当番号
    assert.equal(extractDupCode('Movie 2020 1080p.mkv'), '');
    assert.equal(extractDupCode('Interstellar.2014.mkv'), '');
    // 技术标记不当番号
    assert.equal(extractDupCode('Show.S01E02.1080p.mkv'), '');
  });

  test('纯数字 / 纯符号标题不参与判重', () => {
    assert.equal(hasWord('-02-24 17 51'), false);
    assert.equal(hasWord('2024-02-24 17.51.25'), false);
    assert.equal(hasWord('银翼杀手'), true);
    assert.equal(hasWord('Blade Runner'), true);
  });
});
