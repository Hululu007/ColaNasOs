import 'dart:io';

import 'package:path/path.dart' as p;

import 'offline_models.dart';

/// 本地索引（`Offline/index/*.json`）的读写与自愈。
///
/// 为什么用 JSON 而不是 SQLite：离线媒体本来就是「文件为准」，索引只是一个
/// 便于分组的视图。索引丢了可以从 `videos/` 重建（文件名就是条目 id），
/// 而数据库坏了要写迁移。数据量按几千条估（单条约 400 B），全量读进内存没压力。
class OfflineStore {
  OfflineStore(this.root);

  final String root;

  final Map<String, LocalMediaGroup> groups = <String, LocalMediaGroup>{};
  final Map<String, LocalMediaItem> items = <String, LocalMediaItem>{};
  final Map<String, OfflineTaskRecord> tasks = <String, OfflineTaskRecord>{};

  /// `videos/` 里存在、但索引里没有的文件（手工删过 JSON / 上次写盘失败）。
  /// 只用于提示与清理，不参与展示。
  final List<String> orphanFiles = <String>[];

  String get indexDir => p.join(root, 'index');
  File get _groupsFile => File(p.join(indexDir, 'groups.json'));
  File get _itemsFile => File(p.join(indexDir, 'items.json'));
  File get _tasksFile => File(p.join(indexDir, 'tasks.json'));

  /// 把相对路径解析成绝对路径（索引里一律存相对）
  String absolute(String relative) =>
      p.joinAll(<String>[root, ...relative.split('/').where((s) => s.isNotEmpty)]);

  Future<void> load() async {
    groups
      ..clear()
      ..addEntries(
        (await _read(_groupsFile))
            .map(LocalMediaGroup.fromJson)
            .map((g) => MapEntry(g.id, g)),
      );
    items
      ..clear()
      ..addEntries(
        (await _read(_itemsFile))
            .map(LocalMediaItem.fromJson)
            .map((i) => MapEntry(i.id, i)),
      );
    tasks
      ..clear()
      ..addEntries(
        (await _read(_tasksFile))
            .map(OfflineTaskRecord.fromJson)
            .map((t) => MapEntry(t.itemId, t)),
      );
  }

  /// 与磁盘对账：文件没了的条目直接摘掉（手工删文件是合法操作），
  /// 空掉的合集一并清掉。不做「标记缺失」——离线库的第一原则是**文件在才算数**。
  Future<void> reconcile() async {
    final gone = <String>[];
    for (final entry in items.entries) {
      final file = File(absolute(entry.value.filePath));
      if (!await file.exists()) gone.add(entry.key);
    }
    for (final id in gone) {
      items.remove(id);
    }

    for (final group in groups.values.toList()) {
      group.itemIds.removeWhere((id) => !items.containsKey(id));
      if (group.itemIds.isEmpty) {
        groups.remove(group.id);
        continue;
      }
      if (group.isSeries) {
        group.totalEpisodes = group.totalEpisodes < group.itemIds.length
            ? group.itemIds.length
            : group.totalEpisodes;
      }
    }

    // 反向：有文件但索引里没有
    orphanFiles.clear();
    final videosDir = Directory(p.join(root, 'videos'));
    if (await videosDir.exists()) {
      final known = items.values
          .map((i) => p.basename(absolute(i.filePath)))
          .toSet();
      await for (final entity in videosDir.list()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.startsWith('.')) continue;
        if (!known.contains(name)) orphanFiles.add(name);
      }
    }

    if (gone.isNotEmpty) await saveLibrary();
  }

  Future<void> saveLibrary() async {
    await _writeAtomic(
      _groupsFile,
      IndexFile(
        items: groups.values.map((g) => g.toJson()).toList(),
      ).encode(),
    );
    await _writeAtomic(
      _itemsFile,
      IndexFile(items: items.values.map((i) => i.toJson()).toList()).encode(),
    );
  }

  Future<void> saveTasks() async {
    await _writeAtomic(
      _tasksFile,
      IndexFile(items: tasks.values.map((t) => t.toJson()).toList()).encode(),
    );
  }

  // ---------------------------------------------------------------- 查询

  LocalMediaItem? item(String id) => items[id];

  LocalMediaGroup? groupOf(String itemId) {
    final item = items[itemId];
    if (item == null) return null;
    return groups[item.groupId];
  }

  /// 某合集的条目，按季 / 集排序（剧集列表直接用）
  List<LocalMediaItem> itemsOfGroup(String groupId) {
    final list = items.values.where((i) => i.groupId == groupId).toList();
    list.sort((a, b) {
      final sa = a.season ?? 0;
      final sb = b.season ?? 0;
      if (sa != sb) return sa.compareTo(sb);
      final ea = a.episode ?? 0;
      final eb = b.episode ?? 0;
      if (ea != eb) return ea.compareTo(eb);
      return a.title.compareTo(b.title);
    });
    return list;
  }

  /// 本地视频页的分组：先按来源库，再按最近更新
  List<LocalMediaGroup> sortedGroups({String? libraryId}) {
    final list = groups.values
        .where((g) => libraryId == null || libraryId.isEmpty || g.libraryId == libraryId)
        .toList();
    list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return list;
  }

  /// 出现过的来源库（chip 用）：id → 名称快照
  Map<String, String> libraries() {
    final out = <String, String>{};
    for (final g in groups.values) {
      out[g.libraryId] = g.libraryName.isEmpty ? g.libraryId : g.libraryName;
    }
    return out;
  }

  int get totalBytes => items.values.fold(0, (sum, i) => sum + i.bytes);

  // ---------------------------------------------------------------- 写

  Future<void> putItem(LocalMediaItem item) async {
    items[item.id] = item;
  }

  Future<void> putGroup(LocalMediaGroup group) async {
    groups[group.id] = group;
  }

  /// 删条目并回收空合集；返回被删掉的条目（用于删文件）
  List<LocalMediaItem> removeItems(Iterable<String> ids) {
    final removed = <LocalMediaItem>[];
    for (final id in ids) {
      final item = items.remove(id);
      if (item == null) continue;
      removed.add(item);
      final group = groups[item.groupId];
      if (group != null) {
        group.itemIds.remove(id);
        group.updatedAt = DateTime.now().millisecondsSinceEpoch;
        if (group.itemIds.isEmpty) groups.remove(group.id);
      }
    }
    // 封面是否还有引用：没有引用的封面由调用方按返回值判断删除
    return removed;
  }

  /// 该封面是否还有别的合集/条目在用（删除时决定要不要连封面一起删）
  bool posterInUse(String posterPath, {String? exceptGroupId}) {
    for (final g in groups.values) {
      if (g.id == exceptGroupId) continue;
      if (g.posterPath == posterPath || g.fallbackPosterPath == posterPath) return true;
    }
    return false;
  }

  Future<void> putTask(OfflineTaskRecord task) async {
    tasks[task.itemId] = task;
  }

  void removeTask(String itemId) {
    tasks.remove(itemId);
  }

  // ---------------------------------------------------------------- IO

  Future<List<Map<String, dynamic>>> _read(File file) async {
    try {
      if (!await file.exists()) return const <Map<String, dynamic>>[];
      return IndexFile.decode(await file.readAsString());
    } catch (_) {
      // 半截 JSON / 权限问题：当成空索引，交给 reconcile 自愈
      return const <Map<String, dynamic>>[];
    }
  }

  /// 原子写：先写 `.tmp` 再 rename。
  ///
  /// Dart 的 `File.rename` 在 Windows 上走 `MoveFileEx(REPLACE_EXISTING)`，
  /// 目标已存在也能一次替换 —— 不会出现「删了旧的、新的没写进去」的窗口。
  Future<void> _writeAtomic(File file, String content) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(file.path);
  }
}
