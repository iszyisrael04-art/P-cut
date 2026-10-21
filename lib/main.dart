import 'dart:io';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'storage.dart';
import 'project.dart' hide Clip;
import 'editor.dart';
import 'painting.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  try {
    final store = await ProjectStore.open();
    runApp(PCutApp(store: store));
  } catch (e) {
    runApp(
      MaterialApp(
        home: Scaffold(
          body: Center(child: Text('P-cut could not open local storage.\n$e')),
        ),
      ),
    );
  }
}

class PCutApp extends StatelessWidget {
  const PCutApp({super.key, required this.store});
  final ProjectStore store;
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'P-cut',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: const Color(0xff0d0f14),
      colorScheme: ColorScheme.fromSeed(
        seedColor: accent,
        brightness: Brightness.dark,
        primary: accent,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xff0d0f14),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: const CardThemeData(color: panel),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: panel,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
      ),
    ),
    home: ProjectsPage(store: store),
  );
}

class ProjectsPage extends StatefulWidget {
  const ProjectsPage({super.key, required this.store});
  final ProjectStore store;
  @override
  State<ProjectsPage> createState() => _ProjectsPageState();
}

class _ProjectsPageState extends State<ProjectsPage> {
  List<Project>? projects;
  String? error;
  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    try {
      final p = await widget.store.list();
      if (mounted) setState(() => projects = p);
    } catch (_) {
      if (mounted) setState(() => error = 'Projects could not load.');
    }
  }

  Future<void> open(Project p) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CutEditor(store: widget.store, initial: p),
      ),
    );
    await reload();
  }

  Future<void> create() async {
    final name = await askText(context, 'Name your project', 'My first cut');
    if (name == null || name.trim().isEmpty) return;
    final p = Project(id: newId(), name: name.trim());
    try {
      await widget.store.save(p);
      if (mounted) await open(p);
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Row(
        children: [
          Mark(size: 32),
          SizedBox(width: 12),
          Text(
            'P-cut',
            style: TextStyle(fontWeight: FontWeight.w800, letterSpacing: -1),
          ),
        ],
      ),
      actions: [
        IconButton(
          tooltip: 'About P-cut',
          icon: const Icon(Icons.info_outline),
          onPressed: () => showAboutDialog(
            context: context,
            applicationName: 'P-cut',
            applicationVersion: '0.2.1 · native editor',
            applicationIcon: const Mark(),
            children: const [
              Text(
                'Your files stay on this device. Android uses Media3. Windows export requires FFmpeg and FFprobe. Local projects contain their own imported media copies.',
              ),
            ],
          ),
        ),
      ],
    ),
    body: projects == null
        ? Center(
            child: error == null
                ? const CircularProgressIndicator()
                : Text(error!),
          )
        : LayoutBuilder(
            builder: (context, box) => ListView(
              padding: EdgeInsets.symmetric(
                horizontal: box.maxWidth > 900 ? 64 : 20,
                vertical: 24,
              ),
              children: [
                const Text(
                  'Your next great cut.',
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -1.4,
                  ),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Make something worth watching.',
                  style: TextStyle(color: Colors.white54, fontSize: 16),
                ),
                const SizedBox(height: 28),
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: create,
                    child: const Padding(
                      padding: EdgeInsets.all(28),
                      child: Row(
                        children: [
                          Icon(
                            Icons.add_circle_rounded,
                            size: 48,
                            color: accent,
                          ),
                          SizedBox(width: 18),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'New project',
                                  style: TextStyle(
                                    fontSize: 21,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Videos, photos and a blank timeline',
                                  style: TextStyle(color: Colors.white54),
                                ),
                              ],
                            ),
                          ),
                          Icon(Icons.arrow_forward_rounded),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  'PROJECTS · ${projects!.length}',
                  style: const TextStyle(
                    letterSpacing: 2,
                    color: Colors.white54,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 16),
                if (projects!.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 48),
                    child: Center(
                      child: Text(
                        'Your saved edits will appear here.',
                        style: TextStyle(color: Colors.white38),
                      ),
                    ),
                  ),
                for (final p in projects!)
                  Card(
                    child: ListTile(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      leading: SizedBox(
                        width: 64,
                        height: 64,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child:
                              p.clips.isNotEmpty &&
                                  (p.clips.first.cover != null ||
                                      p.clips.first.kind == 'image')
                              ? Image.file(
                                  File(
                                    p.clips.first.cover ?? p.clips.first.path,
                                  ),
                                  fit: BoxFit.cover,
                                  cacheWidth: 180,
                                  errorBuilder: (_, e, s) =>
                                      const Icon(Icons.movie_outlined),
                                )
                              : const ColoredBox(
                                  color: Color(0xff272a33),
                                  child: Icon(
                                    Icons.movie_outlined,
                                    color: accent,
                                  ),
                                ),
                        ),
                      ),
                      title: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: Text(
                        '${p.clips.length} clips · ${stamp(p.duration)} · ${p.width} × ${p.pixelHeight}',
                      ),
                      onTap: () => open(p),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          final yes = await confirm(
                            context,
                            'Delete project?',
                            'This removes its local media copies. Exported videos are kept.',
                          );
                          if (yes) {
                            try {
                              await widget.store.delete(p);
                              await reload();
                            } catch (e) {
                              if (mounted) showError(context, e);
                            }
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(
                            value: 'delete',
                            child: Text('Delete project'),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
  );
}

String stamp(double seconds) {
  final ms = (seconds * 1000).round();
  return '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}.${((ms % 1000) ~/ 10).toString().padLeft(2, '0')}';
}

Future<String?> askText(
  BuildContext context,
  String title,
  String initial, {
  int maxLength = 100,
}) async {
  final controller = TextEditingController(text: initial);
  final answer = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: controller,
        autofocus: true,
        maxLength: maxLength,
        maxLines: 3,
        minLines: 1,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialog, controller.text.trim()),
          child: const Text('Done'),
        ),
      ],
    ),
  );
  // Dialog animations can still reference the controller during route dismissal.
  await Future<void>.delayed(const Duration(milliseconds: 400));
  controller.dispose();
  return answer;
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Continue'),
          ),
        ],
      ),
    ) ??
    false;
void showError(BuildContext context, Object error) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          error
              .toString()
              .replaceFirst('Bad state: ', '')
              .replaceFirst('FormatException: ', ''),
        ),
        duration: const Duration(seconds: 6),
      ),
    );
