package com.aikobox.app.service

import android.util.Log
import io.nekohasekai.libbox.CommandServerHandler
import io.nekohasekai.libbox.SystemProxyStatus

/**
 * The callbacks libbox's `CommandServer` makes back into the host.
 *
 * These are not the app's control surface — the UI drives the tunnel through
 * `MethodChannel("aikobox/core")` and reads it through the Clash API. This interface exists
 * for requests that originate *inside* the core: a config that asks the service to reload
 * itself, a deprecation notice, or a system-proxy toggle on platforms that have one.
 *
 * Every method here is invoked on a Go-owned gRPC thread. [Delegate] is expected to hand the
 * work to the service's own worker rather than block.
 */
class AikoCommandServerHandler(private val delegate: Delegate) : CommandServerHandler {

    /** What the service must be able to do on the core's behalf. */
    interface Delegate {
        /** Shut the tunnel down, as if the user had pressed stop. */
        fun onCoreRequestedStop()

        /** Re-apply the active configuration without dropping the service. */
        fun onCoreRequestedReload()

        /** A diagnostic line from the core's own machinery. */
        fun onCoreDebugMessage(message: String)
    }

    override fun serviceStop() {
        Log.i(TAG, "core requested stop")
        delegate.onCoreRequestedStop()
    }

    override fun serviceReload() {
        Log.i(TAG, "core requested reload")
        delegate.onCoreRequestedReload()
    }

    /**
     * Android has no per-app system proxy an ordinary application may set.
     *
     * `available = false` is the honest answer and makes the core stop offering the toggle,
     * rather than the app pretending to have flipped something it cannot reach. The tun
     * already carries every app's traffic, so nothing is lost.
     */
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus().apply {
        available = false
        enabled = false
    }

    override fun setSystemProxyEnabled(enabled: Boolean) {
        throw UnsupportedOperationException("android: no settable system proxy")
    }

    override fun writeDebugMessage(message: String) {
        delegate.onCoreDebugMessage(message)
    }

    private companion object {
        const val TAG = "AikoCommandServer"
    }
}
