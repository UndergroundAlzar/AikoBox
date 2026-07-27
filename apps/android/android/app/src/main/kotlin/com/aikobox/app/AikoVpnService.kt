package com.aikobox.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.IBinder
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.atomic.AtomicReference

class AikoVpnService : VpnService() {
    private val worker = Executors.newSingleThreadExecutor()
    private var boxSession: BoxSession? = null
    private var tunDescriptor: ParcelFileDescriptor? = null
    private lateinit var platformInterface: AndroidPlatformInterface

    override fun onCreate() {
        super.onCreate()
        LibboxRuntime.initialize(applicationContext)
        platformInterface = AndroidPlatformInterface(this)
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> requestStop()
            ACTION_START, ACTION_RELOAD -> {
                startForeground(NOTIFICATION_ID, notification("Starting"))
                val path = intent.getStringExtra(EXTRA_PROFILE_PATH)
                if (path.isNullOrBlank()) {
                    fail(IllegalArgumentException("profilePath is required"))
                } else {
                    worker.execute {
                        runCatching {
                            val content = readProfile(path)
                            if (intent.action == ACTION_START) startCore(content) else reloadCore(content)
                            setActiveProfilePath(path)
                        }.onFailure(::fail)
                    }
                }
            }
        }
        return START_NOT_STICKY
    }

    override fun onBind(intent: Intent): IBinder? = super.onBind(intent)

    override fun onRevoke() {
        requestStop()
        super.onRevoke()
    }

    override fun onDestroy() {
        closeResources()
        worker.shutdownNow()
        super.onDestroy()
    }

    fun replaceTunDescriptor(descriptor: ParcelFileDescriptor) {
        tunDescriptor?.close()
        tunDescriptor = descriptor
    }

    fun requestStopFromCore() {
        requestStop()
    }

    fun showCoreNotification(title: String, body: String) {
        val safeTitle = title.take(120).ifBlank { "AikoBox" }
        val safeBody = body.take(240)
        val message = if (safeBody.isBlank()) safeTitle else "$safeTitle: $safeBody"
        updateNotification(message)
    }

    private fun startCore(content: String) {
        check(prepare(this) == null) { "VPN permission is missing or was revoked." }
        setStatus(VpnState.STARTING)
        boxSession?.close()
        boxSession = BoxSession(this, platformInterface).also { it.start(content) }
        setStatus(VpnState.RUNNING)
        updateNotification("Connected")
    }

    private fun reloadCore(content: String) {
        check(prepare(this) == null) { "VPN permission is missing or was revoked." }
        setStatus(VpnState.STARTING)
        val session = boxSession
        if (session == null) {
            startCore(content)
            return
        }
        session.reload(content)
        setStatus(VpnState.RUNNING)
        updateNotification("Connected")
    }

    private fun requestStop() {
        worker.execute {
            setStatus(VpnState.STOPPING)
            closeResources()
            setActiveProfilePath(null)
            setStatus(VpnState.STOPPED)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun closeResources() {
        runCatching { boxSession?.close() }
        boxSession = null
        runCatching { tunDescriptor?.close() }
        tunDescriptor = null
        platformInterface.close()
    }

    private fun fail(error: Throwable) {
        lastError.set(NativeRedaction.message(error.message ?: error.javaClass.simpleName))
        setStatus(VpnState.ERROR)
        closeResources()
        setActiveProfilePath(null)
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun readProfile(path: String): String {
        val file = File(path).canonicalFile
        require(file.isFile) { "Profile does not exist: $file" }
        require(file.length() in 1..MAX_PROFILE_BYTES) {
            "Profile must be between 1 byte and 4 MiB."
        }
        return file.readText(Charsets.UTF_8)
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            getSystemService(NotificationManager::class.java).createNotificationChannel(
                NotificationChannel(
                    NOTIFICATION_CHANNEL,
                    "AikoBox VPN",
                    NotificationManager.IMPORTANCE_LOW,
                ),
            )
        }
    }

    private fun notification(text: String): android.app.Notification {
        val openIntent =
            PendingIntent.getActivity(
                this,
                0,
                packageManager.getLaunchIntentForPackage(packageName),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        val stopIntent =
            PendingIntent.getService(
                this,
                1,
                Intent(this, AikoVpnService::class.java).setAction(ACTION_STOP),
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setContentTitle("AikoBox")
            .setContentText(text)
            .setContentIntent(openIntent)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(0, "Stop", stopIntent)
            .build()
    }

    private fun updateNotification(text: String) {
        getSystemService(NotificationManager::class.java).notify(
            NOTIFICATION_ID,
            notification(text),
        )
    }

    private fun setStatus(value: VpnState) {
        status.set(value)
        if (value != VpnState.ERROR) lastError.set(null)
        val snapshot = statusSnapshot()
        statusListeners.forEach { listener -> listener(snapshot) }
    }

    enum class VpnState {
        STOPPED,
        STARTING,
        RUNNING,
        STOPPING,
        ERROR,
    }

    companion object {
        const val ACTION_START = "com.aikobox.app.action.START"
        const val ACTION_RELOAD = "com.aikobox.app.action.RELOAD"
        const val ACTION_STOP = "com.aikobox.app.action.STOP"
        const val EXTRA_PROFILE_PATH = "profilePath"

        private const val NOTIFICATION_CHANNEL = "aikobox_vpn"
        private const val NOTIFICATION_ID = 2001
        private const val MAX_PROFILE_BYTES = 4L * 1024L * 1024L
        private val status = AtomicReference(VpnState.STOPPED)
        private val lastError = AtomicReference<String?>(null)
        private val activeProfilePath = AtomicReference<String?>(null)
        private val statusListeners =
            CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()

        fun statusSnapshot(): Map<String, Any?> =
            mapOf(
                "state" to status.get().name.lowercase(),
                "message" to lastError.get(),
                "activeProfilePath" to activeProfilePath.get(),
            )

        fun setActiveProfilePath(path: String?) {
            activeProfilePath.set(path)
        }

        fun addStatusListener(listener: (Map<String, Any?>) -> Unit) {
            statusListeners += listener
        }

        fun removeStatusListener(listener: (Map<String, Any?>) -> Unit) {
            statusListeners -= listener
        }
    }
}

internal object NativeRedaction {
    fun message(input: String): String =
        input
            .replace(
                Regex("""https?://[^\s<>"']+""", RegexOption.IGNORE_CASE),
                "[REDACTED-URL]",
            )
            .replace(
                Regex(
                    """\b(token|password|passwd|secret|authorization|uuid)\s*[:=]\s*([^\s,;]+)""",
                    RegexOption.IGNORE_CASE,
                ),
                "${'$'}1=[REDACTED]",
            )
            .replace(
                Regex(
                    """\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b""",
                    RegexOption.IGNORE_CASE,
                ),
                "[REDACTED-ID]",
            )
            .take(240)
}
