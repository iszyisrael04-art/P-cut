import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'project.dart';
import 'subtitles.dart';
import 'exporter.dart';
import 'audio_plan.dart';

/// Optional offline Windows adapter. No media is uploaded and no models download silently.
class TranscriptionPage extends StatefulWidget {
  const TranscriptionPage({super.key, required this.project});
  final Project project;
  @override
  State<TranscriptionPage> createState() => _TranscriptionPageState();
}

class _TranscriptionPageState extends State<TranscriptionPage> {
  final engine = CutExporter();
  Process? recognizer;
  String? cli, model, error;
  String language = 'auto', status = '';
  double progress = 0;
  bool busy = false, cancelled = false;
  @override
  void initState() {
    super.initState();
    loadSettings();
  }

  Future<File> settingsFile() async => File(
    '${(await getApplicationDocumentsDirectory()).path}/P-cut/speech-settings.json',
  );
  Future<void> loadSettings() async {
    try {
      final data =
          jsonDecode(await (await settingsFile()).readAsString()) as Map;
      if (mounted)
        setState(() {
          cli = data['cli'] as String?;
          model = data['model'] as String?;
          engine.ffmpegPath = data['ffmpeg'] as String?;
          language = data['language'] as String? ?? 'auto';
          if (!['auto', 'en', 'yo', 'fr'].contains(language)) language = 'auto';
        });
    } catch (_) {}
  }

  Future<void> saveSettings() async {
    try {
      final file = await settingsFile();
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'cli': cli,
          'model': model,
          'ffmpeg': engine.ffmpegPath,
          'language': language,
        }),
      );
    } catch (_) {}
  }

  Future<void> choose(String type) async {
    final file = await FilePicker.pickFile(
      type: FileType.custom,
      allowedExtensions: type == 'model' ? ['bin', 'ggml', 'gguf'] : ['exe'],
    );
    if (file == null || !mounted) return;
    setState(() {
      switch (type) {
        case 'model':
          model = file.path;
        case 'cli':
          cli = file.path;
        default:
          engine.ffmpegPath = file.path;
      }
    });
    await saveSettings();
  }

  void update(double value, String label) {
    if (mounted)
      setState(() {
        progress = value;
        status = label;
      });
  }

  Future<void> cancel() async {
    cancelled = true;
    recognizer?.kill();
    await engine.cancel();
  }

  Future<void> transcribe() async {
    if (busy || cli == null || model == null) return;
    engine.resetCancellation();
    setState(() {
      busy = true;
      cancelled = false;
      error = null;
      progress = 0;
      status = 'Preparing audio';
    });
    Directory? work;
    try {
      final p = widget.project;
      p.validate(exporting: true);
      if (!await File(cli!).exists() || !await File(model!).exists())
        throw StateError(
          'Choose an existing whisper-cli executable and a compatible GGML model.',
        );
      final ffmpeg = await engine.findFfmpeg(),
          probe = ffmpeg == 'ffmpeg'
              ? 'ffprobe'
              : '${File(ffmpeg).parent.path}/ffprobe.exe';
      final temp = await getTemporaryDirectory();
      work = await Directory('${temp.path}/pcut-speech-${newId()}').create();
      var joined = '';
      for (var i = 0; i < p.clips.length; i++) {
        if (cancelled) throw StateError('Transcription cancelled');
        final c = p.clips[i];
        var hasAudio = false;
        if (c.kind == 'video') {
          final check = await Process.run(probe, [
            '-v',
            'error',
            '-select_streams',
            'a:0',
            '-show_entries',
            'stream=index',
            '-of',
            'csv=p=0',
            c.path,
          ]);
          if (check.exitCode != 0)
            throw StateError('A clip could not be inspected.');
          hasAudio = check.stdout.toString().trim().isNotEmpty;
        }
        final audio = '${work.path}/audio-$i.wav';
        await engine.run(
          ffmpeg,
          audioClipArguments(c, audio, hasAudio: hasAudio),
          c.duration,
          (v) => update(.35 * (i + v) / p.clips.length, 'Preparing clip audio'),
        );
        if (i == 0) {
          joined = audio;
        } else {
          final next = '${work.path}/joined-$i.wav';
          await engine.run(
            ffmpeg,
            joinAudioArguments(p, i, joined, audio, next),
            p.offset(i) + c.duration,
            (_) => {},
          );
          await File(joined).delete();
          await File(audio).delete();
          joined = next;
        }
      }
      if (cancelled) throw StateError('Transcription cancelled');
      final wave = '${work.path}/speech.wav';
      await engine.run(
        ffmpeg,
        mixAudioArguments(p, joined, wave),
        p.duration,
        (v) => update(.35 + .1 * v, 'Mixing voice and music'),
      );
      update(.45, 'Recognizing speech locally — this may take several minutes');
      final prefix = '${work.path}/recognized';
      recognizer = await Process.start(cli!, [
        '-m',
        model!,
        '-f',
        wave,
        '-osrt',
        '-of',
        prefix,
        '-l',
        language,
        '-t',
        '2',
      ], runInShell: false);
      if (cancelled) recognizer!.kill();
      var diagnostic = '';
      void log(String chunk) {
        diagnostic += chunk;
        if (diagnostic.length > 6000)
          diagnostic = diagnostic.substring(diagnostic.length - 6000);
        final matches = RegExp(r'(\d{1,3})%').allMatches(chunk);
        if (matches.isNotEmpty) {
          final n = int.parse(matches.last.group(1)!);
          update(
            .45 + .5 * (n / 100).clamp(0, 1),
            'Recognizing speech locally',
          );
        }
      }

      final drains = [
        recognizer!.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(log)
            .asFuture<void>(),
        recognizer!.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .listen(log)
            .asFuture<void>(),
      ];
      final code = await recognizer!.exitCode;
      await Future.wait(drains);
      recognizer = null;
      if (cancelled) throw StateError('Transcription cancelled');
      if (code != 0)
        throw StateError(
          'The speech engine could not finish. Check that the model and executable match and support this CPU.',
        );
      final file = File('$prefix.srt');
      if (!await file.exists())
        throw StateError('The speech engine did not create subtitles.');
      final parsed = parseSrt(
        await file.readAsString(),
        prefix: 'speech-${newId()}',
      );
      final cues = parsed
          .where((c) => c.start < p.duration)
          .map(
            (c) => SubtitleCue(
              id: c.id,
              start: c.start,
              end: c.end.clamp(0.0, p.duration),
              text: c.text,
            ),
          )
          .toList();
      if (cues.isEmpty)
        throw StateError(
          'No speech was detected. Try a clearer voice track or another language.',
        );
      if (mounted) Navigator.pop(context, cues);
    } catch (e) {
      if (mounted)
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      recognizer = null;
      if (work != null) {
        try {
          await work.delete(recursive: true);
        } catch (_) {}
      }
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void dispose() {
    cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Offline auto captions')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Windows speech setup',
            style: TextStyle(fontSize: 23, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          const Text(
            'Select whisper-cli.exe and a compatible local GGML speech model. These are separate downloads. No audio leaves this device. Small models are better suited to a 4 GB RAM computer. Review generated subtitles before using them.',
          ),
          const SizedBox(height: 20),
          for (final item in [
            ('cli', 'Speech engine', cli),
            ('model', 'Speech model', model),
            ('ffmpeg', 'FFmpeg', engine.ffmpegPath),
          ])
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(item.$2),
              subtitle: Text(
                item.$3 ?? 'Choose file',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: IconButton(
                onPressed: busy ? null : () => choose(item.$1),
                icon: const Icon(Icons.folder_open),
              ),
            ),
          DropdownButtonFormField<String>(
            initialValue: language,
            decoration: const InputDecoration(labelText: 'Speech language'),
            items: const [
              DropdownMenuItem(
                value: 'auto',
                child: Text('Detect automatically'),
              ),
              DropdownMenuItem(value: 'en', child: Text('English')),
              DropdownMenuItem(value: 'yo', child: Text('Yoruba')),
              DropdownMenuItem(value: 'fr', child: Text('French')),
            ],
            onChanged: busy
                ? null
                : (v) {
                    setState(() => language = v ?? 'auto');
                    saveSettings();
                  },
          ),
          const SizedBox(height: 20),
          if (error != null)
            Text(error!, style: const TextStyle(color: Colors.orange)),
          if (busy) ...[
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 12),
            Text(status),
            TextButton(onPressed: cancel, child: const Text('Cancel')),
          ] else
            FilledButton.icon(
              onPressed: cli == null || model == null ? null : transcribe,
              icon: const Icon(Icons.closed_caption),
              label: const Text('Generate subtitles'),
            ),
        ],
      ),
    ),
  );
}
