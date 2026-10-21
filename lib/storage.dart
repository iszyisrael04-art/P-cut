import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'project.dart';

class ProjectStore {
  ProjectStore(this.root);
  final Directory root;
  Future<void> _writes = Future.value();
  static Future<ProjectStore> open() async {
    final doc = await getApplicationDocumentsDirectory();
    final root = Directory('${doc.path}/P-cut');
    await root.create(recursive: true);
    return ProjectStore(root);
  }

  Directory directory(String id) => Directory('${root.path}/$id');
  Future<void> save(Project p) {
    final operation = _writes.catchError((_) {}).then((_) async {
      p.validate();
      final dir = directory(p.id);
      await dir.create(recursive: true);
      final target = File('${dir.path}/project.json'),
          temp = File('${dir.path}/project.next');
      final backup = File('${dir.path}/project.backup');
      await temp.writeAsString(encodeProject(p), flush: true);
      if (await backup.exists()) await backup.delete();
      if (await target.exists()) await target.rename(backup.path);
      try {
        await temp.rename(target.path);
      } catch (_) {
        if (await backup.exists()) await backup.rename(target.path);
        rethrow;
      }
    });
    _writes = operation;
    return operation;
  }

  Future<List<Project>> list() async {
    final list = <Project>[];
    await for (final d in root.list()) {
      if (d is! Directory) continue;
      for (final name in ['project.json', 'project.backup']) {
        try {
          final p = Project.fromJson(
            jsonDecode(await File('${d.path}/$name').readAsString()),
          );
          list.add(p);
          break;
        } catch (_) {}
      }
    }
    return list.reversed.toList();
  }

  Future<File> import(
    Project p,
    File source,
    void Function(double) progress,
  ) async {
    final media = Directory('${directory(p.id).path}/media');
    await media.create(recursive: true);
    final name = source.path.replaceAll('\\', '/').split('/').last;
    final dot = name.lastIndexOf('.');
    final ext = dot >= 0 ? name.substring(dot).toLowerCase() : '';
    final dest = File(
      '${media.path}/${newId()}${ext.replaceAll(RegExp(r'[^.a-z0-9]'), '')}',
    );
    final sink = dest.openWrite();
    final total = await source.length();
    var done = 0;
    try {
      await for (final data in source.openRead()) {
        sink.add(data);
        done += data.length;
        progress(total == 0 ? 0 : done / total);
      }
      await sink.flush();
      await sink.close();
      return dest;
    } catch (_) {
      await sink.close();
      if (await dest.exists()) await dest.delete();
      rethrow;
    }
  }

  Future<void> delete(Project p) async {
    await _writes.catchError((_) {});
    final d = directory(p.id);
    if (await d.exists()) await d.delete(recursive: true);
  }
}
