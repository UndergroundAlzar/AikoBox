package com.aikobox.app.service

import android.content.Context
import android.content.Intent

/**
 * The wire contract between the Flutter UI process and the `:remote` service process.
 *
 * The two processes share nothing but the filesystem and the Binder, so every constant a
 * both-sides message depends on lives here and nowhere else. There are deliberately no
 * singletons holding cross-process state: a `static` written in `:remote` is invisible in
 * the UI process, and code that assumes otherwise fails only on the paths that are hardest
 * to test (always-on VPN, boot restart, UI process death while the tunnel stays up).
 *
 * Direction of travel:
 *
 * ```
 * UI ──startForegroundService(ACTION_START | ACTION_STOP)──▶ AikoVpnService
 * UI ──sendBroadcast(ACTION_QUERY_STATE)───────────────────▶ AikoVpnService   (no-op if dead)
 * UI ◀──sendBroadcast(ACTION_STATE | ACTION_LOG)─────────── AikoVpnService
 * ```
 *
 * Commands are explicit service intents rather than broadcasts because a broadcast cannot
 * bring a stopped service up. The state query is a broadcast for exactly the mirrored
 * reason: it must *not* start anything, and silence is a meaningful answer ("nothing is
 * running").
 *
 * The `state` and `level` values are the same strings `CoreState.fromWire` and
 * `LogLevel.fromWire` parse on the Dart side (`mobile/lib/core/models.dart`). The error
 * codes are the ones `AikoCoreException` declares.
 */
object AikoCoreContract {

    // ---------------------------------------------------------------------
    // UI -> service
    // ---------------------------------------------------------------------

    /**
     * Start or reload the core.
     *
     * With [EXTRA_CONFIG_PATH] the service starts that exact configuration. Without it —
     * always-on VPN, a boot restart, a quick-settings tile tap — the service falls back to
     * the last promoted configuration on disk, [WORK_ACTIVE_CONFIG].
     */
    const val ACTION_START = "com.aikobox.app.action.CORE_START"

    /** Stop the core and take the service out of the foreground. */
    const val ACTION_STOP = "com.aikobox.app.action.CORE_STOP"

    /**
     * Broadcast asking a live service to re-announce its state. Deliberately not a service
     * intent: if nothing is running there must be no side effect at all.
     */
    const val ACTION_QUERY_STATE = "com.aikobox.app.action.CORE_QUERY_STATE"

    // ---------------------------------------------------------------------
    // service -> UI
    // ---------------------------------------------------------------------

    /**
     * `{state, error?}` — feeds `EventChannel("aikobox/core/status")`.
     *
     * Note what is *not* here: the Clash API port and secret. The UI process derives those
     * from the configuration file itself (see `ClashEndpoint`), so the control-plane
     * credential never travels over an intent bus it does not need to travel over.
     */
    const val ACTION_STATE = "com.aikobox.app.action.CORE_STATE"

    /** `{level, message, time}` — feeds `EventChannel("aikobox/core/logs")`. */
    const val ACTION_LOG = "com.aikobox.app.action.CORE_LOG"

    // ---------------------------------------------------------------------
    // Extras
    // ---------------------------------------------------------------------

    /**
     * Absolute path of the sing-box configuration to start.
     *
     * The configuration travels as a file rather than as a string extra because a real
     * subscription expands to hundreds of kilobytes of JSON and the Binder transaction
     * buffer is a shared, ~1 MB, per-process resource. A `TransactionTooLargeException`
     * here would be a "works on my small profile" bug.
     */
    const val EXTRA_CONFIG_PATH = "com.aikobox.app.extra.CONFIG_PATH"

    /** Split-tunnel allow-list. Mutually exclusive with [EXTRA_EXCLUDE_PACKAGES]. */
    const val EXTRA_INCLUDE_PACKAGES = "com.aikobox.app.extra.INCLUDE_PACKAGES"

    /** Split-tunnel deny-list. Mutually exclusive with [EXTRA_INCLUDE_PACKAGES]. */
    const val EXTRA_EXCLUDE_PACKAGES = "com.aikobox.app.extra.EXCLUDE_PACKAGES"

    /**
     * BCP-47 tag the user picked in the app, so the notification is written in the same
     * language as the UI rather than in the device language.
     */
    const val EXTRA_LOCALE = "com.aikobox.app.extra.LOCALE"

    const val EXTRA_STATE = "com.aikobox.app.extra.STATE"
    const val EXTRA_ERROR = "com.aikobox.app.extra.ERROR"
    const val EXTRA_LEVEL = "com.aikobox.app.extra.LEVEL"
    const val EXTRA_MESSAGE = "com.aikobox.app.extra.MESSAGE"
    const val EXTRA_TIME = "com.aikobox.app.extra.TIME"

    // ---------------------------------------------------------------------
    // States — must match CoreState.wireName in mobile/lib/core/models.dart
    // ---------------------------------------------------------------------

    const val STATE_STOPPED = "stopped"
    const val STATE_STARTING = "starting"
    const val STATE_RUNNING = "running"
    const val STATE_STOPPING = "stopping"
    const val STATE_FAILED = "failed"

    // ---------------------------------------------------------------------
    // Log levels — must match LogLevel.wireName
    // ---------------------------------------------------------------------

    const val LEVEL_DEBUG = "debug"
    const val LEVEL_INFO = "info"
    const val LEVEL_WARNING = "warning"
    const val LEVEL_ERROR = "error"

    // ---------------------------------------------------------------------
    // Error codes — must match AikoCoreException in mobile/lib/core/core_channel.dart
    // ---------------------------------------------------------------------

    const val ERROR_CONFIG_INVALID = "E_CONFIG_INVALID"
    const val ERROR_VPN_PERMISSION_DENIED = "E_VPN_PERMISSION_DENIED"
    const val ERROR_CORE_START_FAILED = "E_CORE_START_FAILED"
    const val ERROR_TUN_ESTABLISH_FAILED = "E_TUN_ESTABLISH_FAILED"
    const val ERROR_UNKNOWN = "E_UNKNOWN"

    // ---------------------------------------------------------------------
    // On-disk layout, shared with mobile/lib/core/paths.dart and config_store.dart
    // ---------------------------------------------------------------------

    /** `<filesDir>/work` — `AikoDirs.workDir` on the Dart side. */
    const val WORK_DIR = "work"

    /** `<filesDir>/work/sing-box.json` — `SingboxConfigStore.activeFile`. */
    const val WORK_ACTIVE_CONFIG = "work/sing-box.json"

    /** Where the UI process stages the configuration handed to `start()`. */
    const val PENDING_CONFIG = "aiko-pending-config.json"

    /**
     * Builds an explicit intent addressed at [AikoVpnService].
     *
     * Explicit because `android:permission="android.permission.BIND_VPN_SERVICE"` on the
     * service would reject anything else; same-UID callers are exempt from that check, but
     * only when the component is named.
     */
    fun serviceIntent(context: Context, action: String): Intent =
        Intent(context, AikoVpnService::class.java).setAction(action)

    /**
     * Sends an app-internal broadcast.
     *
     * `setPackage` keeps it inside this app: without it the intent is visible to every
     * receiver on the device, which for a state frame carrying the Clash API secret would
     * be a credential leak.
     */
    fun broadcast(context: Context, intent: Intent) {
        context.sendBroadcast(intent.setPackage(context.packageName))
    }
}
