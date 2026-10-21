package com.pcut.editor.p_cut

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
  private var renderer: CutRenderer? = null
  override fun configureFlutterEngine(engine: FlutterEngine) {
    super.configureFlutterEngine(engine)
    renderer = CutRenderer(this, engine.dartExecutor.binaryMessenger)
  }
  override fun onDestroy() { renderer?.dispose(); super.onDestroy() }
}
