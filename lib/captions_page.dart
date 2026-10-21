import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'subtitles.dart';
import 'project.dart';
import 'transcription.dart';
import 'main.dart' show showError, confirm;

class CaptionsPage extends StatefulWidget {
  const CaptionsPage({
    super.key,
    required this.initial,
    required this.duration,
    required this.directory,
    this.project,
  });
  final List<SubtitleCue> initial;
  final double duration;
  final Directory directory;
  final Project? project;
  @override
  State<CaptionsPage> createState() => _CaptionsPageState();
}

class _CaptionsPageState extends State<CaptionsPage> {
  late List<SubtitleCue> cues = widget.initial.toList();
  bool busy = false;
  Future<void> edit([int? index]) async {
    final cue = index == null ? null : cues[index];
    final text = TextEditingController(text: cue?.text ?? ''),
        start = TextEditingController(text: subtitleTime(cue?.start ?? 0)),
        end = TextEditingController(
          text: subtitleTime(
            cue?.end ?? (widget.duration < 3 ? widget.duration : 3),
          ),
        );
    String? error;
    final changed = await showDialog<SubtitleCue>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (context, refresh) => AlertDialog(
          title: Text(cue == null ? 'Add subtitle' : 'Edit subtitle'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: text,
                  maxLines: 4,
                  minLines: 2,
                  maxLength: 300,
                  decoration: const InputDecoration(labelText: 'Subtitle text'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: start,
                  decoration: const InputDecoration(
                    labelText: 'Start · HH:MM:SS,mmm',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: end,
                  decoration: const InputDecoration(
                    labelText: 'End · HH:MM:SS,mmm',
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.orange),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                try {
                  final a = parseSubtitleTime(start.text),
                      b = parseSubtitleTime(end.text);
                  if (a < 0 ||
                      b <= a ||
                      b > widget.duration ||
                      text.text.trim().isEmpty)
                    throw const FormatException(
                      'Enter text and an interval inside the video.',
                    );
                  final next = SubtitleCue(
                    id:
                        cue?.id ??
                        'caption-${DateTime.now().microsecondsSinceEpoch}',
                    start: a,
                    end: b,
                    text: text.text.trim(),
                  );
                  final all = cues.toList();
                  if (index != null) all.removeAt(index);
                  all.add(next);
                  parseSrt(writeSrt(all));
                  Navigator.pop(dialog, next);
                } catch (e) {
                  refresh(
                    () => error = e.toString().replaceFirst(
                      'FormatException: ',
                      '',
                    ),
                  );
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 400));
    text.dispose();
    start.dispose();
    end.dispose();
    if (changed != null && mounted) {
      setState(() {
        if (index != null) cues.removeAt(index);
        cues.add(changed);
        cues.sort((a, b) => a.start.compareTo(b.start));
      });
    }
  }

  Future<void> import() async {
    final result = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: ['srt'],
    );
    if (result == null || !mounted) return;
    try {
      final path = result.path;
      if (path == null) throw StateError('Choose a local subtitle file.');
      final source = File(path);
      if (await source.length() > 2 * 1024 * 1024)
        throw const FormatException('This subtitle file is too large.');
      final parsed = parseSrt(
        await source.readAsString(),
        prefix: 'caption-${DateTime.now().microsecondsSinceEpoch}',
      );
      if (parsed.any((c) => c.end > widget.duration))
        throw const FormatException(
          'Some subtitles extend past this video. Correct their timings before importing.',
        );
      if (cues.isNotEmpty &&
          mounted &&
          !await confirm(
            context,
            'Replace subtitles?',
            'Imported subtitles will replace this project’s subtitle track.',
          ))
        return;
      if (mounted) setState(() => cues = parsed);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  Future<void> autoCaptions() async {
    if (widget.project == null) return;
    if (cues.isNotEmpty &&
        !await confirm(
          context,
          'Replace subtitles?',
          'Generated subtitles will replace the current subtitle track.',
        ))
      return;
    if (!mounted) return;
    final result = await Navigator.push<List<SubtitleCue>>(
      context,
      MaterialPageRoute(
        builder: (_) => TranscriptionPage(project: widget.project!),
      ),
    );
    if (result != null && mounted) setState(() => cues = result);
  }

  Future<void> export() async {
    try {
      await widget.directory.create(recursive: true);
      final file = File('${widget.directory.path}/subtitles.srt');
      await file.writeAsString(writeSrt(cues));
      final destination = await FilePicker.saveFile(
        fileName: 'P-cut-subtitles.srt',
        type: FileType.custom,
        allowedExtensions: ['srt'],
        bytes: Platform.isAndroid ? await file.readAsBytes() : null,
      );
      if (destination != null && Platform.isWindows && destination != file.path)
        await file.copy(destination);
      if (mounted) showError(context, 'SRT saved: ${file.path}');
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text('Subtitles · ${cues.length}'),
      actions: [
        if (Platform.isWindows && widget.project != null)
          IconButton(
            tooltip: 'Offline auto captions',
            onPressed: busy ? null : autoCaptions,
            icon: const Icon(Icons.auto_awesome),
          ),

        IconButton(
          tooltip: 'Import SRT',
          onPressed: busy ? null : import,
          icon: const Icon(Icons.file_open_outlined),
        ),
        IconButton(
          tooltip: 'Export SRT',
          onPressed: cues.isEmpty ? null : export,
          icon: const Icon(Icons.save_alt),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, cues),
          child: const Text('Apply'),
        ),
      ],
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: cues.length >= 500 ? null : () => edit(),
      child: const Icon(Icons.add),
    ),
    body: cues.isEmpty
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.closed_caption_outlined, size: 64),
                  const SizedBox(height: 16),
                  const Text(
                    'Add subtitles or import an SRT file.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: import,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('Import SRT'),
                  ),
                ],
              ),
            ),
          )
        : ListView.builder(
            padding: const EdgeInsets.only(bottom: 90),
            itemCount: cues.length,
            itemBuilder: (context, index) {
              final cue = cues[index];
              return ListTile(
                title: Text(cue.text),
                subtitle: Text(
                  '${subtitleTime(cue.start)} → ${subtitleTime(cue.end)}',
                ),
                onTap: () => edit(index),
                trailing: IconButton(
                  tooltip: 'Delete subtitle',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => setState(() => cues.removeAt(index)),
                ),
              );
            },
          ),
  );
}
