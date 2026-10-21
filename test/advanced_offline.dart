import '../lib/project.dart';
import '../lib/subtitles.dart';
import '../lib/ffmpeg_plan.dart';

void check(bool v, String message) {
  if (!v) throw StateError(message);
}

void rejects(void Function() f) {
  try {
    f();
  } on FormatException {
    return;
  }
  throw StateError('Expected invalid input rejection');
}

void main() {
  final p = Project(
    id: 'motion',
    clips: [
      Clip(
        id: 'a',
        path: 'a',
        kind: 'video',
        sourceDuration: 4,
        end: 4,
        transition: 1,
      ),
      Clip(
        id: 'b',
        path: 'b',
        kind: 'video',
        sourceDuration: 4,
        end: 4,
        transition: 1,
      ),
      Clip(id: 'c', path: 'c', kind: 'image', sourceDuration: 4, end: 4),
    ],
  );
  p.validate(exporting: true);
  check(
    p.duration == 10 && p.offset(1) == 3 && p.offset(2) == 6,
    'Overlap-aware clock',
  );
  check(p.activeClips(3.5).join(',') == '0,1', 'Two active clips');
  check(
    (p.clipGain(0, 3.5) - .5).abs() < .0001 &&
        (p.clipGain(1, 3.5) - .5).abs() < .0001,
    'Audio crossfade',
  );
  final short = Project(
    id: 'short',
    clips: [
      p.clips[0].copy({'end': .4, 'transition': 2}),
      p.clips[1],
    ],
  );
  check(short.overlap(0) == .2, 'Short clips cap overlap');
  final original = Layer(
    id: 'layer',
    kind: 'text',
    start: 2,
    end: 6,
    x: .2,
    y: .3,
    size: .1,
  );
  final layer = original.keyed(6, {
    'x': .8,
    'y': .7,
    'size': .2,
    'rotation': 90,
    'opacity': 0,
  });
  final middle = layer.at(4);
  check(
    (middle.x - .5).abs() < .00001 &&
        (middle.opacity - .5).abs() < .00001 &&
        middle.rotation == 45,
    'Interpolated transform',
  );
  check(layer.at(-5).x == .2 && layer.at(20).x == .8, 'Endpoint holds');
  final replaced = layer.keyed(6, {'x': .7});
  check(replaced.keys.length == 2, 'Key replacement');
  final smooth = layer.copy({'easing': 'smooth'});
  check(smooth.at(3).x < layer.at(3).x, 'Smooth interpolation');
  rejects(
    () => p.copy({
      'layers': [
        layer.copy({
          'keys': [layer.keys.last.toJson(), layer.keys.first.toJson()],
        }).toJson(),
      ],
    }).validate(),
  );
  final audio = AudioTrack(
    id: 'track',
    path: 'a',
    sourceDuration: 10,
    start: 1,
    length: 4,
    volume: .8,
    fadeIn: 1,
    fadeOut: 1,
  );
  check(
    audio.gainAt(.5) == 0 &&
        (audio.gainAt(1.5) - .4).abs() < .00001 &&
        (audio.gainAt(4.5) - .4).abs() < .00001,
    'Audio envelopes',
  );
  final text =
      '\uFEFF1\r\n00:00:00,200 --> 00:00:01,000\r\nHello <i>Pulse</i>\r\n\r\n2\r\n00:00:01,500 --> 00:00:02,000\r\nP-cut\r\n';
  final cues = parseSrt(text);
  check(cues.length == 2 && cues.first.text == 'Hello Pulse', 'SRT import');
  check(parseSrt(writeSrt(cues)).last.end == 2, 'SRT round trip');
  rejects(
    () => parseSrt(
      '1\n00:00:00,000 --> 00:00:02,000\nOne\n\n2\n00:00:01,000 --> 00:00:03,000\nOverlap',
    ),
  );
  rejects(() => parseSrt('1\n00:60:00,000 --> 00:60:01,000\nInvalid'));
  final roundtrip = Project.fromJson(
    p.copy({
      'captions': cues.map((c) => c.toJson()).toList(),
      'layers': [layer.toJson()],
    }).toJson(),
  );
  check(
    roundtrip.captions.length == 2 && roundtrip.layers.single.keys.length == 2,
    'New fields persist',
  );
  check(
    motionExpression(layer, 'x').contains('if(lt'),
    'Piecewise renderer expression',
  );
  print('Crossfade clocks, keyframes, audio envelopes and subtitles passed.');
}
