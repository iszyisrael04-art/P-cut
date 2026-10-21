import 'dart:io';
import '../lib/project.dart';
import '../lib/subtitles.dart';
import '../lib/ffmpeg_plan.dart';

Future<void> run(List<String> args) async {
  final r = await Process.run('ffmpeg', ['-v', 'error', ...args]);
  if (r.exitCode != 0) throw StateError(r.stderr.toString());
}

Future<List<int>> pixel(
  String file,
  double t, {
  int x = 240,
  int y = 240,
}) async {
  final r = await Process.run('ffmpeg', [
    '-v',
    'error',
    '-ss',
    '$t',
    '-i',
    file,
    '-vf',
    'crop=2:2:$x:$y,scale=1:1',
    '-frames:v',
    '1',
    '-f',
    'rawvideo',
    '-pix_fmt',
    'rgb24',
    'pipe:1',
  ], stdoutEncoding: null);
  if (r.exitCode != 0 || (r.stdout as List<int>).length < 3)
    throw StateError('Frame sampling failed: ${r.stderr}');
  return r.stdout as List<int>;
}

void check(bool value, String why) {
  if (!value) throw StateError(why);
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp("pcut Agent's animation-");
  try {
    final red = '${dir.path}/red.mp4',
        blue = '${dir.path}/blue.mp4',
        tile = '${dir.path}/tile.png',
        blank = '${dir.path}/blank.png';
    await run([
      '-f',
      'lavfi',
      '-i',
      'color=red:s=480x480:r=30',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=440:sample_rate=48000',
      '-t',
      '2',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      red,
    ]);
    await run([
      '-f',
      'lavfi',
      '-i',
      'color=blue:s=480x480:r=30',
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=880:sample_rate=48000',
      '-t',
      '2',
      '-c:v',
      'libx264',
      '-pix_fmt',
      'yuv420p',
      '-c:a',
      'aac',
      blue,
    ]);
    await run([
      '-f',
      'lavfi',
      '-i',
      'color=lime:s=40x40,format=rgba,pad=480:480:220:220:color=black@0',
      '-frames:v',
      '1',
      '-threads',
      '1',
      tile,
    ]);
    await run([
      '-f',
      'lavfi',
      '-i',
      'color=black@0:s=480x480,format=rgba',
      '-frames:v',
      '1',
      '-threads',
      '1',
      blank,
    ]);
    final layer = Layer(
      id: 'moving',
      kind: 'rectangle',
      start: 0,
      end: 3,
      size: .1,
      x: .2,
    ).keyed(3, {'x': .8});
    final p = Project(
      id: 'render-motion',
      ratio: 1,
      height: 480,
      clips: [
        Clip(
          id: 'red',
          path: red,
          kind: 'video',
          sourceDuration: 2,
          transition: 1,
        ),
        Clip(id: 'blue', path: blue, kind: 'video', sourceDuration: 2),
      ],
      layers: [layer],
    );
    p.validate(exporting: true);
    final first = '${dir.path}/first.mp4',
        second = '${dir.path}/second.mp4',
        joined = '${dir.path}/joined.mp4';
    await run(clipArguments(p, p.clips[0], first, hasAudio: true));
    await run(clipArguments(p, p.clips[1], second, hasAudio: true));
    await run(joinArguments(p, 1, first, second, joined));
    final middle = await pixel(joined, 1.5);
    check(
      middle[0] > 80 && middle[2] > 80 && middle[1] < 35,
      'Crossfade must mix red and blue',
    );
    final before = await pixel(joined, .2), after = await pixel(joined, 2.7);
    check(
      before[0] > 200 && before[2] < 30 && after[2] > 200 && after[0] < 30,
      'Crossfade endpoints',
    );
    final manifest = File('${dir.path}/concat.txt');
    await manifest.writeAsString(concatManifest([joined]));
    final animated = '${dir.path}/animated.mp4';
    await run(finishArguments(p, manifest.path, {'moving': tile}, animated));
    final moved = await pixel(animated, 2.8, x: 365),
        old = await pixel(animated, 2.8, x: 105);
    check(
      moved[1] > 120 && moved[0] < 80 && old[2] > 150,
      'Layer motion was not exported: moved=$moved old=$old',
    );
    // Opacity, rotation and scale use the same keyframes, rather than a preview-only change.
    final faded = layer.copy({
      'keys': [
        ...layer.keys.map(
          (k) => {...k.toJson(), 'rotation': 45.0, 'size': .14, 'opacity': .5},
        ),
      ],
    });
    final styled = '${dir.path}/styled.mp4';
    await run(
      finishArguments(
        p.copy({
          'layers': [faded.toJson()],
        }),
        manifest.path,
        {'moving': tile},
        styled,
      ),
    );
    final partial = await pixel(styled, 2.8, x: 365);
    check(
      partial[1] > 50 && partial[1] < 200 && partial[2] > 50,
      'Layer opacity/rotation/scale failed',
    );
    final morph = layer.keyed(3, {
      'x': .8,
      'size': .2,
      'rotation': 90,
      'opacity': 0,
    });
    final morphFile = '${dir.path}/morph.mp4';
    await run(
      finishArguments(
        p.copy({
          'layers': [morph.toJson()],
        }),
        manifest.path,
        {'moving': tile},
        morphFile,
      ),
    );
    final bright = await pixel(morphFile, .5, x: 144),
        dim = await pixel(morphFile, 2.7, x: 355);
    check(
      bright[1] > 140 && dim[1] < bright[1] * .4 && dim[2] > 120,
      'Animated opacity/scale/rotation failed: $bright $dim',
    );
    // Subtitle video is one lossless alpha track, not hundreds of simultaneous inputs.
    final captions = [
      const SubtitleCue(id: 'cue', start: .4, end: .8, text: 'Test'),
    ];
    final cp = p.copy({
      'layers': [],
      'captions': captions.map((c) => c.toJson()).toList(),
    });
    final capList = File('${dir.path}/captions.txt');
    await capList.writeAsString(
      captionManifest(cp, {'caption:cue': tile, 'caption:blank': blank}),
    );
    final capVideo = '${dir.path}/captions.mkv';
    await run(captionArguments(cp, capList.path, capVideo));
    final finalVideo = '${dir.path}/captioned.mp4';
    await run(
      finishArguments(
        cp,
        manifest.path,
        {},
        finalVideo,
        captionVideo: capVideo,
      ),
    );
    final capOn = await pixel(finalVideo, .6),
        capOff = await pixel(finalVideo, 1.0);
    check(capOn[1] > 120 && capOff[1] < 40, 'Subtitle alpha timing failed');
    print(
      'Actual advanced render passed: crossfade colours, moving/scaled/rotated/transparent layer, subtitle timing and alpha.',
    );
  } finally {
    await dir.delete(recursive: true);
  }
}
