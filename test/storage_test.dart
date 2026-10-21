import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import '../lib/project.dart';
import '../lib/storage.dart';

void main() {
  test('serialized saves, recovery and media ownership', () async {
    final root = await Directory.systemTemp.createTemp('p-cut-store-');
    final input = await Directory.systemTemp.createTemp('p-cut-source-');
    try {
      final store = ProjectStore(root), first = Project(id: 'local');
      final second = first.copy({'name': 'Saved edit'});
      await Future.wait([store.save(first), store.save(second)]);
      expect((await store.list()).single.name, 'Saved edit');
      await File(
        '${store.directory('local').path}/project.json',
      ).writeAsString('{interrupted');
      expect((await store.list()).single.name, first.name);
      final source = File('${input.path}/sample.bin');
      await source.writeAsBytes(List.generate(65536, (i) => i % 256));
      var progress = 0.0;
      final copied = await store.import(first, source, (p) => progress = p);
      expect(progress, 1);
      expect(await copied.readAsBytes(), await source.readAsBytes());
      await store.delete(first);
      expect(await source.exists(), isTrue);
      expect(await copied.exists(), isFalse);
    } finally {
      await root.delete(recursive: true);
      await input.delete(recursive: true);
    }
  });
}
