import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:nas_ui/nas_ui.dart';

/// 相册单张下载（桌面 / 移动端）：弹保存对话框 → 流式写入 → 落地再改名。
///
/// 为什么先写 `.part` 再 rename：下载中断会留下半张图，用户下次打开是坏的，
/// 而 rename 在同一分区是原子的，坏文件不会以"正经文件名"出现。
class PhotoDownload {
  PhotoDownload._();

  static bool get supported => true;

  /// 批量下载是否可用：只有能弹「选文件夹」的桌面端才行，
  /// 移动端该接口未实现，调用方要退回到「复制下载链接」。
  static bool get folderBatch => Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  /// 返回保存路径；用户取消返回 null。
  static Future<String?> save({
    required String url,
    required Map<String, String> headers,
    required String suggestedName,
  }) async {
    final location = await getSaveLocation(suggestedName: suggestedName);
    if (location == null) return null;
    final target = File(location.path);
    final part = File('${location.path}.part');
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse(url));
      headers.forEach(req.headers.set);
      final res = await req.close();
      if (res.statusCode != 200) {
        throw HttpException('HTTP ${res.statusCode}');
      }
      final sink = part.openWrite();
      await res.pipe(sink);
      await sink.close();
      if (await part.length() == 0) {
        await part.delete();
        throw const HttpException('empty body');
      }
      await part.rename(target.path);
      return target.path;
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {
        /* 清临时文件失败不影响报错 */
      }
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// 批量下载：只弹一次「选文件夹」，逐个写入，不再为每张图弹一次另存为。
  ///
  /// 返回 `null` = 用户取消选目录；单个文件失败不打断整批（网络抖动很常见），
  /// 成功 / 失败数分别带回，由调用方汇总成一句提示。
  static Future<({int saved, int failed})?> saveAll({
    required List<({String url, String name})> files,
    required Map<String, String> headers,
    void Function(int done, int total)? onProgress,
  }) async {
    if (files.isEmpty) return (saved: 0, failed: 0);
    final dir = await getDirectoryPath(confirmButtonText: tr('common.select'));
    if (dir == null) return null;
    final client = HttpClient();
    var saved = 0;
    var failed = 0;
    try {
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        try {
          final target = _uniqueFile(dir, f.name);
          final part = File('${target.path}.part');
          final req = await client.getUrl(Uri.parse(f.url));
          headers.forEach(req.headers.set);
          final res = await req.close();
          if (res.statusCode != 200) {
            throw HttpException('HTTP ${res.statusCode}');
          }
          final sink = part.openWrite();
          await res.pipe(sink);
          await sink.close();
          if (await part.length() == 0) {
            await part.delete();
            throw const HttpException('empty body');
          }
          await part.rename(target.path);
          saved += 1;
        } catch (_) {
          failed += 1;
        }
        onProgress?.call(i + 1, files.length);
      }
    } finally {
      client.close(force: true);
    }
    return (saved: saved, failed: failed);
  }

  /// 重名不覆盖：目标已存在就写 `名字 (1).xxx`
  static File _uniqueFile(String dir, String name) {
    final safe = _safeName(name);
    final sep = Platform.pathSeparator;
    var f = File('$dir$sep$safe');
    if (!f.existsSync()) return f;
    final dot = safe.lastIndexOf('.');
    final stem = dot > 0 ? safe.substring(0, dot) : safe;
    final ext = dot > 0 ? safe.substring(dot) : '';
    for (var i = 1; i < 1000; i++) {
      f = File('$dir$sep$stem ($i)$ext');
      if (!f.existsSync()) return f;
    }
    return f;
  }

  /// Windows 文件名不允许 `<>:"/\|?*` 与控制字符，直接拿标题落盘会写失败
  static String _safeName(String name) {
    final s = name.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '_').trim();
    return s.isEmpty ? 'download' : s;
  }
}
