package com.aikobox.app.service

import android.content.Context
import android.util.Log
import io.nekohasekai.libbox.CommandServer
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.OverrideOptions
import io.nekohasekai.libbox.PlatformInterface
import java.io.File

/**
 * Owns the sing-box core's lifecycle inside the `:remote` process.
 *
 * libbox 1.13 removed `NewService`/`BoxService`; the surface is
 * `Libbox.setup(SetupOptions)` → `Libbox.newCommandServer(handler, platformInterface)` →
 * `server.start()` → `server.startOrReloadService(configJson, OverrideOptions)`. Every
 * tutorial written against 1.12 is wrong about this, so the sequence is spelled out here
 * once rather than inferred at each call site.
 *
 * The ordering is the point of this class, and it is the desktop app's ordering:
 *
 * * **N2 — validate before you break anything.** `Libbox.checkConfig` runs first, always.
 *   If it rejects the candidate and a core is already carrying traffic, nothing is touched:
 *   [start] throws and the existing tunnel is exactly as it was. `startOrReloadService` is
 *   only reached by a configuration the core has already agreed to parse.
 * * **N1 — a process that started is not a tunnel that works.** After the swap the core has
 *   to answer its own control API before [start] returns. Until then the caller must not
 *   publish `running`.
 * * **N3 — rollback is the caller's move, and this class leaves it possible.** A failed
 *   health gate tears the core down but keeps the command server alive, so restoring the
 *   last-known-good configuration is one more `startOrReloadService` rather than a cold
 *   restart of the whole service.
 */
class CoreManager(
    private val context: Context,
    private val platform: PlatformInterface,
    private val host: Host,
) {

    /** What the core needs from the service that owns it. */
    interface Host : AikoCommandServerHandler.Delegate {
        /**
         * Close the tun `ParcelFileDescriptor` before the core is torn down.
         *
         * Go holds a `dup()` of the descriptor and closes its own copy; this side owns the
         * original and is the only thing that can release it.
         */
        fun onReleaseTun()

        fun log(level: String, message: String)
    }

    /** A start that did not happen, carrying the code the Dart side branches on. */
    class StartFailure(
        val code: String,
        override val message: String,
        cause: Throwable? = null,
    ) : Exception(message, cause)

    data class StartRequest(
        val configJson: String,
        val includePackages: List<String> = emptyList(),
        val excludePackages: List<String> = emptyList(),
        val localeTag: String? = null,
    )

    private val handler = AikoCommandServerHandler(host)

    private var commandServer: CommandServer? = null

    /** The control endpoint of the configuration currently loaded, if it exposes one. */
    @Volatile
    var endpoint: ClashEndpoint? = null
        private set

    /** True between a successful [start] and the next [stop]. */
    @Volatile
    var isServing: Boolean = false
        private set

    /** The configuration the core is currently running, kept for `serviceReload`. */
    @Volatile
    private var activeConfigJson: String? = null

    @Volatile
    private var activeOverrides: StartRequest? = null

    /**
     * Validates, swaps, and waits for the core to serve.
     *
     * @return the core's version string.
     * @throws StartFailure with a code from [AikoCoreContract]; on failure the previous core,
     *   if any, is either untouched (rejected candidate) or fully torn down (failed swap).
     */
    @Throws(StartFailure::class)
    fun start(request: StartRequest): String {
        try {
            LibboxSetup.ensure(context, request.localeTag)
        } catch (e: Exception) {
            throw StartFailure(
                AikoCoreContract.ERROR_CORE_START_FAILED,
                e.message ?: "libbox initialisation failed",
                e,
            )
        }

        // N2. Nothing below this line runs against a configuration the core has not already
        // accepted, so a bad candidate cannot cost a working tunnel.
        checkConfig(request.configJson)?.let { rejection ->
            throw StartFailure(AikoCoreContract.ERROR_CONFIG_INVALID, rejection)
        }

        val server = try {
            ensureCommandServer()
        } catch (e: Exception) {
            throw StartFailure(
                AikoCoreContract.ERROR_CORE_START_FAILED,
                e.message ?: "the core's command server did not start",
                e,
            )
        }

        val candidateEndpoint = ClashEndpoint.parse(request.configJson)
        if (candidateEndpoint == null) {
            host.log(
                AikoCoreContract.LEVEL_WARNING,
                "configuration exposes no clash_api endpoint; the tunnel cannot be health-gated " +
                    "and the app cannot read proxies, traffic or connections",
            )
        }

        try {
            server.startOrReloadService(request.configJson, overridesFor(request))
        } catch (e: Exception) {
            // Past this point libbox has already replaced whatever was running, so the
            // previous core is gone whether or not the new one came up. Say so plainly:
            // `isServing` false is what tells the caller a rollback is now its problem.
            markNotServing()
            throw StartFailure(
                AikoCoreContract.ERROR_CORE_START_FAILED,
                e.message ?: "the core refused to start",
                e,
            )
        }

        // N1. The transport exists now, but "exists" is not "works": until the core answers
        // its own control API this start has not succeeded and must not be reported as one.
        val version = if (candidateEndpoint != null) {
            candidateEndpoint.awaitHealthy(HEALTH_GATE_MS) ?: run {
                markNotServing()
                throw StartFailure(
                    AikoCoreContract.ERROR_CORE_START_FAILED,
                    "the core started but never answered its control API",
                )
            }
        } else {
            runCatching { Libbox.version() }.getOrNull() ?: "unknown"
        }

        endpoint = candidateEndpoint
        activeConfigJson = request.configJson
        activeOverrides = request
        isServing = true
        host.log(AikoCoreContract.LEVEL_INFO, "core $version is serving")
        return version
    }

    /**
     * Runs `Libbox.checkConfig`, the direct equivalent of the desktop's `sing-box check -c`.
     *
     * @return null when the configuration is valid, otherwise the core's own message.
     */
    fun checkConfig(configJson: String): String? = try {
        LibboxSetup.ensure(context)
        Libbox.checkConfig(configJson)
        null
    } catch (e: Exception) {
        e.message ?: "invalid configuration"
    }

    /** Re-applies the configuration the core is already running, at the core's own request. */
    fun reload() {
        val json = activeConfigJson
            ?: LibboxSetup.activeConfigFile(context).takeIf { it.isFile }?.readText()
            ?: run {
                host.log(AikoCoreContract.LEVEL_WARNING, "reload requested but no active configuration")
                return
            }
        val previous = activeOverrides
        start(
            StartRequest(
                configJson = json,
                includePackages = previous?.includePackages.orEmpty(),
                excludePackages = previous?.excludePackages.orEmpty(),
                localeTag = previous?.localeTag,
            ),
        )
    }

    /**
     * Stops the core.
     *
     * The order is load-bearing and is the one sing-box-for-android uses: release the tun
     * descriptor, then close the service, then — only on [dispose] — the command server.
     */
    fun stop() {
        markNotServing()
        activeOverrides = null
        releaseTunQuietly()
        closeServiceQuietly()
    }

    /**
     * Records that nothing is carrying traffic any more.
     *
     * The caller reads [isServing] after a [StartFailure] to tell the two cases apart that
     * matter: a candidate rejected before the swap, where the previous tunnel is still up
     * and must not be reported as broken, and a swap that failed, where it is gone.
     */
    private fun markNotServing() {
        isServing = false
        endpoint = null
        activeConfigJson = null
    }

    /** Stops the core and shuts the command server down. The instance is unusable afterwards. */
    fun dispose() {
        stop()
        val server = commandServer
        commandServer = null
        runCatching { server?.close() }
            .onFailure { Log.w(TAG, "command server close failed", it) }
    }

    private fun overridesFor(request: StartRequest): OverrideOptions = OverrideOptions().apply {
        // VpnService.Builder throws UnsupportedOperationException if both an allow-list and
        // a deny-list are applied, so at most one is ever populated. The Dart side already
        // refuses to send both; this is the second lock on the same door.
        when {
            request.includePackages.isNotEmpty() ->
                includePackage = LibboxStringArray(request.includePackages)

            request.excludePackages.isNotEmpty() ->
                excludePackage = LibboxStringArray(request.excludePackages)
        }
    }

    private fun ensureCommandServer(): CommandServer {
        commandServer?.let { return it }
        val server = Libbox.newCommandServer(handler, platform)
        server.start()
        commandServer = server
        return server
    }

    private fun closeServiceQuietly() {
        runCatching { commandServer?.closeService() }
            .onFailure { Log.d(TAG, "closeService: ${it.message}") }
    }

    private fun releaseTunQuietly() {
        runCatching { host.onReleaseTun() }
            .onFailure { Log.w(TAG, "releasing the tun descriptor failed", it) }
    }

    companion object {
        private const val TAG = "AikoCoreManager"

        /**
         * How long the core has to answer its control API. §3.5 bounds each start stage at
         * 15 s; the Dart side allows 20 s for the whole sequence, so this must stay under it.
         */
        const val HEALTH_GATE_MS = 15_000L

        /** The last configuration the Dart side promoted, used for always-on and boot starts. */
        fun activeConfig(context: Context): File = LibboxSetup.activeConfigFile(context)
    }
}
