package com.aikobox.app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    /**
     * Registers the `aikobox/core` and `aikobox/shell` bridges.
     *
     * Added explicitly rather than through `GeneratedPluginRegistrant`, because both are
     * part of this app rather than a pub package — there is no `pubspec.yaml` entry for the
     * tool to discover. `super` still runs the generated registrant for the real plugins.
     */
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        flutterEngine.plugins.add(AikoCorePlugin())
        flutterEngine.plugins.add(AikoShellPlugin())
    }
}
