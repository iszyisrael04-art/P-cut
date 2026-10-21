import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show FontFeature;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart' hide AudioTrack;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path_provider/path_provider.dart';
import 'project.dart';
import 'storage.dart';
import 'painting.dart';
import 'preview.dart';
import 'exporter.dart';
import 'voiceover.dart';
import 'subtitles.dart';
import 'captions_page.dart';
import 'main.dart' show askText, showError, stamp;

class CutEditor extends StatefulWidget {
  const CutEditor({super.key, required this.store, required this.initial});
  final ProjectStore store;
  final Project initial;
  @override
  State<CutEditor> createState() => _CutEditorState();
}

class _CutEditorState extends State<CutEditor> with WidgetsBindingObserver {
  late Project project = widget.initial;
  final history = ProjectHistory();
  final exporter = CutExporter();
  Timer? timer, autosave;
  DateTime? lastTick;
  double time = 0, zoom = 32, progress = 0;
  bool playing = false, busy = false;
  String task = '', tab = 'clip';
  int selectedClip = 0;
  String? selectedLayer, selectedAudio;
  String saveStatus = 'Saved on device';
  File? exported;
  bool cancelExportRequested = false;
  Project? gestureBefore;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      final now = DateTime.now();
      if (playing) {
        final elapsed = lastTick == null
            ? 0.0
            : now.difference(lastTick!).inMicroseconds / 1000000;
        setState(() {
          time = (time + elapsed).clamp(0, project.duration);
          if (time >= project.duration) playing = false;
        });
      }
      lastTick = now;
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      setState(() => playing = false);
      save();
    }
  }

  void commit(Project next, {bool remember = true}) {
    if (busy) return;
    try {
      next.validate();
      if (remember) history.push(project);
      setState(() {
        project = next;
        time = time.clamp(0, project.duration);
        selectedClip = selectedClip.clamp(
          0,
          math.max(0, project.clips.length - 1),
        );
        saveStatus = 'Saving…';
        playing = false;
      });
      autosave?.cancel();
      autosave = Timer(const Duration(milliseconds: 500), save);
    } catch (e) {
      showError(context, e);
    }
  }

  Future<void> save() async {
    autosave?.cancel();
    final snapshot = project;
    try {
      await widget.store.save(snapshot);
      if (mounted)
        setState(
          () => saveStatus = identical(project, snapshot)
              ? 'Saved on device'
              : 'Saving…',
        );
    } catch (_) {
      if (mounted)
        setState(() => saveStatus = 'Save failed — keep this editor open');
    }
  }

  void beginGesture() {
    gestureBefore = project;
  }

  void endGesture() {
    final before = gestureBefore;
    gestureBefore = null;
    if (before != null && encodeProject(before) != encodeProject(project)) {
      history.push(before);
      setState(() {});
    }
  }

  Clip? get clip => project.clips.isEmpty
      ? null
      : project.clips[selectedClip.clamp(0, project.clips.length - 1)];
  Layer? get layer {
    for (final l in project.layers) {
      if (l.id == selectedLayer) return l;
    }
    return null;
  }

  AudioTrack? get audio {
    for (final a in project.audio) {
      if (a.id == selectedAudio) return a;
    }
    return null;
  }

  void updateClip(Map<String, dynamic> changes, {bool remember = true}) {
    if (clip == null) return;
    final list = project.clips.toList();
    list[selectedClip] = clip!.copy(changes);
    commit(
      project.copy({'clips': list.map((c) => c.toJson()).toList()}),
      remember: remember,
    );
  }

  void updateLayer(Map<String, dynamic> changes, {bool remember = true}) {
    final old = layer;
    if (old == null) return;
    final motionFields = {'x', 'y', 'size', 'opacity', 'rotation'};
    var next =
        !changes.containsKey('keys') &&
            changes.keys.any(motionFields.contains) &&
            old.keys.isNotEmpty
        ? old.keyed(time, changes)
        : old.copy(changes);
    if (changes.containsKey('start') || changes.containsKey('end')) {
      final factor = (next.end - next.start) / (old.end - old.start);
      next = next.copy({
        'keys': old.keys
            .map((k) => {...k.toJson(), 'time': k.time * factor})
            .toList(),
      });
    }
    commit(
      project.copy({
        'layers': project.layers
            .map((l) => (l.id == old.id ? next : l).toJson())
            .toList(),
      }),
      remember: remember,
    );
  }

  void updateAudio(Map<String, dynamic> changes, {bool remember = true}) {
    if (audio == null) return;
    if (changes.containsKey('length')) {
      final length = (changes['length'] as num).toDouble(),
          sum = audio!.fadeIn + audio!.fadeOut;
      if (sum > length) {
        changes = {
          ...changes,
          'fadeIn': audio!.fadeIn * length / sum,
          'fadeOut': audio!.fadeOut * length / sum,
        };
      }
    }
    commit(
      project.copy({
        'audio': project.audio
            .map((a) => (a.id == selectedAudio ? a.copy(changes) : a).toJson())
            .toList(),
      }),
      remember: remember,
    );
  }

  Future<({double duration, String? cover})> probe(
    File file, {
    bool thumbnail = false,
  }) async {
    final player = Player(
      configuration: const PlayerConfiguration(bufferSize: 1024 * 1024),
    );
    // Attach a decoder even though the import preview is not on screen yet.
    final controller = thumbnail ? VideoController(player) : null;
    try {
      await player.open(Media(file.path), play: false);
      final d = player.state.duration.inMilliseconds > 0
          ? player.state.duration
          : await player.stream.duration
                .firstWhere((d) => d.inMilliseconds > 0)
                .timeout(const Duration(seconds: 20));
      String? cover;
      if (controller != null) {
        try {
          await player.seek(
            Duration(
              milliseconds: math.min(100, (d.inMilliseconds / 2).round()),
            ),
          );
          for (var attempt = 0; attempt < 5; attempt++) {
            await Future<void>.delayed(const Duration(milliseconds: 150));
            final bytes = await player.screenshot(format: 'image/jpeg');
            if (bytes != null && bytes.isNotEmpty) {
              cover = '${file.path}.thumb.jpg';
              await File(cover).writeAsBytes(bytes);
              break;
            }
          }
        } catch (_) {}
      }
      return (duration: d.inMilliseconds / 1000, cover: cover);
    } finally {
      await player.dispose();
    }
  }

  Future<void> import({bool music = false}) async {
    if (busy) return;
    setState(() {
      playing = false;
    });
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: music
          ? ['mp3', 'wav', 'm4a', 'aac', 'flac', 'ogg']
          : ['mp4', 'mov', 'mkv', 'webm', 'jpg', 'jpeg', 'png', 'webp'],
    );
    if (files.isEmpty || !mounted) return;
    setState(() {
      busy = true;
      progress = 0;
      task = 'Importing media';
    });
    final added = <File>[];
    try {
      var next = project;
      for (var i = 0; i < files.length; i++) {
        final picked = files[i];
        if (picked.path == null)
          throw StateError('This file cannot be opened. Choose a local copy.');
        if (music && next.audio.length >= 4)
          throw StateError('Up to four music or sound tracks per project.');
        if (!music && next.clips.length >= 100)
          throw StateError('Up to 100 clips per project.');
        final file = await widget.store.import(project, File(picked.path!), (
          v,
        ) {
          if (mounted) setState(() => progress = (i + v) / files.length);
        });
        added.add(file);
        final ext = file.path.split('.').last.toLowerCase();
        final image = ['png', 'jpg', 'jpeg', 'webp'].contains(ext);
        final info = image
            ? (duration: 5.0, cover: file.path)
            : await probe(file, thumbnail: !music);
        final seconds = info.duration;
        if (seconds < .1)
          throw StateError('This media is too short or unsupported.');
        if (music) {
          final a = AudioTrack(
            id: newId(),
            path: file.path,
            sourceDuration: seconds,
            start: time,
            length: math.min(seconds, math.max(.1, project.duration - time)),
          );
          next = next.copy({
            'audio': [...next.audio.map((a) => a.toJson()), a.toJson()],
          });
          selectedAudio = a.id;
          tab = 'music';
        } else {
          final c = Clip(
            id: newId(),
            path: file.path,
            kind: image ? 'image' : 'video',
            label: picked.name,
            cover: info.cover,
            sourceDuration: image ? 1800 : seconds,
            end: seconds,
          );
          next = next.copy({
            'clips': [...next.clips.map((c) => c.toJson()), c.toJson()],
          });
          selectedClip = next.clips.length - 1;
          tab = 'clip';
        }
      }
      next.validate();
      setState(() => busy = false);
      commit(next);
      await save();
    } catch (e) {
      for (final f in added) {
        try {
          await f.delete();
          final thumbnail = File('${f.path}.thumb.jpg');
          if (await thumbnail.exists()) await thumbnail.delete();
        } catch (_) {}
      }
      if (mounted) showError(context, e);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> addLayer(String kind) async {
    if (project.clips.isEmpty) {
      showError(context, 'Add a video or photo first.');
      return;
    }
    if (project.layers.length >= 12) {
      showError(context, 'Up to 12 visual layers per project.');
      return;
    }
    String text = kind == 'sticker' ? '✨' : 'Your text';
    if (kind == 'text' || kind == 'sticker') {
      final result = await askText(
        context,
        kind == 'text' ? 'Add text' : 'Emoji sticker',
        text,
        maxLength: kind == 'text' ? 200 : 20,
      );
      if (result == null || result.isEmpty || !mounted) return;
      text = result;
    }
    final start = time.clamp(0, math.max(0, project.duration - .1)).toDouble();
    final l = Layer(
      id: newId(),
      kind: kind,
      text: text,
      start: start,
      end: math.min(project.duration, start + 3),
      size: kind == 'text' ? .08 : .18,
      color: kind == 'rectangle' || kind == 'circle'
          ? accent.toARGB32()
          : 0xffffffff,
    );
    commit(
      project.copy({
        'layers': [...project.layers.map((l) => l.toJson()), l.toJson()],
      }),
    );
    setState(() {
      selectedLayer = l.id;
      tab = 'layers';
    });
  }

  void moveClip(int delta) {
    if (clip == null) return;
    final target = selectedClip + delta;
    if (target < 0 || target >= project.clips.length) return;
    final list = project.clips.toList(), item = project.clips[selectedClip];
    list.removeAt(selectedClip);
    list.insert(target, item);
    commit(project.copy({'clips': list.map((c) => c.toJson()).toList()}));
    setState(() => selectedClip = target);
  }

  Future<void> export() async {
    if (busy) return;
    try {
      project.validate(exporting: true);
    } catch (e) {
      showError(context, e);
      return;
    }
    setState(() => playing = false);
    var settings = project;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: const Text('Export your cut'),
          content: SizedBox(
            width: 380,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${stamp(project.duration)} · H.264 MP4 · AAC audio'),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final h in [480, 720, 1080])
                      ChoiceChip(
                        label: Text('${h}p'),
                        selected: settings.height == h,
                        onSelected: (_) => refresh(
                          () => settings = settings.copy({'height': h}),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '${settings.width} × ${settings.pixelHeight} pixels',
                  style: const TextStyle(color: Colors.white54),
                ),
                if (Platform.isWindows) ...[
                  const SizedBox(height: 16),
                  const Text(
                    'FFmpeg and FFprobe are required for Windows export.',
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.folder_open),
                    label: const Text('Locate ffmpeg.exe'),
                    onPressed: () async {
                      final result = await FilePicker.pickFile(
                        type: FileType.custom,
                        allowedExtensions: ['exe'],
                      );
                      if (result != null) {
                        exporter.ffmpegPath = result.path;
                        if (context.mounted) refresh(() {});
                      }
                    },
                  ),
                  if (exporter.ffmpegPath != null)
                    Text(
                      exporter.ffmpegPath!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialog, true),
              child: const Text('Export'),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    commit(settings);
    await save();
    cancelExportRequested = false;
    setState(() {
      busy = true;
      task = 'Preparing layers';
      progress = 0;
    });
    Directory? work;
    try {
      final temp = await getTemporaryDirectory();
      work = await Directory('${temp.path}/pcut-${newId()}').create();
      final overlays = await renderLayers(project, work);
      overlays.addAll(await renderCaptions(project, work));
      if (cancelExportRequested) throw StateError('Export cancelled');
      final result = await exporter.export(project, work, overlays, (v, label) {
        if (mounted)
          setState(() {
            progress = v;
            task = label;
          });
      });
      final exports = Directory('${widget.store.root.path}/Exports');
      await exports.create(recursive: true);
      exported = await result.copy(
        '${exports.path}/${result.uri.pathSegments.last}',
      );
      if (mounted) {
        setState(() => busy = false);
        await showExport(exported!);
      }
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      if (work != null) {
        try {
          await work.delete(recursive: true);
        } catch (_) {}
      }
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> showExport(File file) async {
    await showDialog<void>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: const Text('Your cut is ready'),
        content: Text('MP4 saved on this device.\n${file.path}'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Done'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.save_alt),
            label: Text(Platform.isAndroid ? 'Save to gallery' : 'Save a copy'),
            onPressed: () async {
              try {
                if (Platform.isAndroid) {
                  final message = await CutExporter.publish(file);
                  if (dialog.mounted)
                    ScaffoldMessenger.of(
                      dialog,
                    ).showSnackBar(SnackBar(content: Text(message)));
                } else {
                  final destination = await FilePicker.saveFile(
                    dialogTitle: 'Save P-cut video',
                    fileName: file.uri.pathSegments.last,
                    type: FileType.custom,
                    allowedExtensions: ['mp4'],
                  );
                  if (destination != null && destination != file.path)
                    await file.copy(destination);
                }
              } catch (e) {
                if (dialog.mounted) showError(dialog, e);
              }
            },
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    autosave?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Widget icon(IconData symbol, String tip, VoidCallback? action) => IconButton(
    tooltip: tip,
    onPressed: busy ? null : action,
    icon: Icon(symbol, size: 22),
  );
  Widget tool(
    IconData symbol,
    String label,
    VoidCallback action, {
    bool selected = false,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 3),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.filledTonal(
          onPressed: busy ? null : action,
          style: IconButton.styleFrom(
            backgroundColor: selected ? accent : panel,
            foregroundColor: selected ? Colors.black : Colors.white,
          ),
          icon: Icon(symbol),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: const TextStyle(fontSize: 10, color: Colors.white60),
        ),
      ],
    ),
  );
  Widget slider(
    String label,
    double value,
    double min,
    double max,
    void Function(double) change, {
    String? suffix,
  }) => Row(
    children: [
      SizedBox(
        width: 80,
        child: Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ),
      Expanded(
        child: Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChangeStart: (_) => beginGesture(),
          onChanged: busy ? null : change,
          onChangeEnd: (_) => endGesture(),
        ),
      ),
      SizedBox(
        width: 52,
        child: Text(
          suffix ?? value.toStringAsFixed(2),
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    ],
  );
  Widget range(
    String label,
    double start,
    double end,
    double max,
    void Function(RangeValues) change,
  ) => Column(
    children: [
      Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(color: Colors.white60)),
          Text(
            '${stamp(start)} — ${stamp(end)}',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      RangeSlider(
        values: RangeValues(start.clamp(0, max), end.clamp(0, max)),
        min: 0,
        max: math.max(.1, max),
        onChangeStart: (_) => beginGesture(),
        onChanged: busy
            ? null
            : (v) {
                if (v.end - v.start >= .1) change(v);
              },
        onChangeEnd: (_) => endGesture(),
      ),
    ],
  );
  Widget clipTools() {
    final c = clip;
    if (c == null)
      return const Center(
        child: Text(
          'Add videos or photos to start editing.',
          style: TextStyle(color: Colors.white54),
        ),
      );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                c.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            icon(
              Icons.arrow_back,
              'Move clip left',
              selectedClip > 0 ? () => moveClip(-1) : null,
            ),
            icon(
              Icons.arrow_forward,
              'Move clip right',
              selectedClip < project.clips.length - 1
                  ? () => moveClip(1)
                  : null,
            ),
            icon(Icons.delete_outline, 'Delete clip', () {
              final list = project.clips.toList()..removeAt(selectedClip);
              commit(
                project.copy({'clips': list.map((c) => c.toJson()).toList()}),
              );
            }),
          ],
        ),
        if (c.kind == 'image')
          slider(
            'Duration',
            c.end,
            1,
            120,
            (v) => updateClip({'end': v}, remember: false),
            suffix: '${c.end.toStringAsFixed(1)}s',
          )
        else
          range(
            'Trim source',
            c.start,
            c.end,
            c.sourceDuration,
            (v) =>
                updateClip({'start': v.start, 'end': v.end}, remember: false),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            if (c.kind == 'video')
              for (final speed in [.25, .5, 1.0, 1.5, 2.0, 3.0, 4.0])
                ChoiceChip(
                  label: Text('${speed}×'),
                  selected: c.speed == speed,
                  onSelected: busy ? null : (_) => updateClip({'speed': speed}),
                ),
            ActionChip(
              avatar: const Icon(Icons.rotate_right, size: 16),
              label: const Text('Rotate'),
              onPressed: busy
                  ? null
                  : () => updateClip({'rotation': (c.rotation + 1) % 4}),
            ),
            ChoiceChip(
              label: const Text('Fit'),
              selected: c.fit == 'contain',
              onSelected: busy ? null : (_) => updateClip({'fit': 'contain'}),
            ),
            ChoiceChip(
              label: const Text('Fill'),
              selected: c.fit == 'cover',
              onSelected: busy ? null : (_) => updateClip({'fit': 'cover'}),
            ),
          ],
        ),
        if (selectedClip < project.clips.length - 1) ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            children: [
              for (final d in [0.0, .25, .5, 1.0])
                ChoiceChip(
                  label: Text(d == 0 ? 'Cut' : 'Fade ${d}s'),
                  selected: c.transition == d,
                  onSelected: busy
                      ? null
                      : (_) => updateClip({'transition': d}),
                ),
            ],
          ),
          if (c.transition > 0)
            Text(
              'Crossfade: ${project.overlap(selectedClip).toStringAsFixed(2)}s · short clips shorten the fade.',
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
        ],
        if (c.kind == 'video')
          slider(
            'Volume',
            c.volume,
            0,
            1,
            (v) => updateClip({'volume': v}, remember: false),
            suffix: '${(c.volume * 100).round()}%',
          ),
      ],
    );
  }

  Widget effectTools() {
    final c = clip;
    if (c == null) return const Text('Select a clip first.');
    return Column(
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final f in ['none', 'mono', 'warm', 'cool'])
              ChoiceChip(
                label: Text(f),
                selected: c.filter == f,
                onSelected: busy ? null : (_) => updateClip({'filter': f}),
              ),
          ],
        ),
        slider(
          'Brightness',
          c.brightness,
          -.4,
          .4,
          (v) => updateClip({'brightness': v}, remember: false),
        ),
        slider(
          'Contrast',
          c.contrast,
          -.5,
          .5,
          (v) => updateClip({'contrast': v}, remember: false),
        ),
        TextButton(
          onPressed: busy
              ? null
              : () => updateClip({
                  'filter': 'none',
                  'brightness': 0,
                  'contrast': 0,
                }),
          child: const Text('Reset colour'),
        ),
      ],
    );
  }

  Widget layerTools() {
    final l = layer;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          children: [
            for (final type in ['text', 'sticker', 'rectangle', 'circle'])
              ActionChip(
                label: Text('+ $type'),
                onPressed: busy ? null : () => addLayer(type),
              ),
          ],
        ),
        const SizedBox(height: 8),
        if (l == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Choose a layer on the timeline, or add one above.',
              style: TextStyle(color: Colors.white54),
            ),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  l.kind == 'text' || l.kind == 'sticker' ? l.text : l.kind,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (l.kind == 'text' || l.kind == 'sticker')
                icon(Icons.edit_outlined, 'Edit text', () async {
                  final text = await askText(
                    context,
                    'Edit layer',
                    l.text,
                    maxLength: 200,
                  );
                  if (text != null && mounted) updateLayer({'text': text});
                }),
              icon(Icons.vertical_align_top, 'Move layer to front', () {
                final list = project.layers.toList()
                  ..removeWhere((x) => x.id == l.id);
                list.add(l);
                commit(
                  project.copy({
                    'layers': list.map((x) => x.toJson()).toList(),
                  }),
                );
              }),
              icon(Icons.delete_outline, 'Delete layer', () {
                commit(
                  project.copy({
                    'layers': project.layers
                        .where((x) => x.id != l.id)
                        .map((x) => x.toJson())
                        .toList(),
                  }),
                );
                setState(() => selectedLayer = null);
              }),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () {
                        final next = l.keyed(time, {});
                        commit(
                          project.copy({
                            'layers': project.layers
                                .map((x) => (x.id == l.id ? next : x).toJson())
                                .toList(),
                          }),
                        );
                      },
                icon: const Icon(Icons.add_box_outlined, size: 18),
                label: const Text('Add keyframe'),
              ),
              if (l.keys.isNotEmpty)
                OutlinedButton(
                  onPressed: busy
                      ? null
                      : () => updateLayer({...l.at(time).toJson(), 'keys': []}),
                  child: const Text('Freeze animation'),
                ),
              if (l.keys.length > 1)
                ChoiceChip(
                  label: const Text('Smooth'),
                  selected: l.easing == 'smooth',
                  onSelected: busy
                      ? null
                      : (v) => updateLayer({'easing': v ? 'smooth' : 'linear'}),
                ),
            ],
          ),
          if (l.keys.isNotEmpty)
            Wrap(
              spacing: 6,
              children: [
                for (final k in l.keys)
                  InputChip(
                    label: Text(stamp(k.time)),
                    selected: (time - l.start - k.time).abs() < .03,
                    onPressed: () => setState(() {
                      time = l.start + k.time;
                      playing = false;
                    }),
                    onDeleted: () => updateLayer({
                      'keys': l.keys
                          .where((x) => x != k)
                          .map((x) => x.toJson())
                          .toList(),
                    }),
                  ),
              ],
            ),
          range(
            'On screen',
            l.start,
            l.end,
            math.max(project.duration, l.end),
            (v) =>
                updateLayer({'start': v.start, 'end': v.end}, remember: false),
          ),
          const Text(
            'Drag the selected layer in the preview to position it.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          slider(
            'Size',
            l.at(time).size,
            .03,
            .8,
            (v) => updateLayer({'size': v}, remember: false),
          ),
          slider(
            'Opacity',
            l.at(time).opacity,
            0,
            1,
            (v) => updateLayer({'opacity': v}, remember: false),
          ),
          slider(
            'Rotation',
            l.at(time).rotation,
            -180,
            180,
            (v) => updateLayer({'rotation': v}, remember: false),
            suffix: '${l.at(time).rotation.round()}°',
          ),
          Wrap(
            spacing: 8,
            children: [
              for (final colour in [
                0xffffffff,
                0xff000000,
                0xffc6ff37,
                0xffff5d8f,
                0xff50d5ff,
                0xffa690ff,
                0xffffc857,
              ])
                GestureDetector(
                  onTap: busy ? null : () => updateLayer({'color': colour}),
                  child: Container(
                    width: 30,
                    height: 30,
                    decoration: BoxDecoration(
                      color: Color(colour),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: l.color == colour ? accent : Colors.white24,
                        width: l.color == colour ? 3 : 1,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  Widget musicTools() {
    final a = audio;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        OutlinedButton.icon(
          onPressed: busy ? null : () => import(music: true),
          icon: const Icon(Icons.audio_file_outlined),
          label: const Text('Import music or sound'),
        ),
        OutlinedButton.icon(
          onPressed: busy ? null : recordVoiceover,
          icon: const Icon(Icons.mic_none),
          label: const Text('Record voiceover'),
        ),
        if (a == null)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              'Add up to four local music or sound tracks.',
              style: TextStyle(color: Colors.white54),
            ),
          )
        else ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  a.path.replaceAll('\\', '/').split('/').last,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              icon(Icons.delete_outline, 'Remove audio', () {
                commit(
                  project.copy({
                    'audio': project.audio
                        .where((x) => x.id != a.id)
                        .map((x) => x.toJson())
                        .toList(),
                  }),
                );
                setState(() => selectedAudio = null);
              }),
            ],
          ),
          slider(
            'Starts at',
            a.start,
            0,
            math.max(.1, project.duration),
            (v) => updateAudio({'start': v}, remember: false),
            suffix: stamp(a.start),
          ),
          range(
            'Source trim',
            a.inPoint,
            a.inPoint + a.length,
            a.sourceDuration,
            (v) => updateAudio({
              'inPoint': v.start,
              'length': v.end - v.start,
            }, remember: false),
          ),
          slider(
            'Fade in',
            a.fadeIn,
            0,
            math.min(5, a.length - a.fadeOut),
            (v) => updateAudio({'fadeIn': v}, remember: false),
            suffix: '${a.fadeIn.toStringAsFixed(1)}s',
          ),
          slider(
            'Fade out',
            a.fadeOut,
            0,
            math.min(5, a.length - a.fadeIn),
            (v) => updateAudio({'fadeOut': v}, remember: false),
            suffix: '${a.fadeOut.toStringAsFixed(1)}s',
          ),
          slider(
            'Volume',
            a.volume,
            0,
            1,
            (v) => updateAudio({'volume': v}, remember: false),
            suffix: '${(a.volume * 100).round()}%',
          ),
        ],
      ],
    );
  }

  Future<void> editCaptions() async {
    if (busy) return;
    if (project.clips.isEmpty) {
      showError(context, 'Add video or photos first.');
      return;
    }
    setState(() => playing = false);
    final result = await Navigator.push<List<SubtitleCue>>(
      context,
      MaterialPageRoute(
        builder: (_) => CaptionsPage(
          initial: project.captions,
          project: project,
          duration: project.duration,
          directory: widget.store.directory(project.id),
        ),
      ),
    );
    if (result != null && mounted)
      commit(
        project.copy({'captions': result.map((c) => c.toJson()).toList()}),
      );
  }

  Future<void> recordVoiceover() async {
    if (busy) return;
    if (project.clips.isEmpty || time >= project.duration - .1) {
      showError(context, 'Move the playhead inside your video first.');
      return;
    }
    if (project.audio.length >= 4) {
      showError(
        context,
        'Remove an audio track first; four tracks are supported.',
      );
      return;
    }
    setState(() => playing = false);
    final capture = await Navigator.push<VoiceCapture>(
      context,
      MaterialPageRoute(
        builder: (_) => VoiceoverPage(project: project, start: time),
      ),
    );
    if (capture == null || !mounted) return;
    setState(() {
      busy = true;
      task = 'Importing media';
      progress = 0;
    });
    try {
      final file = await widget.store.import(project, capture.file, (v) {
        if (mounted) setState(() => progress = v);
      });
      final track = AudioTrack(
        id: newId(),
        path: file.path,
        sourceDuration: capture.duration,
        start: capture.start,
        length: capture.duration,
        volume: 1,
      );
      setState(() => busy = false);
      commit(
        project.copy({
          'audio': [...project.audio.map((a) => a.toJson()), track.toJson()],
        }),
      );
      setState(() {
        selectedAudio = track.id;
        tab = 'music';
      });
      await save();
    } catch (e) {
      if (mounted) showError(context, e);
    } finally {
      try {
        if (await capture.file.exists()) await capture.file.delete();
      } catch (_) {}
      if (mounted) setState(() => busy = false);
    }
  }

  Widget timeline() {
    return LayoutBuilder(
      builder: (context, box) {
        final width = math.max(box.maxWidth - 58, project.duration * zoom + 32);
        Widget block(
          double start,
          double duration,
          Color colour,
          String label,
          VoidCallback onTap, {
          bool selected = false,
          String? cover,
        }) => Positioned(
          left: start * zoom,
          top: 3,
          width: math.max(12, duration * zoom - 3),
          height: 34,
          child: Material(
            color: selected ? colour : colour.withValues(alpha: .55),
            borderRadius: BorderRadius.circular(7),
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(7),
              child: Container(
                decoration: BoxDecoration(
                  image: cover == null
                      ? null
                      : DecorationImage(
                          image: FileImage(File(cover)),
                          fit: BoxFit.cover,
                          onError: (_, __) {},
                          opacity: .35,
                        ),
                  border: selected
                      ? Border.all(color: Colors.white, width: 1.5)
                      : null,
                  borderRadius: BorderRadius.circular(7),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 7),
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.clip,
                  style: TextStyle(
                    fontSize: 11,
                    color: colour == accent ? Colors.black : Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
        );
        final rows = <Widget>[
          SizedBox(
            height: 25,
            width: width,
            child: CustomPaint(painter: _Ruler(zoom, time)),
          ),
          SizedBox(
            height: 40,
            width: width,
            child: Stack(
              children: [
                for (var i = 0; i < project.clips.length; i++)
                  block(
                    project.offset(i),
                    project.clips[i].duration,
                    accent,
                    '${project.clips[i].kind == 'image' ? '▧' : '▶'} ${project.clips[i].name}',
                    () {
                      setState(() {
                        selectedClip = i;
                        tab = 'clip';
                        selectedLayer = null;
                        selectedAudio = null;
                        time = project.offset(i);
                        playing = false;
                      });
                    },
                    selected: tab == 'clip' && selectedClip == i,
                    cover: project.clips[i].cover,
                  ),
              ],
            ),
          ),
          for (final a in project.audio)
            SizedBox(
              height: 40,
              width: width,
              child: Stack(
                children: [
                  block(
                    a.start,
                    a.length,
                    const Color(0xff68d9d0),
                    '♫  Audio',
                    () {
                      setState(() {
                        selectedAudio = a.id;
                        tab = 'music';
                        time = a.start.clamp(0, project.duration);
                        playing = false;
                      });
                    },
                    selected: selectedAudio == a.id && tab == 'music',
                  ),
                ],
              ),
            ),
          for (final l in project.layers)
            SizedBox(
              height: 40,
              width: width,
              child: Stack(
                children: [
                  block(
                    l.start,
                    l.end - l.start,
                    const Color(0xffb39aff),
                    l.kind == 'text' || l.kind == 'sticker' ? l.text : l.kind,
                    () {
                      setState(() {
                        selectedLayer = l.id;
                        tab = 'layers';
                        time = l.start.clamp(0, project.duration);
                        playing = false;
                      });
                    },
                    selected: selectedLayer == l.id && tab == 'layers',
                  ),
                ],
              ),
            ),
        ];
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 46,
              child: Column(
                children: [
                  const SizedBox(height: 25),
                  const SizedBox(
                    height: 40,
                    child: Icon(
                      Icons.movie_outlined,
                      size: 17,
                      color: Colors.white38,
                    ),
                  ),
                  for (final _ in project.audio)
                    const SizedBox(
                      height: 40,
                      child: Icon(
                        Icons.music_note,
                        size: 17,
                        color: Colors.white38,
                      ),
                    ),
                  for (final _ in project.layers)
                    const SizedBox(
                      height: 40,
                      child: Icon(
                        Icons.layers_outlined,
                        size: 17,
                        color: Colors.white38,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: GestureDetector(
                  onTapDown: busy
                      ? null
                      : (details) => setState(() {
                          time = (details.localPosition.dx / zoom).clamp(
                            0,
                            project.duration,
                          );
                          playing = false;
                        }),
                  child: SizedBox(
                    width: width,
                    child: Stack(
                      children: [
                        Column(children: rows),
                        Positioned(
                          left: time * zoom,
                          top: 0,
                          bottom: 0,
                          child: IgnorePointer(
                            child: Container(width: 2, color: Colors.white),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Future<bool> leave() async {
    if (busy) return false;
    setState(() => playing = false);
    await save();
    if (saveStatus.startsWith('Save failed')) return false;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final preview = ProjectPreview(
      project: project,
      time: time,
      playing: playing,
      selectedLayer: tab == 'layers' ? selectedLayer : null,
      onMove: busy || tab != 'layers' || layer == null
          ? null
          : (dx, dy) {
              gestureBefore ??= project;
              updateLayer({
                'x': (layer!.at(time).x + dx).clamp(0, 1),
                'y': (layer!.at(time).y + dy).clamp(0, 1),
              }, remember: false);
            },
      onMoveEnd: endGesture,
    );
    final tools = SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: switch (tab) {
        'fx' => effectTools(),
        'layers' => layerTools(),
        'music' => musicTools(),
        _ => clipTools(),
      },
    );
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop && await leave() && context.mounted) Navigator.pop(context);
      },
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): _PlayIntent(),
          SingleActivator(LogicalKeyboardKey.keyZ, control: true):
              _UndoIntent(),
          SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true):
              _RedoIntent(),
        },
        child: Actions(
          actions: {
            _PlayIntent: CallbackAction<_PlayIntent>(
              onInvoke: (_) {
                if (!busy) setState(() => playing = !playing);
                return null;
              },
            ),
            _UndoIntent: CallbackAction<_UndoIntent>(
              onInvoke: (_) {
                if (!busy && history.canUndo)
                  commit(history.undo(project), remember: false);
                return null;
              },
            ),
            _RedoIntent: CallbackAction<_RedoIntent>(
              onInvoke: (_) {
                if (!busy && history.canRedo)
                  commit(history.redo(project), remember: false);
                return null;
              },
            ),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              appBar: AppBar(
                leading: icon(
                  Icons.arrow_back_rounded,
                  'Save and close',
                  () async {
                    if (await leave() && context.mounted)
                      Navigator.pop(context);
                  },
                ),
                title: GestureDetector(
                  onTap: busy
                      ? null
                      : () async {
                          final name = await askText(
                            context,
                            'Rename project',
                            project.name,
                          );
                          if (name != null && name.isNotEmpty && mounted)
                            commit(project.copy({'name': name}));
                        },
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        project.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        saveStatus,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.white38,
                        ),
                      ),
                    ],
                  ),
                ),
                actions: [
                  PopupMenuButton<double>(
                    enabled: !busy,
                    tooltip: 'Canvas aspect ratio',
                    onSelected: (ratio) =>
                        commit(project.copy({'ratio': ratio})),
                    itemBuilder: (_) => [
                      for (final e in {
                        '9:16': 9 / 16,
                        '16:9': 16 / 9,
                        '1:1': 1.0,
                        '4:5': 4 / 5,
                      }.entries)
                        PopupMenuItem(value: e.value, child: Text(e.key)),
                    ],
                    icon: const Icon(Icons.aspect_ratio),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: FilledButton(
                      onPressed: busy ? null : export,
                      child: const Icon(Icons.ios_share_rounded, size: 21),
                    ),
                  ),
                ],
              ),
              body: SafeArea(
                child: LayoutBuilder(
                  builder: (context, box) {
                    final wide = box.maxWidth > 850;
                    final screen = Column(
                      children: [
                        Expanded(
                          flex: wide ? 6 : 5,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: preview,
                          ),
                        ),
                        SizedBox(
                          height: 24,
                          child: Slider(
                            value: time.clamp(0.0, project.duration),
                            min: 0,
                            max: math.max(.1, project.duration),
                            onChangeStart: (_) =>
                                setState(() => playing = false),
                            onChanged: busy || project.clips.isEmpty
                                ? null
                                : (v) => setState(() => time = v),
                          ),
                        ),
                        Row(
                          children: [
                            icon(
                              Icons.undo_rounded,
                              'Undo',
                              history.canUndo
                                  ? () => commit(
                                      history.undo(project),
                                      remember: false,
                                    )
                                  : null,
                            ),
                            icon(
                              Icons.redo_rounded,
                              'Redo',
                              history.canRedo
                                  ? () => commit(
                                      history.redo(project),
                                      remember: false,
                                    )
                                  : null,
                            ),
                            Expanded(
                              child: Center(
                                child: Text(
                                  '${stamp(time)} / ${stamp(project.duration)}',
                                  style: const TextStyle(
                                    fontFeatures: [
                                      FontFeature.tabularFigures(),
                                    ],
                                    fontSize: 12,
                                    color: Colors.white60,
                                  ),
                                ),
                              ),
                            ),
                            icon(
                              playing
                                  ? Icons.pause_circle_filled
                                  : Icons.play_circle_filled,
                              'Play / pause',
                              project.clips.isEmpty
                                  ? null
                                  : () {
                                      setState(() {
                                        if (time >= project.duration) time = 0;
                                        playing = !playing;
                                        lastTick = DateTime.now();
                                      });
                                    },
                            ),
                            icon(
                              Icons.remove,
                              'Zoom out timeline',
                              () => setState(
                                () => zoom = (zoom / 1.4).clamp(8, 150),
                              ),
                            ),
                            icon(
                              Icons.add,
                              'Zoom in timeline',
                              () => setState(
                                () => zoom = (zoom * 1.4).clamp(8, 150),
                              ),
                            ),
                          ],
                        ),
                        SizedBox(
                          height: wide ? 180 : 128,
                          child: ColoredBox(
                            color: const Color(0xff12141a),
                            child: SingleChildScrollView(child: timeline()),
                          ),
                        ),
                        if (!wide) Expanded(flex: 3, child: tools),
                        if (busy)
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              children: [
                                LinearProgressIndicator(value: progress),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        '$task · ${(progress * 100).round()}%',
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                    if (task != 'Importing media')
                                      TextButton(
                                        onPressed: () {
                                          cancelExportRequested = true;
                                          exporter.cancel();
                                        },
                                        child: const Text('Cancel'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        SizedBox(
                          height: 82,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                tool(
                                  Icons.add_photo_alternate_outlined,
                                  'Media',
                                  () => import(),
                                ),
                                tool(
                                  Icons.content_cut_rounded,
                                  'Clip',
                                  () => setState(() => tab = 'clip'),
                                  selected: tab == 'clip',
                                ),
                                tool(Icons.call_split_rounded, 'Split', () {
                                  if (clip != null) {
                                    final next = project.split(
                                      selectedClip,
                                      time,
                                    );
                                    if (identical(next, project)) {
                                      showError(
                                        context,
                                        'Move the playhead inside the selected video, away from a crossfade.',
                                      );
                                    } else {
                                      commit(next);
                                    }
                                  }
                                }),
                                tool(Icons.copy_all_rounded, 'Duplicate', () {
                                  if (clip != null) {
                                    final list = project.clips.toList();
                                    list.insert(
                                      selectedClip + 1,
                                      clip!.copy({'id': newId()}),
                                    );
                                    commit(
                                      project.copy({
                                        'clips': list
                                            .map((c) => c.toJson())
                                            .toList(),
                                      }),
                                    );
                                  }
                                }),
                                tool(
                                  Icons.music_note_rounded,
                                  'Music',
                                  () => setState(() => tab = 'music'),
                                  selected: tab == 'music',
                                ),
                                tool(
                                  Icons.auto_awesome_rounded,
                                  'Effects',
                                  () => setState(() => tab = 'fx'),
                                  selected: tab == 'fx',
                                ),
                                tool(
                                  Icons.closed_caption_outlined,
                                  'Subtitles',
                                  editCaptions,
                                ),
                                tool(
                                  Icons.text_fields_rounded,
                                  'Layers',
                                  () => setState(() => tab = 'layers'),
                                  selected: tab == 'layers',
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                    return wide
                        ? Row(
                            children: [
                              Expanded(child: screen),
                              Container(
                                width: 330,
                                decoration: const BoxDecoration(
                                  color: panel,
                                  border: Border(
                                    left: BorderSide(color: Colors.white10),
                                  ),
                                ),
                                child: tools,
                              ),
                            ],
                          )
                        : screen;
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _PlayIntent extends Intent {
  const _PlayIntent();
}

class _UndoIntent extends Intent {
  const _UndoIntent();
}

class _RedoIntent extends Intent {
  const _RedoIntent();
}

class _Ruler extends CustomPainter {
  _Ruler(this.zoom, this.time);
  final double zoom, time;
  @override
  void paint(Canvas canvas, Size size) {
    final step = zoom < 20
        ? 10
        : zoom < 60
        ? 5
        : 1;
    for (var seconds = 0; seconds * zoom < size.width; seconds += step) {
      final x = seconds * zoom;
      canvas.drawLine(
        Offset(x, 20),
        Offset(x, 25),
        Paint()..color = Colors.white24,
      );
      final text = TextPainter(
        text: TextSpan(
          text: '${seconds}s',
          style: const TextStyle(color: Colors.white38, fontSize: 9),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      text.paint(canvas, Offset(x + 3, 5));
    }
  }

  @override
  bool shouldRepaint(covariant _Ruler old) => old.zoom != zoom;
}
