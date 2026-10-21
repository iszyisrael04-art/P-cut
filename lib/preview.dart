import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'project.dart';
import 'painting.dart';

class ProjectPreview extends StatefulWidget {
  const ProjectPreview({
    super.key,
    required this.project,
    required this.time,
    required this.playing,
    this.selectedLayer,
    this.onMove,
    this.onMoveEnd,
  });
  final Project project;
  final double time;
  final bool playing;
  final String? selectedLayer;
  final VoidCallback? onMoveEnd;
  final void Function(double, double)? onMove;
  @override
  State<ProjectPreview> createState() => _ProjectPreviewState();
}

class _VideoSlot {
  final Player player = Player(
    configuration: const PlayerConfiguration(bufferSize: 3 * 1024 * 1024),
  );
  late final VideoController controller = VideoController(player);
  String? opened;
}

/// Retains only active clips: two decoders during crossfades, one otherwise.
class _ProjectPreviewState extends State<ProjectPreview> {
  final slots = <String, _VideoSlot>{}, audio = <String, Player>{};
  final audioPaths = <String, String>{};
  bool syncing = false, again = false, closed = false;
  String? error;
  @override
  void initState() {
    super.initState();
    sync();
  }

  @override
  void didUpdateWidget(covariant ProjectPreview old) {
    super.didUpdateWidget(old);
    sync();
  }

  Future<void> transport(
    Player p,
    double target,
    double rate,
    double volume,
    bool playing,
  ) async {
    if (closed) return;
    if ((p.state.position.inMilliseconds / 1000 - target).abs() > .25 ||
        !playing)
      await p.seek(Duration(milliseconds: (target * 1000).round()));
    if (p.state.rate != rate) await p.setRate(rate);
    if ((p.state.volume - volume).abs() > .2) await p.setVolume(volume);
    if (playing && !p.state.playing) await p.play();
    if (!playing && p.state.playing) await p.pause();
  }

  Future<void> sync() async {
    if (syncing) {
      again = true;
      return;
    }
    syncing = true;
    try {
      do {
        again = false;
        if (closed) return;
        final p = widget.project, t = widget.time;
        var active = p.activeClips(t);
        if (active.isEmpty && p.clips.isNotEmpty && t >= p.duration)
          active = [p.clips.length - 1];
        final ids = {
          for (final i in active)
            if (p.clips[i].kind == 'video') p.clips[i].id,
        };
        for (final id in slots.keys.toList()) {
          if (!ids.contains(id)) await slots.remove(id)?.player.dispose();
        }
        for (final i in active) {
          if (closed) return;
          final c = p.clips[i];
          if (c.kind != 'video') continue;
          final slot = slots.putIfAbsent(c.id, () => _VideoSlot());
          if (slot.opened != c.path) {
            slot.opened = c.path;
            await slot.player.open(Media(c.path), play: false);
            if (mounted) setState(() => error = null);
          }
          final target = (c.start + (t - p.offset(i)) * c.speed).clamp(
            c.start,
            c.end,
          );
          await transport(
            slot.player,
            target,
            c.speed,
            c.volume * p.clipGain(i, t) * 100,
            widget.playing,
          );
        }
        final aids = p.audio.map((a) => a.id).toSet();
        for (final id in audio.keys.toList()) {
          if (!aids.contains(id)) {
            await audio.remove(id)?.dispose();
            audioPaths.remove(id);
          }
        }
        for (final a in p.audio) {
          if (closed) return;
          if (!a.active(t)) {
            await audio[a.id]?.pause();
            continue;
          }
          final sound = audio.putIfAbsent(
            a.id,
            () => Player(
              configuration: const PlayerConfiguration(bufferSize: 1024 * 1024),
            ),
          );
          if (audioPaths[a.id] != a.path) {
            audioPaths[a.id] = a.path;
            await sound.open(Media(a.path), play: false);
          }
          await transport(
            sound,
            a.inPoint + t - a.start,
            1,
            a.gainAt(t) * 100,
            widget.playing,
          );
        }
      } while (again && !closed);
    } catch (_) {
      if (mounted)
        setState(
          () => error =
              'This media could not play. Try a compatible MP4 or WAV file.',
        );
    } finally {
      syncing = false;
    }
  }

  @override
  void dispose() {
    closed = true;
    for (final s in slots.values) {
      s.player.dispose();
    }
    for (final p in audio.values) {
      p.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.project, t = widget.time;
    var active = p.activeClips(t);
    if (active.isEmpty && p.clips.isNotEmpty && t >= p.duration)
      active = [p.clips.length - 1];
    return Center(
      child: AspectRatio(
        aspectRatio: p.ratio,
        child: LayoutBuilder(
          builder: (context, box) {
            Widget visual(int index) {
              final c = p.clips[index],
                  fit = c.fit == 'cover' ? BoxFit.cover : BoxFit.contain;
              final slot = slots[c.id];
              Widget image = c.kind == 'image'
                  ? Image.file(
                      File(c.path),
                      fit: fit,
                      cacheWidth: 1280,
                      errorBuilder: (_, e, s) =>
                          const Icon(Icons.broken_image_outlined),
                    )
                  : slot == null
                  ? const Center(child: CircularProgressIndicator())
                  : Video(
                      controller: slot.controller,
                      fit: fit,
                      controls: NoVideoControls,
                    );
              image = ColorFiltered(
                colorFilter: ColorFilter.matrix(colourMatrix(c)),
                child: RotatedBox(quarterTurns: c.rotation, child: image),
              );
              final d = p.overlap(index - 1);
              final alpha = active.length > 1 && index == active.last && d > 0
                  ? ((t - p.offset(index)) / d).clamp(0.0, 1.0)
                  : 1.0;
              return Opacity(
                opacity: alpha,
                child: ColoredBox(color: Colors.black, child: image),
              );
            }

            return ClipRect(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (active.isEmpty)
                    const ColoredBox(
                      color: Colors.black,
                      child: Center(
                        child: Icon(
                          Icons.add_to_photos_outlined,
                          size: 54,
                          color: Colors.white24,
                        ),
                      ),
                    ),
                  for (final i in active) visual(i),
                  GestureDetector(
                    onPanEnd: (_) => widget.onMoveEnd?.call(),
                    onPanCancel: widget.onMoveEnd,
                    onPanUpdate: widget.onMove == null
                        ? null
                        : (d) => widget.onMove!(
                            d.delta.dx / box.maxWidth,
                            d.delta.dy / box.maxHeight,
                          ),
                    child: CustomPaint(
                      painter: LayersPainter(
                        p.layers.where((l) => l.active(t)).toList(),
                        selected: widget.selectedLayer,
                        time: t,
                      ),
                    ),
                  ),
                  for (final cue in p.captions)
                    if (cue.active(t))
                      IgnorePointer(
                        child: CustomPaint(painter: CaptionPainter(cue.text)),
                      ),
                  if (error != null)
                    Positioned(
                      bottom: 8,
                      left: 8,
                      right: 8,
                      child: Text(
                        error!,
                        style: const TextStyle(
                          color: Colors.orange,
                          fontSize: 11,
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
