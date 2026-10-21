"""Generate P-cut native runners without replacing lib or project data."""
from pathlib import Path
import os
import re
import shutil
import subprocess


def configure(root: Path):
    flutter = shutil.which('flutter') or shutil.which('flutter.bat')
    if not flutter:
        raise RuntimeError('Install Flutter stable and add its bin directory to PATH.')
    args = [flutter, 'create', '--no-pub', '--platforms=android,windows',
            '--org', 'com.pcut.editor', '--project-name', 'p_cut', '.']
    if os.name == 'nt' and flutter.lower().endswith(('.bat', '.cmd')):
        args = [os.environ.get('COMSPEC', 'cmd.exe'), '/d', '/c', *args]
    subprocess.run(args, cwd=root, check=True)
    manifest = root / 'android/app/src/main/AndroidManifest.xml'
    text = manifest.read_text(encoding='utf-8').replace('android:label="p_cut"', 'android:label="P-cut"')
    if 'android.permission.RECORD_AUDIO' not in text:
        text=text.replace('<application','<uses-permission android:name="android.permission.RECORD_AUDIO"/><application',1)
    manifest.write_text(text, encoding='utf-8')
    gradle = root / 'android/app/build.gradle.kts'
    text = gradle.read_text(encoding='utf-8')
    text = re.sub(r'minSdk\s*=\s*flutter.minSdkVersion', 'minSdk = 29', text)
    # Media3 uses hardware Android codecs; no FFmpeg binary is bundled in Android.
    if '// P-cut export engine' not in text:
        text += '\n// P-cut export engine\ndependencies {\n'
        for artifact in ['media3-transformer', 'media3-effect']:
            text += f'    implementation("androidx.media3:{artifact}:1.9.0")\n'
        text += '}\n'
    gradle.write_text(text, encoding='utf-8')
    target = root / 'android/app/src/main/kotlin/com/pcut/editor/p_cut'
    target.mkdir(parents=True, exist_ok=True)
    for source in (root / 'native/android').glob('*.kt'):
        shutil.copyfile(source, target / source.name)
    for density in ['mdpi', 'hdpi', 'xhdpi', 'xxhdpi', 'xxxhdpi']:
        source = root / f'assets/branding/mipmap-{density}/ic_launcher.png'
        if source.exists():
            destination = root / f'android/app/src/main/res/mipmap-{density}/ic_launcher.png'
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, destination)
    drawable = root / 'android/app/src/main/res/drawable'
    drawable.mkdir(parents=True, exist_ok=True)
    (drawable / 'pcut_mark.xml').write_text('''<vector xmlns:android="http://schemas.android.com/apk/res/android" android:width="96dp" android:height="96dp" android:viewportWidth="100" android:viewportHeight="100"><path android:fillColor="#C6FF37" android:pathData="M20,8h60q12,0 12,12v60q0,12 -12,12H20q-12,0 -12,-12V20q0,-12 12,-12"/><path android:strokeColor="#101218" android:strokeWidth="6" android:strokeLineCap="round" android:fillColor="#00000000" android:pathData="M37,59L72,24M35,38L72,76M36,61a10,10 0,1 0,-14,14a10,10 0,1 0,14,-14M36,37a10,10 0,1 0,-14,-14a10,10 0,1 0,14,14"/></vector>''', encoding='utf-8')
    (drawable / 'launch_background.xml').write_text('''<layer-list xmlns:android="http://schemas.android.com/apk/res/android"><item android:drawable="#0D0F14"/><item android:width="96dp" android:height="96dp" android:gravity="center" android:drawable="@drawable/pcut_mark"/></layer-list>''', encoding='utf-8')
    v21=root/'android/app/src/main/res/drawable-v21'
    v21.mkdir(parents=True,exist_ok=True)
    shutil.copyfile(drawable/'launch_background.xml',v21/'launch_background.xml')
    for variant in ['values-v31', 'values-night-v31']:
        folder = root / 'android/app/src/main/res' / variant
        folder.mkdir(parents=True, exist_ok=True)
        (folder / 'styles.xml').write_text('''<resources><style name="LaunchTheme" parent="@android:style/Theme.Black.NoTitleBar"><item name="android:windowSplashScreenBackground">#0D0F14</item><item name="android:windowSplashScreenAnimatedIcon">@drawable/pcut_mark</item></style><style name="NormalTheme" parent="@android:style/Theme.Black.NoTitleBar"><item name="android:windowBackground">#0D0F14</item></style></resources>''', encoding='utf-8')
    runner = root / 'windows/runner/main.cpp'
    runner.write_text(runner.read_text(encoding='utf-8').replace('L"p_cut"', 'L"P-cut"'), encoding='utf-8')
    cmake = root / 'windows/CMakeLists.txt'
    text = cmake.read_text(encoding='utf-8').replace('set(BINARY_NAME "p_cut")', 'set(BINARY_NAME "P-cut")')
    if '# P-cut policies' not in text:
        text = '# P-cut policies\nset(CMAKE_POLICY_VERSION_MINIMUM 3.5)\nadd_compile_definitions(_SILENCE_EXPERIMENTAL_COROUTINE_DEPRECATION_WARNINGS)\n' + text
    cmake.write_text(text, encoding='utf-8')
    resource = root / 'windows/runner/Runner.rc'
    resource.write_text(resource.read_text(encoding='utf-8').replace('p_cut', 'P-cut'), encoding='utf-8')
    source = root / 'assets/branding/pcut.ico'
    if source.exists():
        shutil.copyfile(source, root / 'windows/runner/resources/app_icon.ico')
    default = root / 'test/widget_test.dart'
    if default.exists() and 'MyApp' in default.read_text(encoding='utf-8'):
        default.unlink()
    print('P-cut Android and Windows native runners configured.')


if __name__ == '__main__':
    configure(Path(__file__).resolve().parents[1])
