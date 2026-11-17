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
}
