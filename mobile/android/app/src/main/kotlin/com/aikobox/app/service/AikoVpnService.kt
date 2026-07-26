package com.aikobox.app.service

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.ServiceInfo
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * The foreground [VpnService] that owns the sing-box core.
 *
 * Runs in the `:remote` process (see AndroidManifest), which is not a detail: a Go panic
 * inside libbox takes its process down, and keeping the Flutter engine out of that process
 * means a core fault costs the tunnel, not the UI. It also means **this class shares no
 * memory with the plugin** — every fact the UI needs arrives as a broadcast, and every
 * command arrives as an Intent. A `companion object` holding state here would be invisible
 * on the other side.
 *
 * Three entry paths, and all three must work:
 *
 * * `ACTION_START` from the UI, carrying a config path and the split-tunnel lists.
 * * **A null Intent**, which is how Android starts an always-on VPN and how `START_STICKY`
 *   revives the service after the process died. There is no Activity on this path, so
 *   `VpnService.prepare()` is unavailable and consent is implicit; the configuration and the
 *   split-tunnel lists come from disk instead.
 * * `ACTION_STOP` from the notification action, the quick-settings tile, or the UI.
 */
class AikoVpnService : VpnService(), CoreManager.Host {

    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "aiko-core").apply { isDaemon = true }
    }
    private val ticker = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "aiko-core-telemetry").apply { isDaemon = true }
    }

    private val notification by lazy { TunnelNotification(this) }
    private val platform by lazy { AikoPlatformInterface(this) }
    private val core by lazy { CoreManager(this, platform, this) }
    private val policy by lazy { CrashRestartPolicy.open(this) }
    private val preferences: SharedPreferences by lazy {
        getSharedPreferences(CrashRestartPolicy.PREFERENCES_NAME, Context.MODE_PRIVATE)
    }

    /**
     * The tun descriptor. Go holds a `dup()` of its integer; this reference is the only
     * thing keeping the original open, and losing it kills the tunnel non-deterministically.
     */
    @Volatile
    private var tun: ParcelFileDescriptor? = null

    @Volatile
    private var state: String = AikoCoreContract.STATE_STOPPED

    @Volatile
    private var lastError: String? = null

    @Volatile
    private var localeTag: String? = null

    @Volatile
    private var inForeground = false

    // Telemetry for the notification. Negative means "no sample yet".
    @Volatile
    private var uploadRate = -1L

    @Volatile
    private var downloadRate = -1L

    @Volatile
    private var outboundMode: String? = null

    private var trafficReader: ClashTrafficReader? = null
    private var notificationTask: ScheduledFuture<*>? = null
    private var lingerTask: ScheduledFuture<*>? = null
    private var modeTick = 0

    /**
     * The two messages that must reach a live service without being able to create one.
     *
     * `ACTION_QUERY_STATE` is a question, and silence — no service, no reply — is the
     * correct answer. `ACTION_STOP` arrives as a broadcast rather than a service intent
     * because Android 12+ refuses `startForegroundService` from a backgrounded app, and
     * "stop the VPN" is exactly the command a backgrounded app needs to be able to send.
     */
    private val commandReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                AikoCoreContract.ACTION_QUERY_STATE -> announceState()
                AikoCoreContract.ACTION_STOP -> worker.execute { handleStop() }
            }
        }
    }

    // -----------------------------------------------------------------------
    // Service lifecycle
    // -----------------------------------------------------------------------

    override fun onCreate() {
        super.onCreate()
        localeTag = preferences.getString(KEY_LOCALE, null)
        AikoNotifications.ensureChannels(this)
        ContextCompat.registerReceiver(
            this,
            commandReceiver,
            IntentFilter().apply {
                addAction(AikoCoreContract.ACTION_QUERY_STATE)
                addAction(AikoCoreContract.ACTION_STOP)
            },
            ContextCompat.RECEIVER_NOT_EXPORTED,
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Read the locale before entering the foreground so the very first notification is
        // already in the user's language rather than flashing the device language.
        intent?.getStringExtra(AikoCoreContract.EXTRA_LOCALE)?.let { tag ->
            localeTag = tag
            preferences.edit().putString(KEY_LOCALE, tag).apply()
        }
        notification.applyLocale(localeTag)
        enterForeground()

        when (intent?.action) {
            AikoCoreContract.ACTION_STOP -> worker.execute { handleStop() }

            AikoCoreContract.ACTION_START -> {
                val configPath = intent.getStringExtra(AikoCoreContract.EXTRA_CONFIG_PATH)
                val include = intent.getStringArrayListExtra(AikoCoreContract.EXTRA_INCLUDE_PACKAGES)
                    ?.toList()
                    .orEmpty()
                val exclude = intent.getStringArrayListExtra(AikoCoreContract.EXTRA_EXCLUDE_PACKAGES)
                    ?.toList()
                    .orEmpty()
                rememberSplitTunnel(include, exclude)
                worker.execute { handleStart(configPath, include, exclude) }
            }

            // Null Intent: always-on VPN, or START_STICKY reviving us after the process died.
            else -> worker.execute { handleAutoStart() }
        }

        return START_STICKY
    }

    /**
     * The user (or another VPN app) revoked consent.
     *
     * The default `onRevoke` just calls `stopSelf()`, which would leave the core running
     * against a tun the system has already torn down, so the teardown is done explicitly
     * instead of delegating to `super`.
     */
    override fun onRevoke() {
        log(AikoCoreContract.LEVEL_WARNING, "vpn permission was revoked; stopping")
        worker.execute { handleStop() }
    }

    override fun onDestroy() {
        cancelLinger()
        stopTelemetry()
        runCatching { unregisterReceiver(commandReceiver) }
        // Last chance to hand the descriptor and the Go instance back. Synchronous on
        // purpose: once onDestroy returns, the process may go away.
        runCatching { core.dispose() }
        closeTun()
        worker.shutdownNow()
        ticker.shutdownNow()
        super.onDestroy()
    }

    // -----------------------------------------------------------------------
    // Commands — all of these run on `worker`, never on the main thread
    // -----------------------------------------------------------------------

    private fun handleStart(configPath: String?, include: List<String>, exclude: List<String>) {
        cancelLinger()
        publish(AikoCoreContract.STATE_STARTING, null)
        notification.post(notification.starting())

        val configJson = readConfig(configPath)
        if (configJson == null) {
            fail(
                AikoCoreContract.ERROR_CORE_START_FAILED,
                "no configuration to start; import a profile first",
            )
            return
        }

        try {
            val version = core.start(
                CoreManager.StartRequest(
                    configJson = configJson,
                    includePackages = include,
                    excludePackages = exclude,
                    localeTag = localeTag,
                ),
            )
            setDesiredRunning(true)
            publish(AikoCoreContract.STATE_RUNNING, null)
            log(AikoCoreContract.LEVEL_INFO, "sing-box $version started")
            startTelemetry()
        } catch (e: CoreManager.StartFailure) {
            onStartFailed(e.code, e.message)
        } catch (e: Throwable) {
            onStartFailed(AikoCoreContract.ERROR_CORE_START_FAILED, e.message ?: e.toString())
        }
    }

    /**
     * A start that did not take.
     *
     * The distinction that matters is whether the previous core survived. `checkConfig`
     * rejects a candidate *before* anything is swapped, so a tunnel that was already up is
     * still up and reporting `failed` would be a lie — the user's traffic is still flowing.
     * Only once [CoreManager.isServing] is false has anything actually been lost.
     */
    private fun onStartFailed(code: String, message: String) {
        if (core.isServing) {
            log(AikoCoreContract.LEVEL_ERROR, "$code: $message")
            log(AikoCoreContract.LEVEL_INFO, "the previous configuration is still running")
            publish(AikoCoreContract.STATE_RUNNING, message)
            notification.post(notification.running(outboundMode, uploadRate, downloadRate))
            return
        }
        stopTelemetry()
        fail(code, message)
    }

    private fun fail(code: String, message: String) {
        log(AikoCoreContract.LEVEL_ERROR, "$code: $message")
        setDesiredRunning(false)
        publish(AikoCoreContract.STATE_FAILED, message)
        notification.post(notification.failed(message))
        scheduleLinger()
    }

    private fun handleStop() {
        cancelLinger()
        if (state != AikoCoreContract.STATE_STOPPED) {
            publish(AikoCoreContract.STATE_STOPPING, null)
            notification.post(notification.stopping())
        }
        stopTelemetry()
        runCatching { core.stop() }.onFailure { Log.w(TAG, "core stop failed", it) }
        closeTun()
        setDesiredRunning(false)
        publish(AikoCoreContract.STATE_STOPPED, null)
        leaveForeground()
        stopSelf()
    }

    /**
     * Start without an Intent: always-on VPN, a boot restart, or `START_STICKY` reviving the
     * service after the Go runtime took the process down.
     *
     * The last case is the one that needs a circuit breaker. A configuration that panics the
     * core would otherwise be restarted forever, draining the battery and filling logcat, so
     * the desktop app's crash policy — five restarts in a two-minute window, 1 s doubling to
     * 30 s — gates it.
     */
    private fun handleAutoStart() {
        val config = CoreManager.activeConfig(this)
        if (!config.isFile) {
            log(AikoCoreContract.LEVEL_WARNING, "auto-start requested but no configuration has been promoted yet")
            publish(AikoCoreContract.STATE_STOPPED, null)
            leaveForeground()
            stopSelf()
            return
        }

        if (readDesiredRunning()) {
            val decision = policy.recordCrash()
            if (!decision.allowed) {
                fail(
                    AikoCoreContract.ERROR_CORE_START_FAILED,
                    "the core exited unexpectedly ${decision.crashCount} times in two minutes; " +
                        "not restarting it again",
                )
                return
            }
            log(
                AikoCoreContract.LEVEL_WARNING,
                "the core exited unexpectedly (attempt ${decision.crashCount}); " +
                    "restarting in ${decision.delayMs} ms",
            )
            if (decision.delayMs > 0) {
                try {
                    Thread.sleep(decision.delayMs)
                } catch (e: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return
                }
            }
        }

        handleStart(config.absolutePath, readInclude(), readExclude())
    }

    // -----------------------------------------------------------------------
    // CoreManager.Host
    // -----------------------------------------------------------------------

    override fun onCoreRequestedStop() {
        worker.execute { handleStop() }
    }

    override fun onCoreRequestedReload() {
        worker.execute {
            try {
                core.reload()
                publish(AikoCoreContract.STATE_RUNNING, null)
            } catch (e: CoreManager.StartFailure) {
                onStartFailed(e.code, e.message)
            } catch (e: Throwable) {
                onStartFailed(AikoCoreContract.ERROR_CORE_START_FAILED, e.message ?: e.toString())
            }
        }
    }

    override fun onCoreDebugMessage(message: String) {
        log(AikoCoreContract.LEVEL_DEBUG, message)
    }

    override fun onReleaseTun() {
        closeTun()
    }

    override fun log(level: String, message: String) {
        when (level) {
            AikoCoreContract.LEVEL_ERROR -> Log.e(TAG, message)
            AikoCoreContract.LEVEL_WARNING -> Log.w(TAG, message)
            AikoCoreContract.LEVEL_DEBUG -> Log.d(TAG, message)
            else -> Log.i(TAG, message)
        }
        AikoCoreContract.broadcast(
            this,
            Intent(AikoCoreContract.ACTION_LOG)
                .putExtra(AikoCoreContract.EXTRA_LEVEL, level)
                .putExtra(AikoCoreContract.EXTRA_MESSAGE, message)
                .putExtra(AikoCoreContract.EXTRA_TIME, System.currentTimeMillis()),
        )
    }

    // -----------------------------------------------------------------------
    // Tun descriptor ownership
    // -----------------------------------------------------------------------

    /**
     * Handed to [AikoPlatformInterface] so all the `TunOptions` translation lives in one
     * file while the inner-class instantiation stays where it is legal.
     */
    internal fun newTunBuilder(): Builder = Builder()

    /**
     * Takes ownership of a freshly established tun.
     *
     * On a reload `establish()` replaces the interface, which invalidates the previous
     * descriptor — closing it after the new one exists is what keeps the swap seamless.
     */
    internal fun adoptTunDescriptor(descriptor: ParcelFileDescriptor) {
        val previous = tun
        tun = descriptor
        if (previous != null && previous !== descriptor) {
            runCatching { previous.close() }
        }
    }

    private fun closeTun() {
        val current = tun ?: return
        tun = null
        runCatching { current.close() }
            .onFailure { Log.w(TAG, "closing the tun descriptor failed", it) }
    }

    // -----------------------------------------------------------------------
    // Foreground notification
    // -----------------------------------------------------------------------

    private fun enterForeground() {
        if (inForeground) return
        val initial = when (state) {
            AikoCoreContract.STATE_RUNNING -> notification.running(outboundMode, uploadRate, downloadRate)
            AikoCoreContract.STATE_FAILED -> notification.failed(lastError)
            else -> notification.starting()
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(AikoNotifications.ID_TUNNEL, initial, declaredForegroundServiceType())
            } else {
                startForeground(AikoNotifications.ID_TUNNEL, initial)
            }
            inForeground = true
        } catch (e: Exception) {
            // Android 12+ refuses a foreground start from the background. There is nothing
            // to salvage — without the foreground promotion the service is killed in
            // seconds — so report it rather than start a tunnel that will vanish.
            Log.e(TAG, "cannot enter the foreground", e)
            worker.execute {
                fail(
                    AikoCoreContract.ERROR_CORE_START_FAILED,
                    e.message ?: "the system refused to start the tunnel in the foreground",
                )
                handleStop()
            }
        }
    }

    /**
     * The foreground-service type, read back from the manifest rather than hardcoded.
     *
     * `startForeground(id, notification, type)` throws unless the type is a subset of what
     * the manifest declares. The manifest currently says `specialUse`; ARCHITECTURE-BRIEF
     * §3.5 argues for `systemExempted`, which is the type Android's own documentation lists
     * VPN apps under. Deriving the value means whoever settles that argument changes one
     * file, not two, and cannot leave the two disagreeing.
     */
    private fun declaredForegroundServiceType(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return 0
        val declared = runCatching {
            packageManager
                .getServiceInfo(ComponentName(this, AikoVpnService::class.java), 0)
                .foregroundServiceType
        }.getOrDefault(0)
        return if (declared != 0) declared else ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
    }

    private fun leaveForeground() {
        if (!inForeground) return
        inForeground = false
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
    }

    /**
     * Live upload/download in the notification, read from the core's own control API.
     *
     * The outbound mode is refreshed every fifth tick rather than every tick: it changes
     * only when the user changes it, and a request per second for a value that moves once an
     * hour is not worth the wakeups.
     */
    private fun startTelemetry() {
        stopTelemetry()
        val endpoint = core.endpoint ?: return
        modeTick = 0
        val reader = ClashTrafficReader(endpoint) { up, down ->
            uploadRate = up
            downloadRate = down
        }
        reader.start()
        trafficReader = reader
        notificationTask = ticker.scheduleWithFixedDelay(
            { refreshNotification() },
            0L,
            1L,
            TimeUnit.SECONDS,
        )
    }

    private fun stopTelemetry() {
        notificationTask?.cancel(false)
        notificationTask = null
        trafficReader?.stop()
        trafficReader = null
        uploadRate = -1L
        downloadRate = -1L
        outboundMode = null
    }

    private fun refreshNotification() {
        if (state != AikoCoreContract.STATE_RUNNING) return
        if (modeTick % MODE_REFRESH_TICKS == 0) {
            core.endpoint?.mode()?.let { outboundMode = it }
        }
        modeTick++
        notification.post(notification.running(outboundMode, uploadRate, downloadRate))
    }

    /**
     * A failed service does not sit in the foreground forever.
     *
     * The UI normally resolves a failure within seconds — either by rolling back to the
     * last-known-good configuration or by stopping. This only covers the case where the UI
     * process is gone and nobody is coming.
     */
    private fun scheduleLinger() {
        cancelLinger()
        lingerTask = ticker.schedule(
            {
                if (state == AikoCoreContract.STATE_FAILED) {
                    worker.execute { handleStop() }
                }
            },
            FAILURE_LINGER_SECONDS,
            TimeUnit.SECONDS,
        )
    }

    private fun cancelLinger() {
        lingerTask?.cancel(false)
        lingerTask = null
    }

    // -----------------------------------------------------------------------
    // State publication
    // -----------------------------------------------------------------------

    private fun publish(next: String, error: String?) {
        state = next
        lastError = error
        announceState()
    }

    private fun announceState() {
        AikoCoreContract.broadcast(
            this,
            Intent(AikoCoreContract.ACTION_STATE)
                .putExtra(AikoCoreContract.EXTRA_STATE, state)
                .putExtra(AikoCoreContract.EXTRA_ERROR, lastError),
        )
    }

    // -----------------------------------------------------------------------
    // Persisted intent, private to this process
    // -----------------------------------------------------------------------

    private fun readConfig(path: String?): String? {
        val file = path?.let(::File)?.takeIf { it.isFile }
            ?: CoreManager.activeConfig(this).takeIf { it.isFile }
            ?: return null
        return runCatching { file.readText() }
            .onFailure { Log.e(TAG, "cannot read ${file.absolutePath}", it) }
            .getOrNull()
            ?.takeIf { it.isNotBlank() }
    }

    private fun setDesiredRunning(value: Boolean) {
        preferences.edit().putBoolean(KEY_DESIRED_RUNNING, value).apply()
    }

    private fun readDesiredRunning(): Boolean = preferences.getBoolean(KEY_DESIRED_RUNNING, false)

    /**
     * Split-tunnel lists survive a process restart.
     *
     * Without this an always-on or boot start would route every app, silently discarding a
     * setting the user made on purpose — the exact class of surprise N5 exists to prevent.
     */
    private fun rememberSplitTunnel(include: List<String>, exclude: List<String>) {
        preferences.edit()
            .putStringSet(KEY_INCLUDE, include.toSet())
            .putStringSet(KEY_EXCLUDE, exclude.toSet())
            .apply()
    }

    private fun readInclude(): List<String> =
        preferences.getStringSet(KEY_INCLUDE, emptySet()).orEmpty().sorted()

    private fun readExclude(): List<String> =
        preferences.getStringSet(KEY_EXCLUDE, emptySet()).orEmpty().sorted()

    private companion object {
        const val TAG = "AikoVpnService"

        const val KEY_DESIRED_RUNNING = "desired.running"
        const val KEY_INCLUDE = "split.include"
        const val KEY_EXCLUDE = "split.exclude"
        const val KEY_LOCALE = "ui.locale"

        /** One control-API round trip per five seconds to keep the mode label honest. */
        const val MODE_REFRESH_TICKS = 5

        const val FAILURE_LINGER_SECONDS = 60L
    }
}
