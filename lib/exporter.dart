import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'project.dart';
import 'ffmpeg_plan.dart';

class CutExporter {
  static const channel = MethodChannel('p_cut/render');
  Process? _process;
  bool _cancelled = false;
  String? ffmpegPath;
  void resetCancellation() {
    _cancelled = false;
  }

  Future<void> cancel() async {
    _cancelled = true;
    _process?.kill();
    if (Platform.isAndroid) await channel.invokeMethod('cancel');
  }

  Future<String> findFfmpeg() async {
    final candidates = [
      if (ffmpegPath != null) ffmpegPath!,
      '${File(Platform.resolvedExecutable).parent.path}/ffmpeg.exe',
      'ffmpeg',
    ];
    for (final path in candidates) {
      try {
        final r = await Process.run(path, ['-version']);
        if (r.exitCode == 0) return path;
      } catch (_) {}
    }
    throw StateError(
      'Windows export needs FFmpeg. Select ffmpeg.exe in the export dialog. Keep ffprobe.exe beside it.',
    );
  }

  Future<File> export(
    Project p,
    Directory temp,
    Map<String, String> overlays,
    void Function(double, String) progress,
  ) async {
    p.validate(exporting: true);
    _cancelled = false;
    for (final path in [
      ...p.clips.map((c) => c.path),
      ...p.audio.map((a) => a.path),
    ]) {
      if (!await File(path).exists())
        throw StateError(
          'A project media file is missing. Re-import it before export.',
        );
    }
    final output = File(
      '${temp.path}/P-cut-${DateTime.now().millisecondsSinceEpoch}.mp4',
    );
    Timer? timer;
    var lastProgress = 0.0;
    try {
      if (Platform.isAndroid) {
        timer = Timer.periodic(const Duration(milliseconds: 250), (_) async {
          try {
            final v = await channel.invokeMethod<num>('progress');
            lastProgress = (v?.toDouble() ?? 0).clamp(lastProgress, 1);
            progress(lastProgress, 'Rendering video');
          } catch (_) {}
        });
        await channel.invokeMethod('export', {
          'project': p.toJson(),
          'overlays': overlays,
          'output': output.path,
        });
      } else {
        final ffmpeg = await findFfmpeg();
        final parent = File(ffmpeg).parent.path;
        final probe = ffmpeg == 'ffmpeg'
            ? 'ffprobe'
            : '$parent/${Platform.isWindows ? 'ffprobe.exe' : 'ffprobe'}';
        final files = <String>[];
        for (var i = 0; i < p.clips.length; i++) {
          if (_cancelled) throw StateError('Export cancelled');
          final c = p.clips[i];
          var hasAudio = false;
          if (c.kind == 'video') {
            final result = await Process.run(probe, [
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
            if (result.exitCode != 0)
              throw StateError('FFprobe could not inspect an input video.');
            hasAudio = result.stdout.toString().trim().isNotEmpty;
          }
          final normalized = '${temp.path}/clip-$i.mp4';
          files.add(normalized);
          await run(
            ffmpeg,
            clipArguments(p, c, normalized, hasAudio: hasAudio),
            c.duration,
            (v) => progress(
              .7 * (i + v) / p.clips.length,
              'Rendering clip ${i + 1} of ${p.clips.length}',
            ),
          );
        }
        if (p.clips.any((c) => c.transition > 0) && files.length > 1) {
          var joined = files.first;
          for (var i = 1; i < files.length; i++) {
            final next = '${temp.path}/joined-$i.mp4';
            await run(
              ffmpeg,
              joinArguments(p, i, joined, files[i], next),
              p.offset(i) + p.clips[i].duration,
              (v) => progress(
                .7 + .15 * (i - 1 + v) / (files.length - 1),
                'Rendering crossfades',
              ),
            );
            if (joined.contains('/joined-')) await File(joined).delete();
            joined = next;
          }
          files
            ..clear()
            ..add(joined);
        }
        String? captionVideo;
        if (p.captions.isNotEmpty) {
          final subtitleList = File('${temp.path}/captions.txt');
          await subtitleList.writeAsString(captionManifest(p, overlays));
          captionVideo = '${temp.path}/captions.mkv';
          await run(
            ffmpeg,
            captionArguments(p, subtitleList.path, captionVideo),
            p.duration,
            (v) => progress(.85 + .05 * v, 'Rendering subtitles'),
          );
        }
        final manifest = File('${temp.path}/concat.txt');
        await manifest.writeAsString(concatManifest(files));
        await run(
          ffmpeg,
          finishArguments(
            p,
            manifest.path,
            overlays,
            output.path,
            captionVideo: captionVideo,
          ),
          p.duration,
          (v) => progress(.9 + .1 * v, 'Mixing music and layers'),
        );
      }
      if (_cancelled) throw StateError('Export cancelled');
      if (!await output.exists() || await output.length() == 0)
        throw StateError('The export did not produce a video.');
      progress(1, 'Export complete');
      return output;
    } catch (_) {
      if (await output.exists()) await output.delete();
      rethrow;
    } finally {
      timer?.cancel();
      _process = null;
    }
  }

  Future<void> run(
    String executable,
    List<String> args,
    double duration,
    void Function(double) progress,
  ) async {
    if (_cancelled) throw StateError('Export cancelled');
    final safeArgs = args.toList();
    final filter = safeArgs.indexOf('-filter_complex');
    if (filter >= 0) {
      final file = File('${File(args.last).parent.path}/filter-${newId()}.txt');
      await file.writeAsString(safeArgs[filter + 1]);
      safeArgs[filter] = '-filter_complex_script';
      safeArgs[filter + 1] = file.path;
    }
    final proc = await Process.start(executable, safeArgs, runInShell: false);
    _process = proc;
    if (_cancelled) proc.kill();
    var errors = '';
    final stderrDone = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .listen((s) {
          errors += s;
          if (errors.length > 12000)
            errors = errors.substring(errors.length - 12000);
        })
        .asFuture<void>();
    final stdoutDone = proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen((line) {
          if (line.startsWith('out_time_us=')) {
            final us = int.tryParse(line.substring(12));
            if (us != null) progress((us / 1000000 / duration).clamp(0, 1));
          }
        })
        .asFuture<void>();
    final code = await proc.exitCode;
    await Future.wait([stderrDone, stdoutDone]);
    _process = null;
    if (_cancelled) throw StateError('Export cancelled');
    if (code != 0)
      throw StateError(
        'Video rendering failed. ${errors.length > 1800 ? errors.substring(errors.length - 1800) : errors}',
      );
  }

  static Future<String> publish(File file) async =>
      await channel.invokeMethod<String>('publish', {'path': file.path}) ??
      'Saved to Movies/P-cut';
}
