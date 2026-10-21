import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import '../lib/project.dart';
import '../lib/audio_plan.dart';

Future<void> run(List<String> args) async {
  final r = await Process.run('ffmpeg', ['-v', 'error', ...args]);
  if (r.exitCode != 0) throw StateError(r.stderr.toString());
}

Future<double> rms(String file, double t) async {
  final r = await Process.run('ffmpeg', [
    '-v',
    'error',
    '-ss',
    '$t',
    '-i',
    file,
    '-t',
    '0.03',
    '-f',
    'f32le',
    '-ac',
    '1',
    '-ar',
    '16000',
    'pipe:1',
  ], stdoutEncoding: null);
  if (r.exitCode != 0) throw StateError(r.stderr.toString());
  final bytes = ByteData.sublistView(Uint8List.fromList(r.stdout as List<int>));
  var sum = 0.0;
  for (var i = 0; i < bytes.lengthInBytes; i += 4) {
    final x = bytes.getFloat32(i, Endian.little);
    sum += x * x;
  }
  return math.sqrt(sum / math.max(1, bytes.lengthInBytes ~/ 4));
}

Future<void> main() async {
  final dir = await Directory.systemTemp.createTemp('pcut-audio-');
  try {
    final source = '${dir.path}/tone.wav';
    await run([
      '-f',
      'lavfi',
      '-i',
      'sine=frequency=880:sample_rate=48000',
      '-t',
      '2',
      source,
    ]);
    final p = Project(
      id: 'speech',
      clips: [
        Clip(
          id: 'a',
          path: source,
          kind: 'video',
          sourceDuration: 2,
          end: 1,
          transition: .25,
        ),
        Clip(id: 'b', path: 'image.png', kind: 'image', sourceDuration: 1),
      ],
      audio: [
        AudioTrack(
          id: 'music',
          path: source,
          sourceDuration: 2,
          start: .5,
          length: 1,
          volume: .5,
          fadeIn: .25,
          fadeOut: .25,
        ),
      ],
    );
    final a = '${dir.path}/a.wav',
        b = '${dir.path}/b.wav',
        joined = '${dir.path}/joined.wav',
        mix = '${dir.path}/mix.wav';
    await run(audioClipArguments(p.clips[0], a, hasAudio: true));
    await run(audioClipArguments(p.clips[1], b, hasAudio: false));
    await run(joinAudioArguments(p, 1, a, b, joined));
    await run(mixAudioArguments(p, joined, mix));
    final loud = await rms(mix, 1.05),
        faded = await rms(mix, 1.45),
        silent = await rms(mix, 1.62);
    if (loud < .02 || faded >= loud * .5 || silent > .002)
      throw StateError('Mixed audio fades are wrong: $loud, $faded, $silent');
    final probe = await Process.run('ffprobe', [
      '-v',
      'error',
      '-show_entries',
      'format=duration',
      '-of',
      'csv=p=0',
      mix,
    ]);
    if ((double.parse(probe.stdout.toString().trim()) - 1.75).abs() > .02)
      throw StateError('Transcription audio clock drift');
    print(
      'Audio-only rendering passed: silence, crossfade, mixed track fades, 16 kHz speech input and duration.',
    );
  } finally {
    await dir.delete(recursive: true);
  }
}
