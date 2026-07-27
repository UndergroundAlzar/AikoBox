package com.aikobox.app

import android.app.Activity
import android.content.Intent
import android.net.VpnService
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val worker = Executors.newSingleThreadExecutor()
    private var prepareResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        LibboxRuntime.initialize(applicationContext)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL_NAME)
            .setMethodCallHandler(::handleMethodCall)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL_NAME)
            .setStreamHandler(
                object : EventChannel.StreamHandler {
                    private var listener: ((Map<String, Any?>) -> Unit)? = null

                    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                        val statusListener: (Map<String, Any?>) -> Unit = { value ->
                            runOnUiThread { events.success(value) }
                        }
                        listener = statusListener
                        AikoVpnService.addStatusListener(statusListener)
                        events.success(AikoVpnService.statusSnapshot())
                    }

                    override fun onCancel(arguments: Any?) {
                        listener?.let(AikoVpnService::removeStatusListener)
                        listener = null
                    }
                },
            )
    }

    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareVpn" -> prepareVpn(result)
            "checkProfile" -> {
                val path = requiredPath(call, result) ?: return
                worker.execute {
                    runCatching {
                        LibboxRuntime.checkProfile(readProfile(path))
                    }.fold(
                        onSuccess = { runOnUiThread { result.success(null) } },
                        onFailure = { error -> runOnUiThread { result.nativeError("CHECK_FAILED", error) } },
                    )
                }
            }
            "start", "reload" -> {
                val path = requiredPath(call, result) ?: return
                val action =
                    if (call.method == "start") AikoVpnService.ACTION_START
                    else AikoVpnService.ACTION_RELOAD
                val intent =
                    Intent(this, AikoVpnService::class.java)
                        .setAction(action)
                        .putExtra(AikoVpnService.EXTRA_PROFILE_PATH, path)
                ContextCompat.startForegroundService(this, intent)
                result.success(null)
            }
            "stop" -> {
                startService(Intent(this, AikoVpnService::class.java).setAction(AikoVpnService.ACTION_STOP))
                result.success(null)
            }
            "getStatus" -> result.success(AikoVpnService.statusSnapshot())
            else -> result.notImplemented()
        }
    }

    private fun prepareVpn(result: MethodChannel.Result) {
        if (prepareResult != null) {
            result.error("PREPARE_PENDING", "A VPN permission request is already active.", null)
            return
        }
        val intent = VpnService.prepare(this)
        if (intent == null) {
            result.success(true)
            return
        }
        prepareResult = result
        startActivityForResult(intent, PREPARE_REQUEST)
    }

    @Deprecated("Deprecated in Android SDK; retained for VpnService.prepare compatibility.")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PREPARE_REQUEST) return
        val result = prepareResult ?: return
        prepareResult = null
        result.success(resultCode == Activity.RESULT_OK)
    }

    override fun onDestroy() {
        prepareResult?.error("ACTIVITY_DESTROYED", "VPN permission request was interrupted.", null)
        prepareResult = null
        worker.shutdownNow()
        super.onDestroy()
    }

    private fun requiredPath(call: MethodCall, result: MethodChannel.Result): String? {
        val path = call.argument<String>("profilePath")
        if (path.isNullOrBlank()) {
            result.error("INVALID_ARGUMENT", "profilePath is required.", null)
            return null
        }
        return path
    }

    private fun readProfile(path: String): String {
        val file = File(path).canonicalFile
        require(file.isFile) { "Profile does not exist: $file" }
        require(file.length() in 1..MAX_PROFILE_BYTES) {
            "Profile must be between 1 byte and 4 MiB."
        }
        return file.readText(Charsets.UTF_8)
    }

    private fun MethodChannel.Result.nativeError(code: String, error: Throwable) {
        this.error(code, error.message ?: error.javaClass.simpleName, null)
    }

    companion object {
        private const val CHANNEL_NAME = "com.aikobox.app/vpn"
        private const val EVENT_CHANNEL_NAME = "com.aikobox.app/vpn/events"
        private const val PREPARE_REQUEST = 7001
        private const val MAX_PROFILE_BYTES = 4L * 1024L * 1024L
    }
}
