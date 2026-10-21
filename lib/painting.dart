import 'dart:math' as math;
import 'dart:ui' as ui;
import 'dart:io';
import 'package:flutter/material.dart';
import 'project.dart';

const accent = Color(0xffc6ff37);
const panel = Color(0xff191b21);

class Mark extends StatelessWidget {
  const Mark({super.key, this.size = 40});
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: accent,
      borderRadius: BorderRadius.circular(size * .27),
    ),
    child: Icon(
      Icons.content_cut_rounded,
      color: Colors.black,
      size: size * .56,
    ),
  );
}

class LayersPainter extends CustomPainter {
  LayersPainter(this.layers, {this.selected, this.time, this.referenceWidth});
  final List<Layer> layers;
  final String? selected;
  final double? time;
  final double? referenceWidth;
  @override
  void paint(Canvas canvas, Size size) {
    for (final source in layers) {
      final motion = time == null ? source.base : source.at(time!);
      final l = source.copy(motion.toJson());
      canvas.save();
      canvas.translate(l.x * size.width, l.y * size.height);
      canvas.rotate(l.rotation * math.pi / 180);
      final faded = l.opacity < 1;
      if (faded)
        canvas.saveLayer(
          null,
          Paint()..color = Colors.white.withValues(alpha: l.opacity),
        );
      final colour = Color(l.color).withValues(alpha: 1);
      final unit = l.size * (referenceWidth ?? size.width);
      Rect bounds;
      if (l.kind == 'text' || l.kind == 'sticker') {
        final text = TextPainter(
          text: TextSpan(
            text: l.text,
            style: TextStyle(
              color: colour,
              fontSize: unit,
              fontWeight: FontWeight.w700,
              shadows: const [
                Shadow(
                  color: Colors.black54,
                  blurRadius: 3,
                  offset: Offset(1, 1),
                ),
              ],
            ),
          ),
          textAlign: TextAlign.center,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: (referenceWidth ?? size.width) * .94);
        bounds = Rect.fromCenter(
          center: Offset.zero,
          width: text.width + 10,
          height: text.height + 10,
        );
        text.paint(canvas, Offset(-text.width / 2, -text.height / 2));
      } else {
        bounds = Rect.fromCenter(
          center: Offset.zero,
          width: unit * 2,
          height: unit * 2,
        );
        final p = Paint()..color = colour;
        if (l.kind == 'circle')
          canvas.drawOval(bounds, p);
        else
          canvas.drawRRect(
            RRect.fromRectAndRadius(bounds, Radius.circular(unit * .15)),
            p,
          );
      }
      if (faded) canvas.restore();
      if (l.id == selected)
        canvas.drawRect(
          bounds.inflate(5),
          Paint()
            ..color = accent
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant LayersPainter old) => true;
}

Future<Map<String, String>> renderLayers(Project p, Directory directory) async {
  final results = <String, String>{};
  for (final l in p.layers) {
    final unit = l.rasterSize * p.width;
    var width = (unit * 2 + 32).ceil(), height = (unit * 2 + 32).ceil();
    if (l.kind == 'text' || l.kind == 'sticker') {
      final measured = TextPainter(
        text: TextSpan(
          text: l.text,
          style: TextStyle(fontSize: unit, fontWeight: FontWeight.w700),
        ),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: p.width * .94);
      width = (measured.width + 32).ceil();
      height = (measured.height + 32).ceil();
    }
    if (width > 4096 || height > 4096)
      throw StateError(
        'A text layer is too large to render safely. Reduce its size or number of lines.',
      );
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    LayersPainter(
      [
        l.copy({
          'x': .5,
          'y': .5,
          'size': l.rasterSize,
          'rotation': 0,
          'opacity': 1,
          'keys': [],
        }),
      ],
      referenceWidth: p.width.toDouble(),
    ).paint(canvas, Size(width.toDouble(), height.toDouble()));
    final picture = recorder.endRecording(),
        image = await picture.toImage(width, height);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('Layer image could not render');
      final path = '${directory.path}/${l.id}.png';
      await File(path).writeAsBytes(bytes.buffer.asUint8List());
      results[l.id] = path;
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
  return results;
}

List<double> colourMatrix(Clip c) {
  final contrast = 1 + c.contrast,
      offset = c.brightness * 255 + 128 * (1 - contrast);
  final base = <double>[
    contrast,
    0,
    0,
    0,
    offset,
    0,
    contrast,
    0,
    0,
    offset,
    0,
    0,
    contrast,
    0,
    offset,
    0,
    0,
    0,
    1,
    0,
  ];
  if (c.filter == 'mono')
    return [
      .2126 * contrast,
      .7152 * contrast,
      .0722 * contrast,
      0,
      offset,
      .2126 * contrast,
      .7152 * contrast,
      .0722 * contrast,
      0,
      offset,
      .2126 * contrast,
      .7152 * contrast,
      .0722 * contrast,
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ];
  if (c.filter == 'warm') {
    base[0] *= 1.12;
    base[12] *= .88;
  }
  if (c.filter == 'cool') {
    base[0] *= .88;
    base[12] *= 1.12;
  }
  return base;
}

class CaptionPainter extends CustomPainter {
  CaptionPainter(this.text);
  final String text;
  @override
  void paint(Canvas canvas, Size size) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.white,
          fontSize: size.width * .052,
          fontWeight: FontWeight.w700,
          height: 1.2,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width * .87);
    final rect = Rect.fromLTWH(
      (size.width - painter.width) / 2 - 10,
      size.height * .88 - painter.height / 2 - 6,
      painter.width + 20,
      painter.height + 12,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = const Color(0xb8000000),
    );
    painter.paint(
      canvas,
      Offset(
        (size.width - painter.width) / 2,
        size.height * .88 - painter.height / 2,
      ),
    );
  }

  @override
  bool shouldRepaint(covariant CaptionPainter old) => old.text != text;
}

Future<Map<String, String>> renderCaptions(
  Project p,
  Directory directory,
) async {
  final files = <String, String>{};
  for (final cue in p.captions) {
    final recorder = ui.PictureRecorder();
    CaptionPainter(cue.text).paint(
      Canvas(recorder),
      Size(p.width.toDouble(), p.pixelHeight.toDouble()),
    );
    final picture = recorder.endRecording(),
        image = await picture.toImage(p.width, p.pixelHeight);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) throw StateError('A subtitle could not render');
      final path = '${directory.path}/${cue.id}.png';
      await File(path).writeAsBytes(bytes.buffer.asUint8List());
      files['caption:${cue.id}'] = path;
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
  // One transparent frame represents all gaps in the subtitle track.
  if (p.captions.isNotEmpty) {
    final recorder = ui.PictureRecorder();
    Canvas(recorder);
    final picture = recorder.endRecording(),
        image = await picture.toImage(p.width, p.pixelHeight);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final path = '${directory.path}/caption-blank.png';
      await File(path).writeAsBytes(bytes!.buffer.asUint8List());
      files['caption:blank'] = path;
    } finally {
      image.dispose();
      picture.dispose();
    }
  }
  return files;
}
