package com.aikobox.app

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry

/**
 * `MethodChannel("aikobox/shell")` — the shell's narrow host surface.
 *
 * Deliberately separate from [AikoCorePlugin]: contract §4.4 fixes `aikobox/core` to the
 * tunnel's own vocabulary (consent, start, stop, checkConfig), and runtime-permission
 * plumbing plus "open the system settings page" are UI concerns that have no business
 * widening a contract two other agents code against.
 *
 * The Dart client (`lib/features/shell/shell_host_channel.dart`) latches to unavailable on
 * `MissingPluginException`, so a build without this class simply skips the notification
 * prompt. That degradation is real but expensive: on Android 13+ `POST_NOTIFICATIONS` is a
 * runtime permission, and without it the foreground service still runs while its ongoing
 * notification — the only in-system status line and the only Stop button — is never shown.
 *
 * ```
 * notificationPermissionStatus() -> "granted" | "denied" | "permanentlyDenied" | "unsupported"
 * requestNotificationPermission() -> Boolean   // resolves after the dialog closes
 * openNotificationSettings()      -> Boolean
 * openVpnSettings()               -> Boolean
 * ```
 */
class AikoShellPlugin :
    FlutterPlugin,
    MethodChannel.MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var appContext: Context
    private lateinit var channel: MethodChannel

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingRequest: MethodChannel.Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        appContext = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onDetachedFromActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding = null
        activity = null
        // A dialog whose Activity is gone will never answer; failing the future beats
        // hanging the caller forever.
        pendingRequest?.let { pending ->
            pendingRequest = null
            pending.success(false)
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "notificationPermissionStatus" -> result.success(notificationStatus())
            "requestNotificationPermission" -> requestNotificationPermission(result)
            "openNotificationSettings" -> result.success(openNotificationSettings())
            "openVpnSettings" -> result.success(openVpnSettings())
            else -> result.notImplemented()
        }
    }

    // -----------------------------------------------------------------------
    // POST_NOTIFICATIONS
    // -----------------------------------------------------------------------

    private fun notificationStatus(): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            // Pre-33 there is no runtime permission at all. Reporting "granted" rather than
            // "unsupported" is the honest answer to the question the shell is asking, which
            // is "may I post the tunnel notification?".
            return STATUS_GRANTED
        }
        val held = ContextCompat.checkSelfPermission(
            appContext,
            Manifest.permission.POST_NOTIFICATIONS,
        ) == PackageManager.PERMISSION_GRANTED
        if (held) return STATUS_GRANTED

        // `shouldShowRequestPermissionRationale` is false both before the first ask and
        // after a permanent denial, so it only distinguishes the two once we know an ask
        // has happened. Without that record every fresh install would look permanently
        // denied and the shell would send the user to Settings instead of asking.
        val current = activity
        val asked = preferences().getBoolean(KEY_ASKED, false)
        if (asked && current != null &&
            !ActivityCompat.shouldShowRequestPermissionRationale(
                current,
                Manifest.permission.POST_NOTIFICATIONS,
            )
        ) {
            return STATUS_PERMANENTLY_DENIED
        }
        return STATUS_DENIED
    }

    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }
        if (ContextCompat.checkSelfPermission(
                appContext,
                Manifest.permission.POST_NOTIFICATIONS,
            ) == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        val current = activity
        if (current == null || pendingRequest != null) {
            result.success(false)
            return
        }
        pendingRequest = result
        preferences().edit().putBoolean(KEY_ASKED, true).apply()
        try {
            ActivityCompat.requestPermissions(
                current,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                PERMISSION_REQUEST,
            )
        } catch (e: Exception) {
            pendingRequest = null
            result.success(false)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        val pending = pendingRequest ?: return true
        pendingRequest = null
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pending.success(granted)
        return true
    }

    // -----------------------------------------------------------------------
    // System settings pages
    // -----------------------------------------------------------------------

    private fun openNotificationSettings(): Boolean {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                .putExtra(Settings.EXTRA_APP_PACKAGE, appContext.packageName)
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", appContext.packageName, null))
        }
        return launch(intent)
    }

    private fun openVpnSettings(): Boolean = launch(Intent(Settings.ACTION_VPN_SETTINGS))

    /**
     * Prefers the Activity so the settings page lands on top of the app's own task; falls
     * back to a new task when the app is running without one.
     */
    private fun launch(intent: Intent): Boolean {
        activity?.let { current ->
            return runCatching { current.startActivity(intent) }.isSuccess
        }
        return runCatching {
            appContext.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }.isSuccess
    }

    private fun preferences() =
        appContext.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE)

    private companion object {
        const val CHANNEL = "aikobox/shell"
        const val PREFERENCES = "aikobox.shell"
        const val KEY_ASKED = "notification.asked"
        const val PERMISSION_REQUEST = 0x504E

        const val STATUS_GRANTED = "granted"
        const val STATUS_DENIED = "denied"
        const val STATUS_PERMANENTLY_DENIED = "permanentlyDenied"
    }
}
