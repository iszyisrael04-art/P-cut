import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:media_kit/media_kit.dart';
import 'project.dart';
import 'preview.dart';
import 'painting.dart';
import 'main.dart' show stamp;

class VoiceCapture {
  VoiceCapture(this.file, this.duration, this.start);
  final File file;
  final double duration, start;
}

class VoiceoverPage extends StatefulWidget {
  const VoiceoverPage({super.key, required this.project, required this.start});
  final Project project;
  final double start;
  @override
  State<VoiceoverPage> createState() => _VoiceoverPageState();
}

class _VoiceoverPageState extends State<VoiceoverPage>
    with WidgetsBindingObserver {
  final recorder = AudioRecorder(), watch = Stopwatch();
  Timer? timer;
  File? file;
  final retired = <File>[];
  bool recording = false,
      paused = false,
      busy = false,
      accepted = false,
      listening = false;
  double seconds = 0;
  String? error;
  late final silent = widget.project.copy({
    'clips': widget.project.clips
        .map((c) => c.copy({'volume': 0}).toJson())
        .toList(),
    'audio': [],
  });
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    timer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      if (!mounted) return;
      if (recording && !paused) {
        setState(() => seconds = watch.elapsedMilliseconds / 1000);
        if (seconds >= remaining) stop();
      }
      if (listening) {
        setState(() => seconds += .05);
        if (seconds >= recordedLength) setState(() => listening = false);
      }
    });
  }

  double get remaining =>
      (widget.project.duration - widget.start).clamp(.1, 300.0);
  double recordedLength = 0;
  Future<void> start() async {
    if (busy || recording) return;
    setState(() => busy = true);
    try {
      if (!await recorder.hasPermission())
        throw StateError(
          'Allow microphone access in Settings to record a voiceover.',
        );
      final dir = await getTemporaryDirectory();
      file = File('${dir.path}/pcut-voice-${newId()}.m4a');
      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 44100,
          bitRate: 128000,
          numChannels: 1,
        ),
        path: file!.path,
      );
      watch
        ..reset()
        ..start();
      if (mounted)
        setState(() {
          recording = true;
          paused = false;
          error = null;
          seconds = 0;
        });
    } catch (e) {
      if (mounted)
        setState(() => error = e.toString().replaceFirst('Bad state: ', ''));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> stop() async {
    if (busy || !recording) return;
    setState(() => busy = true);
    watch.stop();
    try {
      final path = await recorder.stop();
      if (path == null) throw StateError('The recording could not be saved.');
      file = File(path);
      final player = Player(
        configuration: const PlayerConfiguration(bufferSize: 512 * 1024),
      );
      try {
        await player.open(Media(path), play: false);
        final d = player.state.duration.inMilliseconds > 0
            ? player.state.duration
            : await player.stream.duration
                  .firstWhere((d) => d.inMilliseconds > 0)
                  .timeout(const Duration(seconds: 10));
        recordedLength = (d.inMilliseconds / 1000).clamp(0.0, remaining);
      } finally {
        await player.dispose();
      }
      if (recordedLength < .1)
        throw StateError('Record at least a moment of audio before stopping.');
      if (mounted)
        setState(() {
          recording = false;
          seconds = 0;
        });
    } catch (e) {
      if (mounted)
        setState(() {
          recording = false;
          error = e.toString();
        });
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> pause() async {
    if (busy || !recording) return;
    setState(() => busy = true);
    try {
      if (paused) {
        await recorder.resume();
        watch.start();
      } else {
        await recorder.pause();
        watch.stop();
      }
      if (mounted) setState(() => paused = !paused);
    } catch (_) {
      if (mounted)
        setState(() => error = 'The recorder could not change pause state.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.paused) {
      if (recording) stop();
      setState(() => listening = false);
    }
  }

  Future<void> cleanup() async {
    try {
      await recorder.dispose();
    } catch (_) {}
    for (final f in [...retired, if (!accepted && file != null) file!]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    watch.stop();
    WidgetsBinding.instance.removeObserver(this);
    cleanup();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final playback = file != null && !recording && recordedLength > 0
        ? silent.copy({
            'audio': [
              AudioTrack(
                id: 'voice-preview',
                path: file!.path,
                sourceDuration: recordedLength,
                start: widget.start,
                length: recordedLength,
                volume: 1,
              ).toJson(),
            ],
          })
        : silent;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Voiceover')),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                Expanded(
                  child: ProjectPreview(
                    project: playback,
                    time: widget.start + seconds,
                    playing: recording && !paused || listening,
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  stamp(seconds),
                  style: const TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Reference audio is muted. Your microphone records only your voice.\nUp to five minutes per recording.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: Colors.orange),
                    ),
                  ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    if (recording) ...[
                      OutlinedButton.icon(
                        onPressed: busy ? null : pause,
                        icon: Icon(paused ? Icons.play_arrow : Icons.pause),
                        label: Text(paused ? 'Resume' : 'Pause'),
                      ),
                      FilledButton.icon(
                        onPressed: busy ? null : stop,
                        icon: const Icon(Icons.stop),
                        label: const Text('Stop'),
                      ),
                    ] else if (recordedLength > 0) ...[
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () {
                                setState(() {
                                  if (!listening) seconds = 0;
                                  listening = !listening;
                                });
                              },
                        icon: Icon(listening ? Icons.pause : Icons.play_arrow),
                        label: const Text('Listen'),
                      ),
                      OutlinedButton(
                        onPressed: busy
                            ? null
                            : () async {
                                setState(() => listening = false);
                                if (file != null) retired.add(file!);
                                if (mounted)
                                  setState(() {
                                    recordedLength = 0;
                                    seconds = 0;
                                    file = null;
                                  });
                              },
                        child: const Text('Retake'),
                      ),
                      FilledButton.icon(
                        onPressed: busy
                            ? null
                            : () {
                                accepted = true;
                                Navigator.pop(
                                  context,
                                  VoiceCapture(
                                    file!,
                                    recordedLength,
                                    widget.start,
                                  ),
                                );
                              },
                        icon: const Icon(Icons.check),
                        label: const Text('Use voiceover'),
                      ),
                    ] else
                      FilledButton.icon(
                        onPressed: busy ? null : start,
                        icon: const Icon(Icons.mic),
                        label: const Text('Record'),
                      ),
                  ],
                ),
                if (busy)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(color: accent),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
