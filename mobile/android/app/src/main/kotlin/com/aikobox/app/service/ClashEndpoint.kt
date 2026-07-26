package com.aikobox.app.service

import android.util.Log
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject

/**
 * The `experimental.clash_api` control endpoint of a sing-box configuration.
 *
 * Everything except lifecycle travels over this API (contract §4.4), so both processes need
 * to be able to find it. Rather than shuttle it across the process boundary, each side reads
 * it out of the configuration JSON — the one artefact that is already shared, already
 * authoritative, and already the exact thing the core was handed.
 */
data class ClashEndpoint(val port: Int, val secret: String) {

    companion object {

        private const val TAG = "AikoClashEndpoint"

        /**
         * Parses `experimental.clash_api.external_controller` out of a sing-box config.
         *
         * Returns null when the configuration exposes no control API — a legitimate state,
         * not an error: the tunnel still works, the UI just cannot introspect it.
         */
        fun parse(configJson: String): ClashEndpoint? = try {
            val clashApi = JSONObject(configJson)
                .optJSONObject("experimental")
                ?.optJSONObject("clash_api")
            val port = clashApi?.let { portOf(it.optString("external_controller")) }
            if (clashApi == null || port == null) {
                null
            } else {
                ClashEndpoint(port, clashApi.optString("secret"))
            }
        } catch (e: Exception) {
            Log.w(TAG, "config does not expose a clash_api endpoint", e)
            null
        }

        /** Same, reading from disk. Returns null when the file is missing or unparseable. */
        fun parseFile(file: File): ClashEndpoint? = try {
            if (file.isFile) parse(file.readText()) else null
        } catch (e: IOException) {
            Log.w(TAG, "cannot read ${file.absolutePath}", e)
            null
        }

        /**
         * Extracts the port from a Go listen address: `127.0.0.1:9090`, `:9090`,
         * `0.0.0.0:9090` or `[::1]:9090` all yield 9090.
         *
         * The host is deliberately discarded. A core configured to listen on `0.0.0.0` is
         * still reachable on loopback, and loopback is the only address this app is willing
         * to send the control secret to.
         */
        private fun portOf(listen: String): Int? {
            val trimmed = listen.trim()
            if (trimmed.isEmpty()) return null
            val port = trimmed.substringAfterLast(':', "").toIntOrNull() ?: return null
            return if (port in 1..65535) port else null
        }
    }

    val baseUrl: String get() = "http://127.0.0.1:$port"

    /**
     * `GET /version`, the cheapest proof that the core is not merely alive but serving.
     *
     * This is the Kotlin half of **N1**: `startOrReloadService` returning without throwing
     * says the Go side accepted the configuration, not that traffic can flow. Only an answer
     * here is evidence.
     *
     * @return the core's version string, or null on any failure at all.
     */
    fun version(timeoutMs: Int = 2_000): String? =
        get("/version", timeoutMs)?.let { body ->
            runCatching { JSONObject(body).optString("version").ifEmpty { null } }.getOrNull()
        }

    /** `GET /configs` → `mode`, one of `rule`, `global`, `direct`. Null when unavailable. */
    fun mode(timeoutMs: Int = 2_000): String? =
        get("/configs", timeoutMs)?.let { body ->
            runCatching { JSONObject(body).optString("mode").ifEmpty { null } }.getOrNull()
        }

    /** Applies the bearer token the core expects, when one is configured. */
    internal fun authorize(connection: HttpURLConnection) {
        if (secret.isNotEmpty()) {
            connection.setRequestProperty("Authorization", "Bearer $secret")
        }
    }

    internal fun open(path: String, connectTimeoutMs: Int, readTimeoutMs: Int): HttpURLConnection {
        val connection = URL("$baseUrl$path").openConnection() as HttpURLConnection
        connection.requestMethod = "GET"
        connection.connectTimeout = connectTimeoutMs
        connection.readTimeout = readTimeoutMs
        connection.useCaches = false
        connection.instanceFollowRedirects = false
        authorize(connection)
        return connection
    }

    private fun get(path: String, timeoutMs: Int): String? {
        var connection: HttpURLConnection? = null
        return try {
            connection = open(path, timeoutMs, timeoutMs)
            if (connection.responseCode != HttpURLConnection.HTTP_OK) return null
            connection.inputStream.bufferedReader().use { it.readText() }
        } catch (e: Exception) {
            // The core not answering yet is the normal case during a start; it is the
            // caller's polling loop that decides when that stops being acceptable.
            null
        } finally {
            connection?.disconnect()
        }
    }

    /**
     * Waits for the control API to answer, or gives up.
     *
     * @return the version string once the core answers, null once [timeoutMs] has elapsed.
     */
    fun awaitHealthy(timeoutMs: Long, pollIntervalMs: Long = 250L): String? {
        val deadline = System.nanoTime() + timeoutMs * 1_000_000L
        while (true) {
            val version = version(timeoutMs = 1_500)
            if (version != null) return version
            if (System.nanoTime() >= deadline) return null
            try {
                Thread.sleep(pollIntervalMs)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return null
            }
        }
    }
}
