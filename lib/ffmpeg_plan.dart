import 'project.dart';

String decimal(num n) => n.toStringAsFixed(6);

/// Each input is normalized before concatenation. No shell evaluation is used.
List<String> clipArguments(
  Project p,
  Clip c,
  String output, {
  required bool hasAudio,
}) {
  final args = <String>['-hide_banner', '-y'];
  if (c.kind == 'image') {
    args.addAll(['-loop', '1', '-framerate', '30', '-i', c.path]);
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
  final silence = c.kind == 'image' || !hasAudio;
  if (silence) args.addAll(['-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo']);
  final v = <String>[];
  for (var i = 0; i < c.rotation; i++) {
    v.add('transpose=1');
  }
  if (c.fit == 'cover') {
    v.add(
      'scale=${p.width}:${p.pixelHeight}:force_original_aspect_ratio=increase',
    );
    v.add('crop=${p.width}:${p.pixelHeight}');
  } else {
    v.add(
      'scale=${p.width}:${p.pixelHeight}:force_original_aspect_ratio=decrease',
    );
    v.add('pad=${p.width}:${p.pixelHeight}:(ow-iw)/2:(oh-ih)/2:black');
  }
  v.add('setsar=1');
  v.add('setpts=(PTS-STARTPTS)/${decimal(c.speed)}');
  v.add('fps=30');
  v.add(
    'eq=brightness=${decimal(c.brightness)}:contrast=${decimal(1 + c.contrast)}',
  );
  if (c.filter == 'mono') v.add('hue=s=0');
  if (c.filter == 'warm') v.add('colorchannelmixer=rr=1.12:bb=0.88');
  if (c.filter == 'cool') v.add('colorchannelmixer=rr=0.88:bb=1.12');
  final a = <String>['asetpts=PTS-STARTPTS'];
  if (!silence) {
    var speed = c.speed;
    while (speed > 2) {
      a.add('atempo=2');
      speed /= 2;
    }
    while (speed < .5) {
      a.add('atempo=0.5');
      speed /= .5;
    }
    a.add('atempo=${decimal(speed)}');
  }
  a.add('volume=${decimal(c.volume)}');
  a.add('apad');
  args.addAll([
    '-map',
    '0:v:0',
    '-map',
    silence ? '1:a:0' : '0:a:0',
    '-vf',
    v.join(','),
    '-af',
    a.join(','),
    '-t',
    decimal(c.duration),
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '20',
    '-pix_fmt',
    'yuv420p',
    '-c:a',
    'aac',
    '-ar',
    '48000',
    '-ac',
    '2',
    '-movflags',
    '+faststart',
    '-progress',
    'pipe:1',
    '-nostats',
    output,
  ]);
  return args;
}

String concatManifest(List<String> files) => files
    .map((f) => "file '${f.replaceAll('\\', '/').replaceAll("'", "'\\''")}'")
    .join('\n');

List<String> finishArguments(
  Project p,
  String manifest,
  Map<String, String> overlays,
  String output, {
  String? captionVideo,
}) {
  final args = <String>[
    '-hide_banner',
    '-y',
    '-f',
    'concat',
    '-safe',
    '0',
    '-i',
    manifest,
  ];
  for (final layer in p.layers) {
    args.addAll(['-loop', '1', '-framerate', '30', '-i', overlays[layer.id]!]);
  }
  for (final a in p.audio) {
    args.addAll([
      '-ss',
      decimal(a.inPoint),
      '-t',
      decimal(a.length),
      '-i',
      a.path,
    ]);
  }
  if (captionVideo != null) args.addAll(['-i', captionVideo]);
  final filters = <String>[];
  var previous = '0:v:0';
  for (var i = 0; i < p.layers.length; i++) {
    final l = p.layers[i], out = 'v$i';
    final x = motionExpression(l, 'x'), y = motionExpression(l, 'y');
    final animated = l.keys.isNotEmpty;
    final transform = <String>['format=rgba'];
    final poses = l.keys.isEmpty ? [l.base] : l.keys;
    final geometry = poses.any(
      (k) => k.rotation != 0 || (k.size - l.rasterSize).abs() > .00001,
    );
    if (geometry) {
      // Constant-size affine projection: evaluate transform once per frame, not per pixel.
      transform.add(
        "pad=w='ceil(hypot(iw,ih))':h='ceil(hypot(iw,ih))':x=(ow-iw)/2:y=(oh-ih)/2:color=black@0",
      );
      final scale =
          '(${motionExpression(l, 'size', clock: 'on/30')}/${decimal(l.rasterSize)})';
      final angle =
          '(${motionExpression(l, 'rotation', clock: 'on/30')}*PI/180)';
      final corners = <String>[];
      for (var corner = 0; corner < 4; corner++) {
        final u = corner % 2 == 0 ? '(-W/2)' : '(W/2)',
            v = corner < 2 ? '(-H/2)' : '(H/2)';
        corners.add("x$corner='W/2+$scale*(cos($angle)*$u-sin($angle)*$v)'");
        corners.add("y$corner='H/2+$scale*(sin($angle)*$u+cos($angle)*$v)'");
      }
      transform.add(
        'perspective=${corners.join(':')}:sense=destination:eval=frame',
      );
    }
    if (animated && l.keys.any((k) => k.opacity != l.keys.first.opacity)) {
      final alpha = motionExpression(l, 'opacity', clock: 'T');
      transform.add(
        "geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='alpha(X,Y)*($alpha)'",
      );
    } else {
      transform.add('colorchannelmixer=aa=${decimal(poses.first.opacity)}');
    }
    filters.add('[${i + 1}:v:0]${transform.join(',')}[layer$i]');
    filters.add(
      "[$previous][layer$i]overlay=x='${p.width}*($x)-overlay_w/2':y='${p.pixelHeight}*($y)-overlay_h/2':eval=frame:enable='gte(t,${decimal(l.start)})*lt(t,${decimal(l.end)})':shortest=0[$out]",
    );
    previous = out;
  }
  if (captionVideo != null) {
    filters.add(
      '[$previous][${1 + p.layers.length + p.audio.length}:v:0]overlay=0:0:eof_action=pass[captioned]',
    );
    previous = 'captioned';
  }
  final sounds = <String>['[0:a:0]'];
  for (var i = 0; i < p.audio.length; i++) {
    final a = p.audio[i], index = 1 + p.layers.length + i;
    filters.add(
      '[$index:a:0]asetpts=PTS-STARTPTS,volume=${decimal(a.volume)}${a.fadeIn > 0 ? ',afade=t=in:st=0:d=${decimal(a.fadeIn)}' : ''}${a.fadeOut > 0 ? ',afade=t=out:st=${decimal(a.length - a.fadeOut)}:d=${decimal(a.fadeOut)}' : ''},adelay=${(a.start * 1000).round()}:all=1[a$i]',
    );
    sounds.add('[a$i]');
  }
  if (p.audio.isNotEmpty)
    filters.add(
      '${sounds.join()}amix=inputs=${sounds.length}:duration=first:normalize=0,alimiter=limit=0.95:latency=1[mix]',
    );
  if (filters.isNotEmpty)
    args.addAll([
      '-filter_complex_threads',
      '1',
      '-filter_complex',
      filters.join(';'),
    ]);
  args.addAll([
    '-map',
    p.layers.isEmpty && captionVideo == null ? '0:v:0' : '[$previous]',
    '-map',
    p.audio.isEmpty ? '0:a:0' : '[mix]',
    '-t',
    decimal(p.duration),
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '20',
    '-pix_fmt',
    'yuv420p',
    '-r',
    '30',
    '-c:a',
    'aac',
    '-ar',
    '48000',
    '-ac',
    '2',
    '-movflags',
    '+faststart',
    '-progress',
    'pipe:1',
    '-nostats',
    output,
  ]);
  return args;
}

/// Join two normalized files. Pairwise rendering bounds decoder memory.
List<String> joinArguments(
  Project p,
  int index,
  String previous,
  String next,
  String output,
) {
  final d = p.overlap(index - 1),
      end = p.offset(index) + p.clips[index].duration;
  final graph = d > 0
      ? '[0:v]settb=AVTB,setpts=PTS-STARTPTS[v0];[1:v]settb=AVTB,setpts=PTS-STARTPTS[v1];[v0][v1]xfade=transition=fade:duration=${decimal(d)}:offset=${decimal(p.offset(index))}[v];[0:a][1:a]acrossfade=d=${decimal(d)}:c1=tri:c2=tri[a]'
      : '[0:v][0:a][1:v][1:a]concat=n=2:v=1:a=1[v][a]';
  return [
    '-hide_banner',
    '-y',
    '-i',
    previous,
    '-i',
    next,
    '-filter_complex_threads',
    '1',
    '-filter_complex',
    graph,
    '-map',
    '[v]',
    '-map',
    '[a]',
    '-t',
    decimal(end),
    '-c:v',
    'libx264',
    '-preset',
    'veryfast',
    '-crf',
    '20',
    '-pix_fmt',
    'yuv420p',
    '-r',
    '30',
    '-c:a',
    'aac',
    '-ar',
    '48000',
    '-ac',
    '2',
    '-progress',
    'pipe:1',
    '-nostats',
    output,
  ];
}

String motionExpression(Layer layer, String property, {String clock = 't'}) {
  double value(MotionKey k) => (k.toJson()[property] as num).toDouble();
  final keys = layer.keys.isEmpty ? [layer.base] : layer.keys;
  var expr = decimal(value(keys.last));
  for (var i = keys.length - 2; i >= 0; i--) {
    final a = keys[i], b = keys[i + 1];
    final t =
        '(($clock-${decimal(layer.start + a.time)})/${decimal(b.time - a.time)})';
    final u = layer.easing == 'smooth' ? '($t*$t*(3-2*$t))' : t;
    final interpolated =
        '(${decimal(value(a))}+${decimal(value(b) - value(a))}*$u)';
    expr =
        'if(lt($clock,${decimal(layer.start + b.time)}),$interpolated,$expr)';
  }
  return 'if(lt($clock,${decimal(layer.start + keys.first.time)}),${decimal(value(keys.first))},$expr)';
}

String captionManifest(Project p, Map<String, String> graphics) {
  final lines = <String>[];
  var cursor = 0.0;
  void frame(String path, double duration) {
    if (duration <= 0) return;
    lines.add(concatManifest([path]));
    lines.add('option framerate 1000');
    lines.add('duration ${decimal(duration)}');
  }

  for (final cue in p.captions) {
    if (cue.start >= p.duration) break;
    if (cue.start > cursor)
      frame(graphics['caption:blank']!, cue.start - cursor);
    final end = cue.end.clamp(0.0, p.duration);
    frame(graphics['caption:${cue.id}']!, end - cue.start);
    cursor = end;
  }
  if (cursor < p.duration)
    frame(graphics['caption:blank']!, p.duration - cursor);
  lines.add(concatManifest([graphics['caption:blank']!]));
  lines.add('option framerate 1000');
  return lines.join('\n');
}

List<String> captionArguments(Project p, String manifest, String output) => [
  '-hide_banner',
  '-y',
  '-f',
  'concat',
  '-safe',
  '0',
  '-i',
  manifest,
  '-vf',
  'fps=30',
  '-t',
  decimal(p.duration),
  '-c:v',
  'ffv1',
  '-level',
  '3',
  '-pix_fmt',
  'bgra',
  '-an',
  '-progress',
  'pipe:1',
  '-nostats',
  output,
];
