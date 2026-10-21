import 'dart:convert';
import '../lib/project.dart';
import '../lib/ffmpeg_plan.dart';

void check(bool value, String message) {
  if (!value) throw StateError(message);
}

void rejects(void Function() action, String message) {
  try {
    action();
  } on FormatException {
    return;
  }
  throw StateError(message);
}

void main() {
  final a = Clip(
    id: 'a',
    path: 'a.mp4',
    kind: 'video',
    sourceDuration: 12,
    start: 2,
    end: 10,
    speed: 2,
  );
  final b = Clip(
    id: 'b',
    path: 'photo.png',
    kind: 'image',
    sourceDuration: 1800,
    end: 3,
  );
  final p = Project(
    id: 'test',
    clips: [a, b],
    layers: [Layer(id: 'layer', kind: 'text', text: 'P-cut', start: 1, end: 5)],
    audio: [
      AudioTrack(
        id: 'sound',
        path: 'sound.wav',
        sourceDuration: 10,
        start: 1,
        length: 3,
      ),
    ],
  );
  p.validate(exporting: true);
  final portrait = Project(id: 'portrait');
  check(
    portrait.width == 720 && portrait.pixelHeight == 1280,
    'Portrait short-edge export resolution',
  );
  check(p.duration == 7, 'Speed-aware duration');
  check(
    p.offset(1) == 4 && p.clipAt(3.99) == 0 && p.clipAt(4) == 1,
    'Clip boundary',
  );
  final split = p.split(0, 1);
  check(split.clips.length == 3, 'Split count');
  check(
    split.duration == p.duration &&
        split.clips.first.end == 4 &&
        split.clips[1].start == 4,
    'Split preserves source and duration',
  );
  check(identical(p.split(0, 0), p), 'Boundary split rejected');
  check(identical(p.split(1, 5), p), 'Photo split rejected');
  final restored = Project.fromJson(jsonDecode(encodeProject(p)));
  check(encodeProject(restored) == encodeProject(p), 'Project round trip');
  final h = ProjectHistory();
  h.push(p);
  check(identical(h.undo(split), p), 'Undo');
  check(identical(h.redo(p), split), 'Redo');
  h.push(p);
  check(!h.canRedo, 'Branch invalidates redo');
  rejects(
    () => p.copy({'height': 800}).validate(),
    'Unknown resolution rejected',
  );
  rejects(
    () => p.copy({
      'clips': [
        a.copy({'speed': 0}).toJson(),
      ],
    }).validate(),
    'Zero speed rejected',
  );
  rejects(
    () => p.copy({
      'clips': [a.toJson(), a.toJson()],
    }).validate(),
    'Duplicate ID rejected',
  );
  rejects(
    () => Project(id: '../escape').validate(),
    'Unsafe project ID rejected',
  );
  rejects(
    () => p.copy({
      'layers': [Layer(id: 'l', kind: 'text', start: 4, end: 2).toJson()],
    }).validate(),
    'Reversed layer rejected',
  );
  rejects(
    () => p.copy({
      'clips': [
        a.copy({'start': double.nan}).toJson(),
      ],
    }).validate(),
    'NaN rejected',
  );
  final args = clipArguments(p, a, 'out.mp4', hasAudio: true);
  check(
    args.contains(a.path) && args.contains('0:a:0'),
    'Paths remain individual arguments',
  );
  check(args[args.indexOf('-t') + 1] == '8.000000', 'Source interval');
  check(
    args.any((x) => x.contains('atempo=2.000000')),
    'Speed exported to audio',
  );
  final silent = clipArguments(p, b, 'image.mp4', hasAudio: false);
  check(
    silent.contains('anullsrc=r=48000:cl=stereo'),
    'Photos get silence for concatenation',
  );
  final finish = finishArguments(p, 'concat.txt', {
    'layer': 'layer.png',
  }, 'finished.mp4');
  check(
    finish.any((x) => x.contains('gte(t,1.000000)*lt(t,5.000000)')),
    'Timed overlays',
  );
  check(finish.any((x) => x.contains('adelay=1000')), 'Music offset');
  check(
    concatManifest([r"C:\Agent's Cut\file.mp4"]).contains("Agent'\\''s"),
    'Concat escaping',
  );
  print('Project, edit history and export-plan checks passed.');
}
