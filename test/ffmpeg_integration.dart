import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import '../lib/project.dart';
import '../lib/ffmpeg_plan.dart';

Future<void> run(List<String> args) async {
  final r = await Process.run('ffmpeg', ['-v', 'error', ...args]);
  if (r.exitCode != 0) throw StateError(r.stderr.toString());
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('pcut-render-');
  try {
    final video = '${dir.path}/input.mp4',
        image = '${dir.path}/photo.png',
        sound = '${dir.path}/music.wav',
        overlay = '${dir.path}/overlay.png';
    await run([
      '-f',
      'lavfi',
      '-i',
      'testsrc2=s=160x120:r=30',
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
      video,
    ]);
    await run([
      '-f',
      'lavfi',
      '-i',
      'color=blue:s=160x120',
      '-frames:v',
      '1',
      '-threads',
      '1',
      image,
    ]);
    await run([
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=880:sample_rate=48000',
      '-t',
      '3',
      sound,
    ]);
    await run([
      '-f',
      'lavfi',
      '-i',
      'color=red:s=480x480',
      '-frames:v',
      '1',
      '-threads',
      '1',
      overlay,
    ]);
    final p = Project(
      id: 'render',
      ratio: 1,
      height: 480,
      clips: [
        Clip(
          id: 'v',
          path: video,
          kind: 'video',
          sourceDuration: 2,
          start: .2,
          end: 1.8,
          speed: 2,
          rotation: 1,
          brightness: .1,
          contrast: .1,
          filter: 'mono',
        ),
        Clip(id: 'i', path: image, kind: 'image', sourceDuration: 2, end: 1),
      ],
      layers: [Layer(id: 'l', kind: 'rectangle', start: .3, end: .6)],
      audio: [
        AudioTrack(
          id: 'a',
          path: sound,
          sourceDuration: 3,
          start: .4,
          inPoint: .2,
          length: 1,
          volume: .2,
        ),
      ],
    );
    p.validate(exporting: true);
    final files = <String>[];
    for (var i = 0; i < p.clips.length; i++) {
      final out = '${dir.path}/clip-$i.mp4';
      files.add(out);
      await run(clipArguments(p, p.clips[i], out, hasAudio: i == 0));
    }
    final list = File('${dir.path}/concat.txt');
    await list.writeAsString(concatManifest(files));
    final output = '${dir.path}/out.mp4';
    await run(finishArguments(p, list.path, {'l': overlay}, output));
    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_streams',
      '-show_format',
      '-of',
      'json',
      output,
    ]);
    if (probe.exitCode != 0) throw StateError(probe.stderr.toString());
    final info = jsonDecode(probe.stdout.toString()) as Map;
    final streams = info['streams'] as List;
    final v = streams.firstWhere((s) => s['codec_type'] == 'video');
    if (v['width'] != 480 ||
        v['height'] != 480 ||
        !streams.any((s) => s['codec_type'] == 'audio'))
      throw StateError('Invalid output tracks');
    final duration = double.parse(info['format']['duration']);
    if ((duration - p.duration).abs() > .12)
      throw StateError('Duration drift: $duration');
    // Sample center pixel before, during and after the timed red overlay.
    Future<List<int>> pixel(double t) async {
      final r = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-ss',
        '$t',
        '-i',
        output,
        '-vf',
        'crop=2:2:240:240,scale=1:1',
        '-frames:v',
        '1',
        '-f',
        'rawvideo',
        '-pix_fmt',
        'rgb24',
        'pipe:1',
      ], stdoutEncoding: null);
      if (r.exitCode != 0) throw StateError('Could not sample overlay');
      return r.stdout as List<int>;
    }

    final before = await pixel(.1),
        during = await pixel(.4),
        after = await pixel(1.2);
    if (!(during[0] > 200 && during[1] < 40 && during[2] < 40))
      throw StateError('Timed overlay missing');
    if (before[0] > 200 && before[1] < 40 && before[2] < 40)
      throw StateError('Overlay began early');
    if (!(after[2] > 150 && after[0] < 60))
      throw StateError('Photo or overlay end failed');
    Future<double> audioRms(double t) async {
      final r = await Process.run('ffmpeg', [
        '-v',
        'error',
        '-ss',
        '$t',
        '-i',
        output,
        '-t',
        '0.12',
        '-vn',
        '-ac',
        '1',
        '-ar',
        '8000',
        '-f',
        'f32le',
        'pipe:1',
      ], stdoutEncoding: null);
      if (r.exitCode != 0)
        throw StateError('Could not inspect mixed audio: ${r.stderr}');
      final bytes = Uint8List.fromList(r.stdout as List<int>),
          data = ByteData.sublistView(bytes);
      var squares = 0.0;
      for (var i = 0; i + 4 <= data.lengthInBytes; i += 4) {
        final v = data.getFloat32(i, Endian.little);
        squares += v * v;
      }
      return math.sqrt(squares / math.max(1, data.lengthInBytes ~/ 4));
    }

    if (await audioRms(1.05) < .005)
      throw StateError('Imported music was not mixed into photo segment');
    if (await audioRms(1.6) > .005)
      throw StateError('Music continued after its trimmed timeline interval');
    print(
      'Actual FFmpeg render passed: concat, image, trim, speed, rotate, colour, audio mix, timed overlay, dimensions, duration.',
    );
  } finally {
    await dir.delete(recursive: true);
  }
}
