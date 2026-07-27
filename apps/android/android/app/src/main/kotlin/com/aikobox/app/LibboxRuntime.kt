package com.aikobox.app

import android.content.Context
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import io.nekohasekai.libbox.SetupOptions
import io.nekohasekai.libbox.SystemProxyStatus
import java.io.File

object LibboxRuntime {
    private val lock = Any()
    @Volatile private var initialized = false

    fun initialize(context: Context) {
        if (initialized) return
        synchronized(lock) {
            if (initialized) return
            val workingDirectory = File(context.filesDir, "sing-box").apply { mkdirs() }
            Libbox.setup(
                SetupOptions().apply {
                    basePath = context.filesDir.absolutePath
                    workingPath = workingDirectory.absolutePath
                    tempPath = context.cacheDir.absolutePath
                    fixAndroidStack = true
                    commandServerListenPort = 0
                    commandServerSecret = ""
                    logMaxLines = 3000
                    debug = BuildConfig.DEBUG
                },
            )
            initialized = true
        }
    }

    fun checkProfile(content: String) {
        Libbox.checkConfig(content)
    }
}

class BoxSession(
    private val service: AikoVpnService,
    platformInterface: PlatformInterface,
) : CommandServerHandler {
    private val server = CommandServer(this, platformInterface)
    private var currentProfile: String? = null

    fun start(profile: String) {
        var started = false
        try {
            server.start()
            reload(profile)
            started = true
        } finally {
            if (!started) {
                close()
            }
        }
    }

    fun reload(profile: String) {
        Libbox.checkConfig(profile)
        server.startOrReloadService(profile, OverrideOptions())
        currentProfile = profile
    }

    fun close() {
        runCatching { server.closeService() }
        runCatching { server.close() }
        currentProfile = null
    }

    override fun serviceStop() {
        service.requestStopFromCore()
    }

    override fun serviceReload() {
        currentProfile?.let(::reload)
    }

    override fun getSystemProxyStatus(): SystemProxyStatus =
        SystemProxyStatus().apply {
            available = false
            enabled = false
        }

    override fun setSystemProxyEnabled(enabled: Boolean) {
        Log.i(TAG, "System proxy is not supported by the Android VPN service: $enabled")
    }

    override fun writeDebugMessage(message: String?) {
        Log.d(TAG, message.orEmpty())
    }

    companion object {
        private const val TAG = "AikoBox/libbox"
    }
}
