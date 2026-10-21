# P-cut 0.2.0

A separate native Flutter video editor for Android and Windows. This project does not modify Pulse, use Pulse accounts, or connect to Supabase. Editing is local. No paid service or API key is needed.

This is implemented editor source, not an already compiled or fully device-verified app. It implements the core timeline and layers in the reference, with the limitations below. It is not a claim that every feature in a mature commercial editor has been completed.

## Build on GitHub

1. Use your **`p-cut` repository** if you already created it; otherwise create it once. Keep your existing Pulse repository intact. Update matching P-cut files without deleting unrelated files.
2. Extract `P-cut_Source_v0.2.0.zip`. Open the `p-cut` folder and upload its **contents** to the new repository root. `pubspec.yaml`, `lib`, `scripts`, `native`, `assets`, `test`, and `.github` must be at that root. The ZIP itself is not the app source layout for Actions.
3. If GitHub's file picker hides `.github`, create `.github/workflows/main.yml` with **Add file → Create new file** and paste the file supplied in this project.
4. Open **Actions → P-cut native builds → Run workflow**.
5. When both jobs pass, download the `P-cut-Android-Beta` and `P-cut-Windows` artifacts. Extract each downloaded artifact ZIP. Android contains an APK. Windows contains the setup EXE and the complete portable application directory.
6. Do not copy only `P-cut.exe` out of the portable folder: its DLLs and `data` directory are required. The setup EXE installs those together.

The Android artifact is a debug-signed beta. Distribution through a store requires release signing and store setup. No GitHub build has been triggered from this workspace; repository integration write access was unavailable during the Pulse work.

## Implemented in source

- Original P-cut branding, project library, dark responsive interface, desktop inspector and mobile editing controls.
- Native file import with actual copy progress, media copies owned by each project, video/photo thumbnails where a frame can be decoded, and no dependency on the original file after import.
- Sequential video/photo timeline with zoom, ruler, playhead, seeking, playback, clip selection and source trim.
- Split video at the playhead, duplicate, move left/right, delete, and change photo duration.
- Speed choices from 0.25× to 4×; video and audio export are changed together. Photo clips retain their set duration.
- Per-clip volume/mute, quarter-turn rotation, fit/fill framing, brightness, contrast, monochrome, warm and cool filters.
- Four independent local music/sound tracks, source trim, timeline start, volume and fade-in/out envelopes, mixed with source audio. Voiceover recording supports microphone permission requests, pause/resume, stop, preview, retake and adding the accepted recording to the audio timeline. Reference playback is muted while recording. Each take is limited to five minutes and the remaining video duration.
- Keyframes animate layer position, size, rotation and opacity with linear or smooth interpolation. Add a keyframe, scrub to another time, then change the pose. Keyframe chips seek to or delete individual keys; Freeze animation keeps the current pose. Each layer supports up to 50 keys.
- Overlapping crossfades between neighbouring clips, including source-audio crossfades. Choose Cut or a fade duration in Clip tools. Actual fades are capped at half of the shorter adjacent clip so no more than two main clips overlap. Timeline duration, seeking and audio positions use that overlap-aware clock. Splitting is limited away from crossfade regions to preserve the existing timeline.
- Twelve independent visual layers: text, emoji stickers, rectangles and circles. Each has start/end time, size, position, rotation, colour and opacity. Select a layer and drag it in the preview; its timeline row selects it. Move-to-front changes stacking order.
- Undo/redo with bounded history, including slider gestures as one edit. Resetting/replacing a project is not needed to try different edits.
- Debounced autosave, serialized disk writes, backup recovery and reopening projects. Deleting a project deletes its media copies, not original files or already exported videos.
- 9:16, 16:9, 1:1 and 4:5 canvases; 480p, 720p and 1080p resolution choices. The chosen quality is the short edge for portrait output: 720p at 9:16 produces 720 × 1280.
- Actual MP4 rendering with progress/cancel, layers burned into the video, local exports, Android gallery save, and Windows Save a copy.
- Editable subtitle track with up to 500 cues, SRT import/export, timing validation, preview and burned-in export. The subtitle editor has an Apply button; saving a standalone SRT does not apply project changes automatically.
- Optional offline Windows auto-caption adapter for a user-supplied whisper.cpp CLI and compatible speech model. It renders 16 kHz mono project audio, including clip timing/speed, crossfades, music and voiceover, then runs local transcription. Executable/model settings are saved locally. No model or executable is silently downloaded. Recognition accuracy and real model inference have not been tested in this workspace. Android automatic speech recognition is not included in this version.
- Space plays/pauses; Ctrl+Z undoes; Ctrl+Shift+Z redoes when the editor has focus.

To edit: New project → Media → select files → choose a timeline clip → use Clip/Effects/Music/Layers. Split only works when the playhead is inside the selected video. Add a visual layer before trying to position one. The export icon is at the top right; aspect ratio is beside it.

## Platform engines and external setup

### Android

Android 10 or later. Media3 1.9.0 Transformer composes native video/photo sequences, audio tracks and bitmap overlays through Android codecs. Crossfades use two alternating sequences and a custom compositor, with PCM audio envelopes after the speed processor. Layer animation is applied by native overlay transforms. Subtitle frames reuse one bitmap rather than allocating hundreds of simultaneous GPU textures. `scripts/bootstrap.py` registers the native Kotlin bridge and dependencies. The APK does not need FFmpeg, a server or an account. Gallery output uses MediaStore `Movies/P-cut`, without requesting broad access to the phone's photo library.

Keep P-cut in the foreground during rendering. The native renderer keeps the screen awake while active. Background/locked-screen rendering is not a foreground-service implementation in this version. Codec support, decoder limits and export speed vary by phone. 720p and short projects are the recommended starting point for a 4 GB RAM device.

### Windows

Windows export requires **both `ffmpeg.exe` and `ffprobe.exe`**, with the FFmpeg build supporting `libx264` and AAC. Download a Windows build using the providers linked from https://ffmpeg.org/download.html . Keep the two EXEs together; either put their directory on PATH, place both beside `P-cut.exe`, or select `ffmpeg.exe` in P-cut's export dialog. Selecting the EXE is remembered for the current editor session. Playback does not require a separately installed FFmpeg.

The Windows installer does not bundle FFmpeg binaries. This keeps that dependency explicit and avoids silently shipping a third-party executable. The exporter calls argument arrays, never a shell command containing user paths. It normalizes clips one at a time, concatenates them and renders timed overlays/music. Crossfade joins are rendered pairwise to limit decoder memory, which increases rendering time on long timelines. Animated sprites use fixed-size transforms to avoid repeated buffer reallocations. This uses temporary disk space in addition to imported media and the final video; leave sufficient free space.

## Local builds

Install Flutter stable 3.47.7, Android SDK/Java 17 for Android and Visual Studio Desktop development with C++ for Windows. Then:

```text
python scripts/bootstrap.py
flutter pub get
dart format lib test
flutter analyze
dart test/project_offline.dart
python -m unittest discover -s test -p "test_*.py"
flutter test
flutter build apk --debug
```

On a Windows machine with Flutter desktop tools:

```text
flutter build windows --release
```

Use Inno Setup 6 to compile `scripts/windows-installer.iss` after a Windows release build. Its AppId and local data are separate from Pulse. Never generate Windows runners inside Pulse for this app.

## Validation performed

Passed in the development workspace:

- Dart parser/format checks for all app/test files.
- Standalone Dart analysis for the project model, edit history, FFmpeg plan and their standalone tests.
- Model tests: JSON round trip, speed-aware positions, split continuity, undo/redo, invalid input rejection, safe IDs, timed-layer/audio planning and concat path escaping. Additional tests check overlap clocks, short-clip fade limits, interpolation and endpoint holds, key replacement, smooth easing, audio envelopes and subtitle parsing/round trips.
- A real FFmpeg render and FFprobe inspection: video/photo concatenation, trim, speed, rotation, colour, silence normalization, audio mixing and a timed overlay. Output dimensions, duration, audio/video tracks and before/during/after overlay pixels were checked.
- Advanced real-render tests verify crossfade colours, position/scale/rotation/opacity keyframes (including changing opacity and scale together), and timed subtitle alpha. Audio-only rendering is tested for speech preparation, source silence, crossfades, imported-track fade envelopes and exact duration.
- Python bootstrap test: native configuration is idempotent and preserves Dart source, including on repeated generation.

**Not yet executed here:** full Flutter dependency resolution/analyzer, Flutter widget/storage tests, Android Kotlin/Gradle compilation, Windows desktop compilation/installer execution, or physical-device UI/export/gallery/microphone testing. The whisper.cpp adapter has not been run with a real speech model. Those checks are wired into Actions where possible; device tests remain manual. No APK/EXE is included in this source ZIP.

## Limits and remaining development

This version has one main video/photo timeline with adjacent overlapping crossfades, four audio tracks, twelve timed/keyframed text/shape/emoji layers and a separate subtitle track. It does not yet implement arbitrary overlapping video tracks/PiP, full waveform displays, particle effects, Android automatic speech recognition, AI background removal, masking, curves, chroma key, stabilization, reverse playback, advanced colour grading, custom font import, a licensed music catalog, cloud collaboration or 4K export. The optional Windows speech adapter requires an external compatible executable and model; that requirement is not fulfilled by this ZIP alone.

Source thumbnails are best-effort decoded covers, not a generated frame strip for every timeline second. A video with no decodable cover uses a media icon. Preview uses at most two active video decoders during crossfades and the active audio players, with clock-based synchronization; it is not sample-accurate scrubbing. Flutter's live colour preview and native encoder colour handling may differ slightly. Layer text/shapes are rasterized using the same painter into bounded sprites at the largest keyed size, but emoji availability depends on platform fonts. Export rejects a layer sprite larger than 4096 pixels on either side; reduce oversized text or line count instead of exhausting device memory.

Projects are capped at 100 clips and 30 minutes to bound timeline/memory load. Audio and overlay positions are absolute timeline times and do not ripple automatically when earlier clips are shortened. Layers outside the final video interval are retained but do not appear in the output. Audio is truncated at the end of the video. Export is SDR-oriented; HDR/device codec support must be verified. There is no automatic app-update system or store billing in this initial app.

Local projects are stored in the app's Documents/P-cut directory. They are not encrypted backups. The app does not yet offer a portable project archive/relink workflow; moving only a project JSON to another device will not move its media. Uninstalling/clearing app data can remove local projects, so keep exported videos in the gallery or another backup.

## Device acceptance checklist

- Open a fresh project; import two videos, a large photo and an audio track. Confirm import progress and usable previews.
- Trim/split/reorder/duplicate/remove; test slow/fast audio, rotation, fit/fill and colour reset.
- Create timed text, a translucent shape and an emoji; position/rotate, change front order, undo and redo.
- Offset/trim music; listen for correct playback and exported sync. Test mixed mono/stereo and silent videos.
- Save, close, restart and reopen. Remove the original imported file and confirm the project's copy still works.
- Animate each layer property with multiple keys, including simultaneous scale/opacity changes; check smooth interpolation and Freeze. Set adjacent crossfades, verify the shorter timeline and audio/video sync, then undo.
- Record a voiceover, pause/resume, stop, listen, retake, accept and cancel. Test microphone denial and backgrounding on both platforms.
- Import/edit/apply subtitles, reject overlaps, export SRT and inspect subtitle timing in MP4. On Windows only, test the optional speech adapter with a compatible small model, review errors, cancel/retry, and correct generated text before Apply.
- Export each aspect ratio at 720p, cancel another export, and retry. Confirm no incomplete video is presented as complete.
- Check exported layer start/end, rotation, colour and sound, then gallery save/Windows Save a copy.
- Test denied file access, corrupt inputs, low disk space, screen lock/backgrounding, 320px phone layouts, Windows resize and long projects.

## Technical references

- Android Media3 composition: https://developer.android.com/media/media3/transformer/composition
- Pinned API source: https://github.com/androidx/media/tree/1.9.0/libraries/transformer
- FFmpeg filters: https://ffmpeg.org/ffmpeg-filters.html
- Flutter SDK archive: https://docs.flutter.dev/install/archive

P-cut uses Flutter, Media Kit, File Picker, Path Provider and AndroidX Media3. Their licenses remain with their respective authors; dependency notices should accompany distributed builds. This project contains original app code and branding, not proprietary assets from the editing reference.

## Optional Windows speech setup

Obtain a CPU-compatible `whisper-cli.exe` and a supported GGML model from the official whisper.cpp project: https://github.com/ggml-org/whisper.cpp . Do not assume every precompiled executable supports an older Pentium CPU; check the build's CPU requirements or build without unsupported instruction sets. The adapter uses the documented `-m`, `-f`, `-osrt`, `-of`, `-l` and `-t` options. A small multilingual model is needed for languages other than English; an English-only model cannot recognize Yoruba. Model size, accuracy and speed vary.

In P-cut: Subtitles → auto-caption sparkle icon (Windows only) → select speech EXE, model and FFmpeg → choose language → Generate subtitles. Review/edit the result, then Apply. Audio stays local. A model and a CPU-compatible CLI are not bundled, and no claim of tested speech recognition is made here. Android users can add subtitles manually or import SRT.

Do not open and resave v0.2 projects in v0.1 if you want to preserve the new fields; older code does not know about keyframes, fades or subtitle tracks. v0.2 can load v0.1 projects.
