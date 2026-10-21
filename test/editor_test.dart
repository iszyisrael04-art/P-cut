import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../lib/painting.dart';
import '../lib/project.dart';
import 'project_offline.dart' as rules;
import 'advanced_offline.dart' as advanced;

void main() {
  test('project and render rules', rules.main);
  test(
    'keyframes, transition clocks, audio fades and subtitles',
    advanced.main,
  );
  testWidgets('brand and timed graphics paint without media decoding', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Mark(),
              SizedBox(
                width: 200,
                height: 300,
                child: CustomPaint(
                  painter: LayersPainter([
                    Layer(id: 'text', kind: 'text', text: 'P-cut'),
                    Layer(id: 'circle', kind: 'circle', x: .2, y: .3),
                  ]),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(Mark), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('export sprites use the largest key and preserve alpha', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final dir = await Directory.systemTemp.createTemp('pcut-sprite-');
      try {
        final layer = Layer(
          id: 'sprite',
          kind: 'circle',
          size: .1,
          opacity: .2,
        ).keyed(1, {'size': .2});
        final p = Project(
          id: 'sprite-project',
          ratio: 1,
          height: 480,
          layers: [layer],
        );
        final files = await renderLayers(p, dir);
        final codec = await ui.instantiateImageCodec(
          await File(files['sprite']!).readAsBytes(),
        );
        final frame = await codec.getNextFrame();
        try {
          expect(frame.image.width, 224);
          expect(frame.image.height, 224);
          final bytes = await frame.image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          expect(bytes!.getUint8(3), 0);
          expect(bytes.getUint8((112 * 224 + 112) * 4 + 3), 255);
        } finally {
          frame.image.dispose();
          codec.dispose();
        }
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
