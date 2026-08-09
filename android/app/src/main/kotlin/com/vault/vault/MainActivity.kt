package com.vault.vault

import com.vault.vault.offload.OffloadPlugin
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(ProotPlugin())
        flutterEngine.plugins.add(OffloadPlugin())
    }
}
