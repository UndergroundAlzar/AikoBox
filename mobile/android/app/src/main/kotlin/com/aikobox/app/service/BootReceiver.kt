package com.aikobox.app.service

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.content.ContextCompat

/**
 * Brings the tunnel back after a reboot, but only when it was up when the device went down.
 *
 * **Needs a manifest entry** — see the `notDone` notes. Declare it in the `:remote` process
 * so it reads the same private preferences the service writes; a receiver in the UI process
 * would be reading a `SharedPreferences` file another process owns, which Android does not
 * keep coherent.
 *
 * This is the *fallback* path. The supported way to have a VPN survive a reboot on Android
 * is always-on VPN in system settings, which the service already advertises through
 * `SUPPORTS_ALWAYS_ON` and handles via the null-Intent branch of `onStartCommand`. This
 * receiver covers the user who wants the tunnel back without handing the system a lockdown
 * switch.
 *
 * The decision is deliberately narrow: the tunnel is restored only if the last thing that
 * happened to it was *not* an explicit stop. Rebooting is not consent to reconnect for
 * someone who turned the VPN off before shutting down.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action !in BOOT_ACTIONS) return

        val preferences = context.getSharedPreferences(
            CrashRestartPolicy.PREFERENCES_NAME,
            Context.MODE_PRIVATE,
        )
        if (!preferences.getBoolean(KEY_DESIRED_RUNNING, false)) {
            Log.i(TAG, "boot completed; the tunnel was not running, leaving it alone")
            return
        }
        if (!CoreManager.activeConfig(context).isFile) {
            Log.w(TAG, "boot completed; no promoted configuration to start")
            return
        }

        try {
            // No config path: the service reads the last promoted configuration itself, the
            // same way the always-on path does.
            ContextCompat.startForegroundService(
                context,
                AikoCoreContract.serviceIntent(context, AikoCoreContract.ACTION_START),
            )
        } catch (e: Exception) {
            // Android 15 restricts starting specialUse foreground services from
            // BOOT_COMPLETED. There is no workaround from here, and pretending otherwise
            // would leave the user believing the tunnel came back.
            Log.e(TAG, "the system refused a foreground start from boot", e)
        }
    }

    private companion object {
        const val TAG = "AikoBootReceiver"
        const val KEY_DESIRED_RUNNING = "desired.running"

        val BOOT_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            // Several Chinese OEM ROMs send this instead of BOOT_COMPLETED, and zh-CN is
            // this app's primary audience.
            "android.intent.action.QUICKBOOT_POWERON",
        )
    }
}
