package com.aikobox.app

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.content.ContextCompat
import com.aikobox.app.service.AikoCoreContract
import com.aikobox.app.service.ClashEndpoint
import com.aikobox.app.service.InstalledAppsReader
import com.aikobox.app.service.LibboxProbe
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.util.concurrent.Executors

/**
 * The Dart ⇄ Kotlin bridge, bound to the names fixed in contract §4.4.
 *
 * ```
 * MethodChannel "aikobox/core"
 * EventChannel  "aikobox/core/status"  -> {state, error?}
 * EventChannel  "aikobox/core/logs"    -> {level, message, time}
 * ```
 *
 * Everything else the UI needs — traffic, connections, proxies, rules, modes — is read
 * straight from the core's Clash API over loopback, exactly like the desktop app's
 * `mihomoApi.ts`. No channel is invented for it, and no libbox proxy object ever crosses
 * this boundary: `OutboundGroup`, `StatusMessage` and friends are Go-ref-counted, and
 * touching one after Go has released it takes the process down.
 *
 * This class runs in the UI process. The tunnel runs in `:remote`. Commands therefore leave
 * as Intents and state arrives as broadcasts; there is deliberately nothing static shared
 * between the two.
 */
class AikoCorePlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.ActivityResultListener {

    private lateinit var appContext: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var statusChannel: EventChannel
    private lateinit var logsChannel: EventChannel

    private val main = Handler(Looper.getMainLooper())
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "aiko-core-plugin").apply { isDaemon = true }
    }

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingConsent: MethodChannel.Result? = null

    private var statusSink: EventChannel.EventSink? = null
    private var logSink: EventChannel.EventSink? = null

    /** Last state the service announced; `stopped` until it says otherwise. */
    @Volatile
    private var lastState: String = AikoCoreContract.STATE_STOPPED

    /**
     * The control endpoint of the configuration most recently handed to `start`.
     *
     * Cached rather than re-parsed on every `clashApiPort()` call, which the Dart health
     * gate makes several times a second while a core comes up.
     */
    @Volatile
    private var endpoint: ClashEndpoint? = null

    private val serviceReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                AikoCoreContract.ACTION_STATE -> {
                    val state = intent.getStringExtra(AikoCoreContract.EXTRA_STATE)
                        ?: AikoCoreContract.STATE_STOPPED
                    lastState = state
                    if (state == AikoCoreContract.STATE_STOPPED) endpoint = null
                    emitStatus(state, intent.getStringExtra(AikoCoreContract.EXTRA_ERROR))
                }

                AikoCoreContract.ACTION_LOG -> emitLog(
                    intent.getStringExtra(AikoCoreContract.EXTRA_LEVEL)
                        ?: AikoCoreContract.LEVEL_INFO,
                    intent.getStringExtra(AikoCoreContract.EXTRA_MESSAGE).orEmpty(),
                    intent.getLongExtra(AikoCoreContract.EXTRA_TIME, System.currentTimeMillis()),
                )
            }
        }
    }

    // -----------------------------------------------------------------------
    // FlutterPlugin
    // -----------------------------------------------------------------------

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        statusChannel = EventChannel(binding.binaryMessenger, STATUS_CHANNEL)
        statusChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    statusSink = events
                    // Ask a live service to re-announce, so a UI process that restarted
                    // while the tunnel stayed up sees `running` immediately instead of
                    // believing its own default. Silence means nothing is running.
                    AikoCoreContract.broadcast(
                        appContext,
                        Intent(AikoCoreContract.ACTION_QUERY_STATE),
                    )
                }

                override fun onCancel(arguments: Any?) {
                    statusSink = null
                }
            },
        )

        logsChannel = EventChannel(binding.binaryMessenger, LOGS_CHANNEL)
        logsChannel.setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    logSink = events
                }

                override fun onCancel(arguments: Any?) {
                    logSink = null
                }
            },
        )

        ContextCompat.registerReceiver(
            appContext,
            serviceReceiver,
            IntentFilter().apply {
                addAction(AikoCoreContract.ACTION_STATE)
                addAction(AikoCoreContract.ACTION_LOG)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        runCatching { appContext.unregisterReceiver(serviceReceiver) }
        methodChannel.setMethodCallHandler(null)
        statusChannel.setStreamHandler(null)
        logsChannel.setStreamHandler(null)
        statusSink = null
        logSink = null
        worker.shutdown()
    }

    // -----------------------------------------------------------------------
    // ActivityAware — VpnService.prepare() needs an Activity
    // -----------------------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
        // A consent dialog whose Activity is gone will never answer. Failing it now beats
        // leaving the Dart future hanging forever.
        pendingConsent?.let { pending ->
            pendingConsent = null
            pending.success(false)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != VPN_CONSENT_REQUEST) return false
        val pending = pendingConsent ?: return true
        pendingConsent = null
        pending.success(resultCode == Activity.RESULT_OK)
        return true
    }

    // -----------------------------------------------------------------------
    // MethodChannel
    // -----------------------------------------------------------------------

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "prepareVpn" -> result.success(VpnService.prepare(appContext) == null)
            "requestVpnPermission" -> requestVpnPermission(result)
            "start" -> start(call, result)
            "stop" -> stop(result)
            "checkConfig" -> checkConfig(call, result)
            "coreVersion" -> onWorker(result) { LibboxProbe.coreVersion() }
            "installedApps" -> onWorker(result) { InstalledAppsReader.read(appContext) }
            "clashApiPort" -> clashApiPort(result)
            "clashApiSecret" -> result.success(resolveEndpoint()?.secret.orEmpty())
            else -> result.notImplemented()
        }
    }

    private fun requestVpnPermission(result: MethodChannel.Result) {
        val consent = VpnService.prepare(appContext)
        if (consent == null) {
            result.success(true)
            return
        }
        val current = activity
        if (current == null) {
            // Always-on VPN and quick-tile paths reach the service without an Activity, but
            // this call cannot: the system dialog has nowhere to appear.
            result.error(
                AikoCoreContract.ERROR_VPN_PERMISSION_DENIED,
                "VPN consent needs a foreground activity",
                null,
            )
            return
        }
        if (pendingConsent != null) {
            result.error(
                AikoCoreContract.ERROR_VPN_PERMISSION_DENIED,
                "a VPN consent dialog is already open",
                null,
            )
            return
        }
        pendingConsent = result
        try {
            current.startActivityForResult(consent, VPN_CONSENT_REQUEST)
        } catch (e: Exception) {
            pendingConsent = null
            result.error(
                AikoCoreContract.ERROR_VPN_PERMISSION_DENIED,
                e.message ?: "the VPN consent dialog could not be shown",
                null,
            )
        }
    }

    /**
     * Hands a validated configuration to the service and returns.
     *
     * Deliberately **not** synchronous on the core's outcome. The Dart controller runs its
     * own health gate after this call and, when that gate fails, rolls back to the
     * last-known-good configuration (N3) — a path it only takes when `start` itself did not
     * throw. Reporting a core failure as a thrown `PlatformException` here would skip the
     * rollback entirely, so core-level outcomes travel on the status stream instead and only
     * dispatch failures are raised as errors.
     */
    private fun start(call: MethodCall, result: MethodChannel.Result) {
        val configJson = call.argument<String>("configJson")
        if (configJson.isNullOrBlank()) {
            result.error(
                AikoCoreContract.ERROR_CONFIG_INVALID,
                "start requires a non-empty configJson",
                null,
            )
            return
        }
        val include = call.argument<List<String>>("includePackages").orEmpty()
        val exclude = call.argument<List<String>>("excludePackages").orEmpty()
        if (include.isNotEmpty() && exclude.isNotEmpty()) {
            result.error(
                AikoCoreContract.ERROR_UNKNOWN,
                "VpnService.Builder accepts an allow-list or a deny-list, never both",
                null,
            )
            return
        }

        worker.execute {
            try {
                val staged = stageConfig(configJson)
                endpoint = ClashEndpoint.parse(configJson)
                val intent = AikoCoreContract.serviceIntent(appContext, AikoCoreContract.ACTION_START)
                    .putExtra(AikoCoreContract.EXTRA_CONFIG_PATH, staged.absolutePath)
                    .putStringArrayListExtra(
                        AikoCoreContract.EXTRA_INCLUDE_PACKAGES,
                        ArrayList(include),
                    )
                    .putStringArrayListExtra(
                        AikoCoreContract.EXTRA_EXCLUDE_PACKAGES,
                        ArrayList(exclude),
                    )
                    .putExtra(AikoCoreContract.EXTRA_LOCALE, readUiLocale())
                ContextCompat.startForegroundService(appContext, intent)
                main.post { result.success(null) }
            } catch (e: Exception) {
                Log.e(TAG, "start dispatch failed", e)
                main.post {
                    result.error(
                        AikoCoreContract.ERROR_CORE_START_FAILED,
                        e.message ?: "the system refused to start the tunnel service",
                        null,
                    )
                }
            }
        }
    }

    /**
     * A broadcast, not a service start.
     *
     * Android 12+ throws `ForegroundServiceStartNotAllowedException` for a background
     * `startForegroundService`, and "stop the VPN" is precisely the command that gets sent
     * while the app is off screen.
     */
    private fun stop(result: MethodChannel.Result) {
        endpoint = null
        AikoCoreContract.broadcast(appContext, Intent(AikoCoreContract.ACTION_STOP))
        result.success(null)
    }

    private fun checkConfig(call: MethodCall, result: MethodChannel.Result) {
        val json = call.argument<String>("json")
        if (json.isNullOrBlank()) {
            result.success("The configuration is empty")
            return
        }
        // Off the platform thread: checkConfig builds a full core instance to validate, and
        // a large profile takes long enough to drop frames.
        worker.execute {
            val rejection = LibboxProbe.checkConfig(appContext, json)
            main.post { result.success(rejection) }
        }
    }

    private fun clashApiPort(result: MethodChannel.Result) {
        val resolved = resolveEndpoint()
        if (resolved == null) {
            result.error(
                AikoCoreContract.ERROR_CORE_START_FAILED,
                "the core has not published a control endpoint yet",
                null,
            )
            return
        }
        result.success(resolved.port)
    }

    /**
     * The endpoint of whatever the core is running.
     *
     * Falls back to the promoted configuration on disk, which covers the two cases the cache
     * cannot: an always-on start this process never saw, and a UI process that was killed
     * and restarted while the tunnel kept running.
     */
    private fun resolveEndpoint(): ClashEndpoint? {
        endpoint?.let { return it }
        val fromDisk = ClashEndpoint.parseFile(
            File(appContext.filesDir, AikoCoreContract.WORK_ACTIVE_CONFIG),
        )
        if (fromDisk != null) endpoint = fromDisk
        return fromDisk
    }

    /**
     * Writes the configuration where the `:remote` process can read it.
     *
     * A start payload is hundreds of kilobytes for a real subscription and Binder's
     * transaction buffer is about a megabyte, shared process-wide — passing it as an extra
     * would work on a small profile and fail on a real one.
     */
    private fun stageConfig(configJson: String): File {
        val target = File(appContext.cacheDir, AikoCoreContract.PENDING_CONFIG)
        val temporary = File(appContext.cacheDir, "${AikoCoreContract.PENDING_CONFIG}.tmp")
        temporary.writeText(configJson)
        if (!temporary.renameTo(target)) {
            // renameTo can fail if the target is being read; a plain overwrite is still
            // better than starting the core with a truncated file, which the rename was
            // there to prevent in the first place.
            target.writeText(configJson)
            temporary.delete()
        }
        return target
    }

    /**
     * The language the user picked inside the app, so the service's notification matches the
     * UI rather than the device locale.
     *
     * `shared_preferences` stores Dart strings in `FlutterSharedPreferences` under a
     * `flutter.` prefix; `LocaleSettingNotifier.prefsKey` is `aikobox.locale`. Absent means
     * "follow the system", which is also what the service does with a null tag.
     */
    private fun readUiLocale(): String? = runCatching {
        appContext
            .getSharedPreferences(FLUTTER_PREFERENCES, Context.MODE_PRIVATE)
            .getString(LOCALE_PREFERENCE_KEY, null)
    }.getOrNull()

    // -----------------------------------------------------------------------
    // Plumbing
    // -----------------------------------------------------------------------

    private fun <T> onWorker(result: MethodChannel.Result, block: () -> T) {
        worker.execute {
            try {
                val value = block()
                main.post { result.success(value) }
            } catch (e: Throwable) {
                main.post {
                    result.error(
                        AikoCoreContract.ERROR_UNKNOWN,
                        e.message ?: e.toString(),
                        null,
                    )
                }
            }
        }
    }

    private fun emitStatus(state: String, error: String?) {
        main.post {
            statusSink?.success(
                mapOf(
                    "state" to state,
                    "error" to error,
                ),
            )
        }
    }

    private fun emitLog(level: String, message: String, time: Long) {
        if (message.isEmpty()) return
        main.post {
            logSink?.success(
                mapOf(
                    "level" to level,
                    "message" to message,
                    "time" to time,
                ),
            )
        }
    }

    private companion object {
        const val TAG = "AikoCorePlugin"

        const val METHOD_CHANNEL = "aikobox/core"
        const val STATUS_CHANNEL = "aikobox/core/status"
        const val LOGS_CHANNEL = "aikobox/core/logs"

        const val VPN_CONSENT_REQUEST = 0x5642

        const val FLUTTER_PREFERENCES = "FlutterSharedPreferences"
        const val LOCALE_PREFERENCE_KEY = "flutter.aikobox.locale"
    }
}
