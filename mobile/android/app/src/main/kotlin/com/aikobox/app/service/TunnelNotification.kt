package com.aikobox.app.service

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.aikobox.app.MainActivity
import com.aikobox.app.R
import java.util.Locale

/** Channel identifiers and their one-time registration. */
object AikoNotifications {

    /** The ongoing tunnel notification. Silent by design: it is a status line, not an alert. */
    const val CHANNEL_TUNNEL = "aikobox.tunnel"

    /** Notices the core itself raises — deprecation warnings and the like. */
    const val CHANNEL_NOTICES = "aikobox.notices"

    const val ID_TUNNEL = 1

    fun ensureChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_TUNNEL,
                context.getString(R.string.notification_channel_tunnel),
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                description = context.getString(R.string.notification_channel_tunnel_description)
                setShowBadge(false)
            },
        )
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_NOTICES,
                context.getString(R.string.notification_channel_notices),
                NotificationManager.IMPORTANCE_DEFAULT,
            ).apply {
                description = context.getString(R.string.notification_channel_notices_description)
            },
        )
    }
}

/**
 * The ongoing foreground notification: what the tunnel is doing, in which outbound mode, and
 * how fast — plus a one-tap stop.
 *
 * Two things make this less trivial than it looks.
 *
 * **It must exist before anything slow happens.** Android gives a foreground service roughly
 * five seconds between `startForegroundService` and `startForeground`, and misses become
 * `ForegroundServiceDidNotStartInTimeException`. [starting] is therefore buildable with no
 * core, no config and no network.
 *
 * **It is localised from the app's language, not the device's.** The user picks a language
 * inside AikoBox (`aikobox.locale`), and a notification in a different language than the app
 * that raised it reads as a bug. [applyLocale] rebuilds the resource context accordingly.
 */
class TunnelNotification(private val service: AikoVpnService) {

    private var resources: Context = service
    private var locale: Locale = Locale.getDefault()

    private val manager: NotificationManager?
        get() = service.getSystemService(NotificationManager::class.java)

    /** Re-resolves strings against [localeTag]; a null or unparsable tag keeps the device locale. */
    fun applyLocale(localeTag: String?) {
        val tag = localeTag?.takeIf { it.isNotBlank() } ?: return
        val parsed = runCatching { Locale.forLanguageTag(tag) }.getOrNull() ?: return
        if (parsed.language.isEmpty()) return
        locale = parsed
        val configuration = android.content.res.Configuration(service.resources.configuration)
        configuration.setLocale(parsed)
        resources = service.createConfigurationContext(configuration)
    }

    /** The placeholder posted the instant the service enters the foreground. */
    fun starting(): android.app.Notification = build(
        resources.getString(R.string.notification_starting_title),
        resources.getString(R.string.notification_starting_body),
    )

    fun stopping(): android.app.Notification = build(
        resources.getString(R.string.notification_title),
        resources.getString(R.string.notification_stopping_body),
    )

    /** The core's own message is shown verbatim; it is already redacted by the time it lands here. */
    fun failed(error: String?): android.app.Notification = build(
        resources.getString(R.string.notification_failed_title),
        error?.takeIf { it.isNotBlank() }.orEmpty(),
    )

    /**
     * @param mode the core's outbound mode wire name, or null while it is still unknown.
     * @param uploadBytesPerSecond negative before the first traffic sample arrives, which is
     *   reported as zero rather than hidden — a core that just came up genuinely has moved
     *   no bytes yet.
     */
    fun running(mode: String?, uploadBytesPerSecond: Long, downloadBytesPerSecond: Long): android.app.Notification {
        val up = formatRate(uploadBytesPerSecond.coerceAtLeast(0L))
        val down = formatRate(downloadBytesPerSecond.coerceAtLeast(0L))
        val label = modeLabel(mode)
        val text = if (label == null) {
            resources.getString(R.string.notification_running_body_no_mode, up, down)
        } else {
            resources.getString(R.string.notification_running_body, label, up, down)
        }
        return build(resources.getString(R.string.notification_running_title), text)
    }

    /** Replaces the posted notification in place. No-op when notifications are blocked. */
    fun post(notification: android.app.Notification) {
        runCatching { manager?.notify(AikoNotifications.ID_TUNNEL, notification) }
    }

    private fun modeLabel(mode: String?): String? = when (mode) {
        "rule" -> resources.getString(R.string.notification_mode_rule)
        "global" -> resources.getString(R.string.notification_mode_global)
        "direct" -> resources.getString(R.string.notification_mode_direct)
        else -> null
    }

    private fun build(title: String, text: String): android.app.Notification {
        AikoNotifications.ensureChannels(resources)
        return NotificationCompat.Builder(service, AikoNotifications.CHANNEL_TUNNEL)
            .setSmallIcon(R.drawable.ic_stat_tunnel)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(openAppIntent())
            .setOngoing(true)
            .setShowWhen(false)
            .setOnlyAlertOnce(true)
            .setLocalOnly(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .addAction(
                R.drawable.ic_stat_tunnel,
                resources.getString(R.string.notification_action_stop),
                stopIntent(),
            )
            .build()
    }

    private fun openAppIntent(): PendingIntent = PendingIntent.getActivity(
        service,
        REQUEST_OPEN,
        Intent(service, MainActivity::class.java)
            .setAction(Intent.ACTION_MAIN)
            .addCategory(Intent.CATEGORY_LAUNCHER)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    /**
     * A broadcast, not a service start.
     *
     * The service's runtime receiver is not exported and `setPackage` keeps the intent
     * inside the app, so the Android 14 rule about implicit intents reaching non-exported
     * *manifest* components does not apply. Broadcasting also sidesteps the Android 12+
     * background restriction on `startForegroundService`, which is the exact situation this
     * button is pressed in — the app is not on screen.
     */
    private fun stopIntent(): PendingIntent = PendingIntent.getBroadcast(
        service,
        REQUEST_STOP,
        Intent(AikoCoreContract.ACTION_STOP).setPackage(service.packageName),
        PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
    )

    private fun formatRate(bytesPerSecond: Long): String {
        var value = bytesPerSecond.coerceAtLeast(0L).toDouble()
        var unit = 0
        while (value >= 1024.0 && unit < UNITS.lastIndex) {
            value /= 1024.0
            unit++
        }
        return if (unit == 0) {
            String.format(locale, "%.0f %s/s", value, UNITS[unit])
        } else {
            String.format(locale, "%.1f %s/s", value, UNITS[unit])
        }
    }

    private companion object {
        const val REQUEST_OPEN = 100
        const val REQUEST_STOP = 101

        /** Binary units, matching what the core itself reports. Symbols, not prose. */
        val UNITS = arrayOf("B", "KiB", "MiB", "GiB", "TiB")
    }
}
