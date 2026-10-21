import 'dart:convert';
import 'subtitles.dart';

String newId() =>
    '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_serial++}';
int _serial = 0;
double numOf(Map m, String key, double fallback) =>
    (m[key] as num?)?.toDouble() ?? fallback;

class Clip {
  Clip({
    required this.id,
    required this.path,
    required this.kind,
    required this.sourceDuration,
    this.label,
    this.cover,
    this.start = 0,
    double? end,
    this.speed = 1,
    this.volume = 1,
    this.rotation = 0,
    this.brightness = 0,
    this.contrast = 0,
    this.filter = 'none',
    this.fit = 'contain',
    this.transition = 0,
  }) : end = end ?? sourceDuration;
  final String id, path, kind, filter, fit;
  final String? label, cover;
  final double sourceDuration,
      start,
      end,
      speed,
      volume,
      brightness,
      contrast,
      transition;
  final int rotation;
  double get duration => (end - start) / speed;
  String get name => label ?? path.replaceAll('\\', '/').split('/').last;
  Map<String, dynamic> toJson() => {
    'id': id,
    'label': label,
    'cover': cover,
    'path': path,
    'kind': kind,
    'sourceDuration': sourceDuration,
    'start': start,
    'end': end,
    'speed': speed,
    'volume': volume,
    'rotation': rotation,
    'brightness': brightness,
    'contrast': contrast,
    'filter': filter,
    'fit': fit,
    'transition': transition,
  };
  factory Clip.fromJson(Map m) => Clip(
    id: m['id'],
    label: m['label'],
    cover: m['cover'],
    path: m['path'],
    kind: m['kind'],
    sourceDuration: numOf(m, 'sourceDuration', 0),
    start: numOf(m, 'start', 0),
    end: numOf(m, 'end', 0),
    speed: numOf(m, 'speed', 1),
    volume: numOf(m, 'volume', 1),
    rotation: m['rotation'] ?? 0,
    brightness: numOf(m, 'brightness', 0),
    contrast: numOf(m, 'contrast', 0),
    filter: m['filter'] ?? 'none',
    fit: m['fit'] ?? 'contain',
    transition: numOf(m, 'transition', 0),
  );
  Clip copy(Map<String, dynamic> values) =>
      Clip.fromJson({...toJson(), ...values});
}

class MotionKey {
  const MotionKey({
    required this.time,
    required this.x,
    required this.y,
    required this.size,
    required this.opacity,
    required this.rotation,
  });
  final double time, x, y, size, opacity, rotation;
  Map<String, dynamic> toJson() => {
    'time': time,
    'x': x,
    'y': y,
    'size': size,
    'opacity': opacity,
    'rotation': rotation,
  };
  factory MotionKey.fromJson(Map m) => MotionKey(
    time: numOf(m, 'time', 0),
    x: numOf(m, 'x', .5),
    y: numOf(m, 'y', .5),
    size: numOf(m, 'size', .1),
    opacity: numOf(m, 'opacity', 1),
    rotation: numOf(m, 'rotation', 0),
  );
}

class Layer {
  Layer({
    required this.id,
    required this.kind,
    this.text = 'Your text',
    this.start = 0,
    this.end = 3,
    this.x = .5,
    this.y = .5,
    this.size = .12,
    this.color = 0xffffffff,
    this.opacity = 1,
    this.rotation = 0,
    List<MotionKey> keys = const [],
    this.easing = 'linear',
  }) : keys = List.unmodifiable(keys);
  final List<MotionKey> keys;
  final String easing;
  final String id, kind, text;
  final double start, end, x, y, size, opacity, rotation;
  final int color;
  bool active(double t) => t >= start && t < end;
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind,
    'text': text,
    'start': start,
    'end': end,
    'x': x,
    'y': y,
    'size': size,
    'color': color,
    'opacity': opacity,
    'rotation': rotation,
    'keys': keys.map((k) => k.toJson()).toList(),
    'easing': easing,
  };
  factory Layer.fromJson(Map m) => Layer(
    id: m['id'],
    kind: m['kind'],
    text: m['text'] ?? '',
    start: numOf(m, 'start', 0),
    end: numOf(m, 'end', 3),
    x: numOf(m, 'x', .5),
    y: numOf(m, 'y', .5),
    size: numOf(m, 'size', .12),
    color: m['color'] ?? 0xffffffff,
    opacity: numOf(m, 'opacity', 1),
    rotation: numOf(m, 'rotation', 0),
    keys: ((m['keys'] as List?) ?? [])
        .map((k) => MotionKey.fromJson(k))
        .toList(),
    easing: m['easing'] ?? 'linear',
  );
  Layer copy(Map<String, dynamic> values) =>
      Layer.fromJson({...toJson(), ...values});
  double get rasterSize => keys.fold(
    size,
    (maximum, key) => key.size > maximum ? key.size : maximum,
  );
  MotionKey get base => MotionKey(
    time: 0,
    x: x,
    y: y,
    size: size,
    opacity: opacity,
    rotation: rotation,
  );
  MotionKey at(double absoluteTime) {
    if (keys.isEmpty) return base;
    final t = (absoluteTime - start).clamp(0.0, end - start);
    if (t <= keys.first.time) return keys.first;
    for (var i = 1; i < keys.length; i++) {
      final b = keys[i], a = keys[i - 1];
      if (t > b.time) continue;
      var u = ((t - a.time) / (b.time - a.time)).clamp(0.0, 1.0);
      if (easing == 'smooth') u = u * u * (3 - 2 * u);
      double lerp(double a, double b) => a + (b - a) * u;
      return MotionKey(
        time: t,
        x: lerp(a.x, b.x),
        y: lerp(a.y, b.y),
        size: lerp(a.size, b.size),
        opacity: lerp(a.opacity, b.opacity),
        rotation: lerp(a.rotation, b.rotation),
      );
    }
    return keys.last;
  }

  Layer keyed(double absoluteTime, Map<String, dynamic> changes) {
    final t = (absoluteTime - start).clamp(0.0, end - start);
    final value = MotionKey.fromJson({
      ...at(absoluteTime).toJson(),
      ...changes,
      'time': t,
    });
    final list = keys.isEmpty ? [base] : keys.toList();
    list.removeWhere((k) => (k.time - t).abs() < .025);
    list.add(value);
    list.sort((a, b) => a.time.compareTo(b.time));
    return copy({'keys': list.map((k) => k.toJson()).toList()});
  }
}

class AudioTrack {
  AudioTrack({
    required this.id,
    required this.path,
    required this.sourceDuration,
    this.start = 0,
    this.inPoint = 0,
    double? length,
    this.volume = .5,
    this.fadeIn = 0,
    this.fadeOut = 0,
  }) : length = length ?? sourceDuration;
  final String id, path;
  final double sourceDuration, start, inPoint, length, volume, fadeIn, fadeOut;
  bool active(double t) => t >= start && t < start + length;
  double gainAt(double t) {
    if (!active(t)) return 0;
    var gain = volume;
    final local = t - start;
    if (fadeIn > 0) gain *= (local / fadeIn).clamp(0, 1);
    if (fadeOut > 0) gain *= ((length - local) / fadeOut).clamp(0, 1);
    return gain;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'sourceDuration': sourceDuration,
    'start': start,
    'inPoint': inPoint,
    'length': length,
    'volume': volume,
    'fadeIn': fadeIn,
    'fadeOut': fadeOut,
  };
  factory AudioTrack.fromJson(Map m) => AudioTrack(
    id: m['id'],
    path: m['path'],
    sourceDuration: numOf(m, 'sourceDuration', 0),
    start: numOf(m, 'start', 0),
    inPoint: numOf(m, 'inPoint', 0),
    length: numOf(m, 'length', 0),
    volume: numOf(m, 'volume', .5),
    fadeIn: numOf(m, 'fadeIn', 0),
    fadeOut: numOf(m, 'fadeOut', 0),
  );
  AudioTrack copy(Map<String, dynamic> values) =>
      AudioTrack.fromJson({...toJson(), ...values});
}

class Project {
  Project({
    required this.id,
    this.name = 'Untitled edit',
    this.ratio = 9 / 16,
    this.height = 720,
    List<Clip> clips = const [],
    List<Layer> layers = const [],
    List<AudioTrack> audio = const [],
    List<SubtitleCue> captions = const [],
  }) : clips = List.unmodifiable(clips),
       layers = List.unmodifiable(layers),
       audio = List.unmodifiable(audio),
       captions = List.unmodifiable(captions);
  final String id, name;
  final double ratio;
  final int height;
  final List<Clip> clips;
  final List<Layer> layers;
  final List<AudioTrack> audio;
  final List<SubtitleCue> captions;
  int get width => ratio < 1 ? height : ((height * ratio) / 2).round() * 2;
  int get pixelHeight =>
      ratio < 1 ? ((height / ratio) / 2).round() * 2 : height;
  double overlap(int index) {
    if (index < 0 || index >= clips.length - 1) return 0;
    final wanted = clips[index].transition;
    return wanted.clamp(
      0,
      _min(clips[index].duration, clips[index + 1].duration) / 2,
    );
  }

  double get duration =>
      clips.isEmpty ? 0 : offset(clips.length - 1) + clips.last.duration;
  double offset(int index) {
    var t = 0.0;
    for (var i = 0; i < index; i++) {
      t += clips[i].duration - overlap(i);
    }
    return t;
  }

  List<int> activeClips(double t) => [
    for (var i = 0; i < clips.length; i++)
      if (t >= offset(i) && t < offset(i) + clips[i].duration) i,
  ];
  int clipAt(double t) {
    final active = activeClips(t);
    return active.isNotEmpty
        ? active.last
        : clips.isEmpty
        ? -1
        : clips.length - 1;
  }

  double clipGain(int index, double t) {
    final local = t - offset(index), length = clips[index].duration;
    var gain = 1.0;
    final fadeIn = overlap(index - 1), fadeOut = overlap(index);
    if (fadeIn > 0) gain *= (local / fadeIn).clamp(0, 1);
    if (fadeOut > 0) gain *= ((length - local) / fadeOut).clamp(0, 1);
    return gain;
  }

  Map<String, dynamic> toJson() => {
    'schema': 1,
    'id': id,
    'name': name,
    'ratio': ratio,
    'height': height,
    'clips': clips.map((c) => c.toJson()).toList(),
    'layers': layers.map((l) => l.toJson()).toList(),
    'audio': audio.map((a) => a.toJson()).toList(),
    'captions': captions.map((c) => c.toJson()).toList(),
  };
  factory Project.fromJson(Map m, {bool validate = true}) {
    if (m['schema'] != 1)
      throw const FormatException('Unsupported project version');
    final p = Project(
      id: m['id'],
      name: m['name'],
      ratio: numOf(m, 'ratio', 9 / 16),
      height: m['height'] ?? 720,
      clips: (m['clips'] as List).map((c) => Clip.fromJson(c)).toList(),
      layers: (m['layers'] as List).map((l) => Layer.fromJson(l)).toList(),
      audio: (m['audio'] as List).map((a) => AudioTrack.fromJson(a)).toList(),
      captions: ((m['captions'] as List?) ?? [])
          .map((c) => SubtitleCue.fromJson(c))
          .toList(),
    );
    if (validate) p.validate();
    return p;
  }
  Project copy(Map<String, dynamic> values) =>
      Project.fromJson({...toJson(), ...values}, validate: false);
  void validate({bool exporting = false}) {
    void require(bool v, String message) {
      if (!v) throw FormatException(message);
    }

    require(
      id.isNotEmpty && !id.contains(RegExp(r'[^a-zA-Z0-9_-]')),
      'Invalid project ID',
    );
    require(
      name.trim().isNotEmpty && name.length <= 100,
      'Project name must be 1–100 characters',
    );
    require(
      [9 / 16, 16 / 9, 1.0, 4 / 5].contains(ratio),
      'Unsupported aspect ratio',
    );
    require([480, 720, 1080].contains(height), 'Unsupported export resolution');
    require(
      clips.length <= 100 && layers.length <= 12 && audio.length <= 4,
      'Timeline limit reached',
    );
    require(
      duration.isFinite && duration <= 1800,
      'Projects may be up to 30 minutes',
    );
    if (exporting) require(clips.isNotEmpty, 'Add a video or photo first');
    final ids = <String>{};
    require(captions.length <= 500, 'Use up to 500 subtitle cues');
    var previousCaptionEnd = 0.0;
    for (final c in captions) {
      require(
        c.id.isNotEmpty &&
            !c.id.contains(RegExp(r'[^a-zA-Z0-9_-]')) &&
            ids.add(c.id),
        'Invalid subtitle ID',
      );
      require(
        c.start.isFinite &&
            c.end.isFinite &&
            c.start >= previousCaptionEnd - .001 &&
            c.end > c.start &&
            c.end <= 1800 &&
            c.text.trim().isNotEmpty &&
            c.text.length <= 300,
        'Invalid subtitle cue',
      );
      previousCaptionEnd = c.end;
    }
    for (final c in clips) {
      require(
        c.id.isNotEmpty &&
            !c.id.contains(RegExp(r'[^a-zA-Z0-9_-]')) &&
            ids.add(c.id),
        'Invalid or duplicate timeline ID',
      );
      require(
        ['video', 'image'].contains(c.kind) && c.path.isNotEmpty,
        'Invalid media clip',
      );
      require(
        c.sourceDuration.isFinite &&
            c.start >= 0 &&
            c.end <= c.sourceDuration &&
            c.end > c.start,
        'Invalid trim range',
      );
      require(
        [.25, .5, 1.0, 1.5, 2.0, 3.0, 4.0].contains(c.speed),
        'Invalid speed',
      );
      require(
        c.duration >= .1 &&
            c.volume >= 0 &&
            c.volume <= 1 &&
            c.rotation >= 0 &&
            c.rotation <= 3,
        'Invalid clip settings',
      );
      require(
        c.brightness.abs() <= .4 && c.contrast.abs() <= .5,
        'Invalid colour settings',
      );
      require(
        ['none', 'mono', 'warm', 'cool'].contains(c.filter) &&
            ['contain', 'cover'].contains(c.fit),
        'Invalid filter or fit',
      );
    }
    for (final c in clips) {
      require(
        c.transition.isFinite && c.transition >= 0 && c.transition <= 2,
        'Invalid transition',
      );
    }
    for (final l in layers) {
      require(
        l.id.isNotEmpty &&
            !l.id.contains(RegExp(r'[^a-zA-Z0-9_-]')) &&
            ids.add(l.id),
        'Invalid or duplicate timeline ID',
      );
      require(
        ['text', 'rectangle', 'circle', 'sticker'].contains(l.kind),
        'Unsupported layer',
      );
      require(
        l.start.isFinite &&
            l.end.isFinite &&
            l.start >= 0 &&
            l.end > l.start &&
            l.end <= 1800,
        'Invalid layer timing',
      );
      require(
        l.x >= 0 &&
            l.x <= 1 &&
            l.y >= 0 &&
            l.y <= 1 &&
            l.size >= .03 &&
            l.size <= .8 &&
            l.opacity >= 0 &&
            l.opacity <= 1 &&
            l.rotation.abs() <= 180,
        'Invalid layer position',
      );
      require(l.text.length <= 200, 'Text may be up to 200 characters');
      require(
        l.keys.length <= 50 && ['linear', 'smooth'].contains(l.easing),
        'Invalid animation settings',
      );
      var previous = -1.0;
      for (final k in l.keys) {
        require(
          k.time.isFinite &&
              k.time >= 0 &&
              k.time <= l.end - l.start &&
              k.time > previous,
          'Invalid keyframe timing',
        );
        previous = k.time;
        require(
          k.x >= 0 &&
              k.x <= 1 &&
              k.y >= 0 &&
              k.y <= 1 &&
              k.size >= .03 &&
              k.size <= .8 &&
              k.opacity >= 0 &&
              k.opacity <= 1 &&
              k.rotation.abs() <= 180,
          'Invalid keyframe',
        );
      }
    }
    for (final a in audio) {
      require(
        a.id.isNotEmpty &&
            !a.id.contains(RegExp(r'[^a-zA-Z0-9_-]')) &&
            ids.add(a.id),
        'Invalid or duplicate timeline ID',
      );
      require(
        a.path.isNotEmpty &&
            a.sourceDuration.isFinite &&
            a.inPoint.isFinite &&
            a.start.isFinite &&
            a.start >= 0 &&
            a.start <= 1800 &&
            a.inPoint >= 0 &&
            a.length.isFinite &&
            a.length >= .1 &&
            a.inPoint + a.length <= a.sourceDuration + .001 &&
            a.volume >= 0 &&
            a.volume <= 1,
        'Invalid audio settings',
      );
      require(
        a.fadeIn.isFinite &&
            a.fadeOut.isFinite &&
            a.fadeIn >= 0 &&
            a.fadeOut >= 0 &&
            a.fadeIn + a.fadeOut <= a.length + .001,
        'Audio fades exceed track length',
      );
    }
  }

  Project split(int index, double timelineTime) {
    final c = clips[index];
    final local = timelineTime - offset(index);
    if (local < 2 * overlap(index - 1) ||
        c.duration - local < 2 * overlap(index))
      return this;
    final cut = c.start + local * c.speed;
    if (c.kind == 'image' ||
        cut - c.start < .1 * c.speed ||
        c.end - cut < .1 * c.speed)
      return this;
    return copy({
      'clips': [
        ...clips.take(index).map((c) => c.toJson()),
        c.copy({'end': cut, 'transition': 0}).toJson(),
        c.copy({'id': newId(), 'start': cut}).toJson(),
        ...clips.skip(index + 1).map((c) => c.toJson()),
      ],
    });
  }
}

class ProjectHistory {
  final _past = <Project>[], _future = <Project>[];
  bool get canUndo => _past.isNotEmpty;
  bool get canRedo => _future.isNotEmpty;
  void push(Project p) {
    _past.add(p);
    if (_past.length > 40) _past.removeAt(0);
    _future.clear();
  }

  Project undo(Project p) {
    if (!canUndo) return p;
    _future.add(p);
    return _past.removeLast();
  }

  Project redo(Project p) {
    if (!canRedo) return p;
    _past.add(p);
    return _future.removeLast();
  }
}

String encodeProject(Project p) =>
    const JsonEncoder.withIndent('  ').convert(p.toJson());

double _min(double a, double b) => a < b ? a : b;
