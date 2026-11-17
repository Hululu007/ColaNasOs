import 'dart:io';

import 'package:colanas_os/features/video/offline/offline_models.dart';
import 'package:colanas_os/features/video/offline/offline_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// 本地索引的读写与自愈。
///
/// 这些行为都是「看不见但错了很难查」的类型：索引与文件不一致、删了最后一集
/// 还留着整剧卡片、封面被提前删掉导致别的片子白框。全部在纯 IO 层断言。
void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('colanas-offline-test-');
    for (final dir in ['videos', 'posters', 'index', 'temp']) {
      await Directory(p.join(tmp.path, dir)).create(recursive: true);
    }
  });

  tearDown(() async {
    try {
      await tmp.delete(recursive: true);
    } catch (_) {
      // Windows 上偶尔有句柄没释放，留给系统清理
    }
  });

  Future<void> touchVideo(String name) async {
    await File(p.join(tmp.path, 'videos', name)).writeAsString('x');
  }

  LocalMediaItem item(String id, {String groupId = 'g', int? episode}) => LocalMediaItem(
    id: id,
    groupId: groupId,
    libraryId: 'lib1',
    title: '第 $id 集',
    filePath: 'videos/$id.mp4',
    bytes: 100,
    season: 1,
    episode: episode,
    height: 1080,
    videoCodec: 'hevc',
    container: 'mp4',
  );

  test('索引写盘后能原样读回', () async {
    final store = OfflineStore(tmp.path);
    await store.putGroup(
      LocalMediaGroup(
        id: 'g',
        kind: 'series',
        libraryId: 'lib1',
        libraryName: '电视剧',
        title: '测试剧',
        totalEpisodes: 24,
        itemIds: ['a'],
      ),
    );
    await store.putItem(item('a', episode: 1));
    await store.saveLibrary();

    final reloaded = OfflineStore(tmp.path);
    await reloaded.load();
    expect(reloaded.groups.length, 1);
    expect(reloaded.groups['g']!.title, '测试剧');
    expect(reloaded.groups['g']!.totalEpisodes, 24);
    expect(reloaded.items['a']!.filePath, 'videos/a.mp4');
    expect(reloaded.items['a']!.specLabel, '1080P · H.265 · MP4');
  });

  test('原子写不留 .tmp 残渣', () async {
    final store = OfflineStore(tmp.path);
    await store.putItem(item('a'));
    await store.saveLibrary();
    await store.saveTasks();

    final leftovers = Directory(p.join(tmp.path, 'index'))
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n.endsWith('.tmp'))
        .toList();
    expect(leftovers, isEmpty);
  });

  test('文件消失 → 条目与空合集一起被摘掉', () async {
    final store = OfflineStore(tmp.path);
    await touchVideo('a.mp4');
    await store.putGroup(
      LocalMediaGroup(
        id: 'g',
        kind: 'series',
        libraryId: 'lib1',
        title: '测试剧',
        itemIds: ['a'],
      ),
    );
    await store.putItem(item('a', episode: 1));
    await store.saveLibrary();

    await File(p.join(tmp.path, 'videos', 'a.mp4')).delete();
    await store.reconcile();

    expect(store.items.containsKey('a'), isFalse);
    // 最后一集没了，整剧卡片也不该留
    expect(store.groups.containsKey('g'), isFalse);
  });

  test('删一集不影响同剧其它集', () async {
    final store = OfflineStore(tmp.path);
    await touchVideo('a.mp4');
    await touchVideo('b.mp4');
    await store.putGroup(
      LocalMediaGroup(
        id: 'g',
        kind: 'series',
        libraryId: 'lib1',
        title: '测试剧',
        posterPath: 'posters/p.jpg',
        itemIds: ['a', 'b'],
      ),
    );
    await store.putItem(item('a', episode: 1));
    await store.putItem(item('b', episode: 2));

    final removed = store.removeItems(['a']);
    expect(removed.length, 1);
    expect(store.items.containsKey('b'), isTrue);
    expect(store.groups['g']!.itemIds, ['b']);
    // 封面还在被这一集用着，不能删
    expect(store.posterInUse('posters/p.jpg'), isTrue);
  });

  test('删掉最后一集后封面不再被引用', () async {
    final store = OfflineStore(tmp.path);
    await store.putGroup(
      LocalMediaGroup(
        id: 'g',
        kind: 'series',
        libraryId: 'lib1',
        title: '测试剧',
        posterPath: 'posters/p.jpg',
        itemIds: ['a'],
      ),
    );
    await store.putItem(item('a', episode: 1));

    store.removeItems(['a']);
    expect(store.groups.containsKey('g'), isFalse);
    expect(store.posterInUse('posters/p.jpg'), isFalse);
  });

  test('orphan：有文件但索引没有 → 记下来（不静默吞掉）', () async {
    final store = OfflineStore(tmp.path);
    await touchVideo('ghost.mp4');
    await store.reconcile();
    expect(store.orphanFiles, contains('ghost.mp4'));
  });

  test('索引文件损坏时按空库启动，不抛错', () async {
    await File(p.join(tmp.path, 'index', 'items.json')).writeAsString('{"items":[wrong}');
    final store = OfflineStore(tmp.path);
    await store.load();
    expect(store.items, isEmpty);
  });

  test('IndexFile 兼容裸数组与包了 items 的新格式', () {
    expect(IndexFile.decode('[{"id":"a"}]').first['id'], 'a');
    expect(IndexFile.decode('{"version":1,"items":[{"id":"b"}]}').first['id'], 'b');
    expect(IndexFile.decode(''), isEmpty);
    expect(IndexFile.decode('{}'), isEmpty);
  });

  test('任务记录带 meta 往返（重启续传要靠它复现上下文）', () {
    final record = OfflineTaskRecord(
      itemId: 'a',
      jobId: 'job-1',
      title: '第 1 集',
      libraryId: 'lib1',
      spec: const {'codec': 'h265', 'height': 1080},
      meta: const {'seriesKey': 'lib1\u0000测试剧', 'episode': 1, 'posterUrl': 'http://x/p.jpg'},
      state: OfflineTaskState.downloading,
      downloadedBytes: 10,
      totalBytes: 100,
    );
    final back = OfflineTaskRecord.fromJson(record.toJson());
    expect(back.jobId, 'job-1');
    expect(back.state, OfflineTaskState.downloading);
    expect(back.meta['episode'], 1);
    expect(back.meta['seriesKey'], 'lib1\u0000测试剧');
    // 编码假设：下载阶段只占后 70%
    expect(back.overall, closeTo(0.3 + 0.1 * 0.7, 0.001));
  });

  // ---------------------------------------------------------------- 覆盖替换恢复
  //
  // 替换是「旧片 rename 成 .old」+「新片 rename 到位」两步。两步之间断电会留下
  // 四种半成品组合，任何一种都必须收敛到「有一个能播的文件」，绝不能两边都没了。

  Future<void> writeLog(String dst, String back, String part) async {
    await File(p.join(tmp.path, 'index', 'replace.log')).writeAsString(
      '{"dst":"$dst","back":"$back","part":"$part"}',
    );
  }

  Future<void> write(String rel, String content) async {
    final file = File(p.join(tmp.path, rel));
    await file.parent.create(recursive: true);
    await file.writeAsString(content);
  }

  test('替换恢复：只写了日志、还没退位 → 保持原样', () async {
    await write('videos/a.mp4', 'old');
    await writeLog('videos/a.mp4', 'videos/a.mp4.old', 'temp/a.part');
    final store = OfflineStore(tmp.path);
    expect(await store.recoverReplacement(), 'abort_before_swap');
    expect(await File(p.join(tmp.path, 'videos', 'a.mp4')).readAsString(), 'old');
    expect(await File(p.join(tmp.path, 'index', 'replace.log')).exists(), isFalse);
  });

  test('替换恢复：卡在两次 rename 之间 → 把新片放到位', () async {
    await write('videos/a.mp4.old', 'old');
    await write('temp/a.part', 'new');
    await writeLog('videos/a.mp4', 'videos/a.mp4.old', 'temp/a.part');
    final store = OfflineStore(tmp.path);
    expect(await store.recoverReplacement(), 'complete_swap');
    expect(await File(p.join(tmp.path, 'videos', 'a.mp4')).readAsString(), 'new');
    expect(await File(p.join(tmp.path, 'videos', 'a.mp4.old')).exists(), isFalse);
    expect(await File(p.join(tmp.path, 'temp', 'a.part')).exists(), isFalse);
  });

  test('替换恢复：新片已就位、旧片没删 → 只清旧的', () async {
    await write('videos/a.mp4', 'new');
    await write('videos/a.mp4.old', 'old');
    await writeLog('videos/a.mp4', 'videos/a.mp4.old', 'temp/a.part');
    final store = OfflineStore(tmp.path);
    expect(await store.recoverReplacement(), 'drop_backup');
    expect(await File(p.join(tmp.path, 'videos', 'a.mp4')).readAsString(), 'new');
    expect(await File(p.join(tmp.path, 'videos', 'a.mp4.old')).exists(), isFalse);
  });

  test('替换恢复：新片丢了 → 回滚旧片（宁可留旧版本）', () async {
    await write('videos/a.mp4.old', 'old');
    await writeLog('videos/a.mp4', 'videos/a.mp4.old', 'temp/a.part');
    final store = OfflineStore(tmp.path);
    expect(await store.recoverReplacement(), 'rollback');
    expect(await File(p.join(tmp.path, 'videos', 'a.mp4')).readAsString(), 'old');
    expect(await File(p.join(tmp.path, 'videos', 'a.mp4.old')).exists(), isFalse);
  });

  test('替换恢复：日志写坏 → 什么都不动，只丢掉日志', () async {
    await write('videos/a.mp4', 'old');
    await File(p.join(tmp.path, 'index', 'replace.log')).writeAsString('{"dst":"videos/a');
    final store = OfflineStore(tmp.path);
    expect(await store.recoverReplacement(), 'log_corrupt');
    expect(await File(p.join(tmp.path, 'videos', 'a.mp4')).readAsString(), 'old');
    expect(await File(p.join(tmp.path, 'index', 'replace.log')).exists(), isFalse);
  });

  test('替换恢复：没有日志就是空操作', () async {
    final store = OfflineStore(tmp.path);
    expect(await store.recoverReplacement(), isNull);
  });

  // ---------------------------------------------------------------- 目录迁移
  //
  // 迁移错了就是丢片子，所以拷贝这件事本身必须有断言：结构不能变形、
  // 半截 .tmp 不能跟着搬、每个文件大小要对得上。

  test('迁移拷贝：结构与内容完整，跳过 .tmp', () async {
    await write('videos/a.mp4', 'AAA');
    await write('posters/p.jpg', 'PP');
    await write('subtitles/a.zh.vtt', 'WEBVTT');
    await write('index/items.json', '{"version":1,"items":[]}');
    await write('index/items.json.tmp', 'half');

    final store = OfflineStore(tmp.path);
    final target = p.join(tmp.path, 'moved');
    await Directory(target).create(recursive: true);

    var lastDone = 0;
    var lastTotal = 0;
    final copied = await store.copyLibraryTo(
      target,
      onProgress: (done, total) {
        lastDone = done;
        lastTotal = total;
      },
    );

    expect(copied, 4);
    expect(lastDone, 4);
    expect(lastTotal, 4);
    expect(await File(p.join(target, 'videos', 'a.mp4')).readAsString(), 'AAA');
    expect(await File(p.join(target, 'posters', 'p.jpg')).readAsString(), 'PP');
    expect(await File(p.join(target, 'subtitles', 'a.zh.vtt')).readAsString(), 'WEBVTT');
    // .tmp 不搬
    expect(await File(p.join(target, 'index', 'items.json.tmp')).exists(), isFalse);
  });

  test('迁移拷贝：空库也能跑（0 个文件不报错）', () async {
    final store = OfflineStore(tmp.path);
    final target = p.join(tmp.path, 'empty');
    await Directory(target).create(recursive: true);
    expect(await store.copyLibraryTo(target), 0);
  });

  // ---------------------------------------------------------------- 任务状态机
  //
  // 调度器只看 `readyToRun`，界面只看 `active`。两个口径搞混的后果很具体：
  // 暂停的任务被重新捡起来跑，或者「等 WiFi」的任务被当成消失了。

  OfflineTaskRecord taskWith(OfflineTaskState state, {int nextTryAt = 0}) => OfflineTaskRecord(
    itemId: 'a',
    jobId: 'j',
    title: 't',
    libraryId: 'lib',
    spec: const <String, dynamic>{},
    state: state,
    nextTryAt: nextTryAt,
  );

  test('运行类状态可以跑；暂停 / 等 WiFi / 终态都不跑', () {
    for (final s in [
      OfflineTaskState.queued,
      OfflineTaskState.transcoding,
      OfflineTaskState.downloading,
      OfflineTaskState.verifying,
      OfflineTaskState.replacing,
    ]) {
      expect(taskWith(s).readyToRun, isTrue, reason: s.name);
    }
    for (final s in [
      OfflineTaskState.paused,
      OfflineTaskState.waitingWifi,
      OfflineTaskState.done,
      OfflineTaskState.failed,
      OfflineTaskState.canceled,
    ]) {
      expect(taskWith(s).readyToRun, isFalse, reason: s.name);
    }
  });

  test('暂停与等 WiFi 仍算「进行中」（否则用户以为任务没了）', () {
    expect(taskWith(OfflineTaskState.paused).active, isTrue);
    expect(taskWith(OfflineTaskState.waitingWifi).active, isTrue);
    expect(taskWith(OfflineTaskState.failed).active, isFalse);
    expect(taskWith(OfflineTaskState.done).active, isFalse);
  });

  test('退避未到点的任务不跑，到点就跑', () {
    final future = DateTime.now().millisecondsSinceEpoch + 60_000;
    expect(taskWith(OfflineTaskState.queued, nextTryAt: future).readyToRun, isFalse);
    final past = DateTime.now().millisecondsSinceEpoch - 1;
    expect(taskWith(OfflineTaskState.queued, nextTryAt: past).readyToRun, isTrue);
  });

  test('任务记录带重试字段往返', () {
    final task = taskWith(OfflineTaskState.failed)..attempts = 2..nextTryAt = 12345;
    final back = OfflineTaskRecord.fromJson(task.toJson());
    expect(back.attempts, 2);
    expect(back.nextTryAt, 12345);
    expect(back.state, OfflineTaskState.failed);
  });
}
