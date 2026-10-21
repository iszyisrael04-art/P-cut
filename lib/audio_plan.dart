import 'project.dart';
import 'ffmpeg_plan.dart' show decimal;

List<String> audioClipArguments(Clip c, String out, {required bool hasAudio}) {
  final silent = c.kind == 'image' || !hasAudio;
  final args = <String>['-hide_banner', '-y'];
  if (silent) {
    args.addAll(['-f', 'lavfi', '-i', 'anullsrc=r=16000:cl=mono']);
  } else {
    args.addAll([
      '-ss',
      decimal(c.start),
      '-t',
      decimal(c.end - c.start),
      '-i',
      c.path,
    ]);
  }
  final filters = <String>['asetpts=PTS-STARTPTS'];
  if (!silent) {
    var speed = c.speed;
    while (speed > 2) {
      filters.add('atempo=2');
      speed /= 2;
    }
    while (speed < .5) {
      filters.add('atempo=0.5');
      speed /= .5;
    }
    filters.add('atempo=${decimal(speed)}');
  }
  filters.add('volume=${decimal(c.volume)}');
  filters.add('apad');
  return [
    ...args,
    '-map',
    '0:a:0',
    '-vn',
    '-af',
    filters.join(','),
    '-t',
    decimal(c.duration),
    '-c:a',
    'pcm_s16le',
    '-ar',
    '16000',
    '-ac',
    '1',
    '-progress',
    'pipe:1',
    '-nostats',
    out,
  ];
}

List<String> joinAudioArguments(
  Project p,
  int index,
  String previous,
  String next,
  String out,
) {
  final d = p.overlap(index - 1),
      filter = d > 0
          ? '[0:a][1:a]acrossfade=d=${decimal(d)}:c1=tri:c2=tri[a]'
          : '[0:a][1:a]concat=n=2:v=0:a=1[a]';
  return [
    '-hide_banner',
    '-y',
    '-i',
    previous,
    '-i',
    next,
    '-filter_complex',
    filter,
    '-map',
    '[a]',
    '-t',
    decimal(p.offset(index) + p.clips[index].duration),
    '-c:a',
    'pcm_s16le',
    '-ar',
    '16000',
    '-ac',
    '1',
    '-progress',
    'pipe:1',
    '-nostats',
    out,
  ];
}

List<String> mixAudioArguments(Project p, String main, String out) {
  final args = <String>['-hide_banner', '-y', '-i', main];
  final filters = <String>[], sources = <String>['[0:a]'];
  for (var i = 0; i < p.audio.length; i++) {
    final a = p.audio[i];
    args.addAll([
      '-ss',
      decimal(a.inPoint),
      '-t',
      decimal(a.length),
      '-i',
      a.path,
    ]);
    filters.add(
      '[${i + 1}:a]asetpts=PTS-STARTPTS,volume=${decimal(a.volume)}${a.fadeIn > 0 ? ',afade=t=in:d=${decimal(a.fadeIn)}' : ''}${a.fadeOut > 0 ? ',afade=t=out:st=${decimal(a.length - a.fadeOut)}:d=${decimal(a.fadeOut)}' : ''},adelay=${(a.start * 1000).round()}:all=1[a$i]',
    );
    sources.add('[a$i]');
  }
  if (p.audio.isNotEmpty) {
    filters.add(
      '${sources.join()}amix=inputs=${sources.length}:duration=first:normalize=0,alimiter=limit=0.95:latency=1[mix]',
    );
    args.addAll(['-filter_complex', filters.join(';'), '-map', '[mix]']);
  } else {
    args.addAll(['-map', '0:a']);
  }
  return [
    ...args,
    '-t',
    decimal(p.duration),
    '-ar',
    '16000',
    '-ac',
    '1',
    '-c:a',
    'pcm_s16le',
    '-progress',
    'pipe:1',
    '-nostats',
    out,
  ];
}
