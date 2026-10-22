import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import patch

spec=importlib.util.spec_from_file_location('bootstrap',Path(__file__).resolve().parents[1]/'scripts/bootstrap.py')
bootstrap=importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)

class NativeConfigurationTest(unittest.TestCase):
    def test_configuration_is_idempotent_and_preserves_source(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            fixtures={
                'android/app/src/main/AndroidManifest.xml':'<manifest><application android:label="p_cut"/></manifest>',
                'android/app/build.gradle.kts':'android { defaultConfig { minSdk = flutter.minSdkVersion } }',
                'windows/runner/main.cpp':'window.Create(L"p_cut", origin, size);',
                'windows/CMakeLists.txt':'cmake_minimum_required(VERSION 3.14)\nset(BINARY_NAME "p_cut")',
                'windows/runner/Runner.rc':'VALUE "ProductName", "p_cut"',
                'lib/main.dart':'// Existing editor source must be preserved',
                'native/android/MainActivity.kt':'// Native bridge',
            }
            for name,text in fixtures.items():
                path=root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text,encoding='utf-8')
            with patch.object(bootstrap.shutil,'which',return_value='/tools/flutter'),patch.object(bootstrap.subprocess,'run') as run:
                bootstrap.configure(root)
                first={str(p.relative_to(root)):p.read_bytes() for p in root.rglob('*') if p.is_file()}
                bootstrap.configure(root)
                second={str(p.relative_to(root)):p.read_bytes() for p in root.rglob('*') if p.is_file()}
                self.assertEqual(first,second)
                self.assertEqual(run.call_args.kwargs['cwd'],root)
                self.assertIn('--no-pub',run.call_args.args[0])
            self.assertEqual((root/'lib/main.dart').read_text(),fixtures['lib/main.dart'])
            android = '{http://schemas.android.com/apk/res/android}'
            for variant in ['drawable', 'drawable-v21']:
                splash = ET.parse(root / f'android/app/src/main/res/{variant}/launch_background.xml').getroot()
                self.assertEqual(splash.find('item/shape/solid').get(android + 'color'), '#0D0F14')
                for item in splash.findall('item'):
                    drawable = item.get(android + 'drawable')
                    if drawable is not None:
                        self.assertTrue(drawable.startswith(('@', '?')))
            self.assertIn('minSdk = 29',(root/'android/app/build.gradle.kts').read_text())
            self.assertIn('media3-transformer:1.9.0',(root/'android/app/build.gradle.kts').read_text())
            self.assertIn('L"P-cut"',(root/'windows/runner/main.cpp').read_text())
            self.assertTrue((root/'android/app/src/main/kotlin/com/pcut/editor/p_cut/MainActivity.kt').exists())

if __name__=='__main__':unittest.main()
