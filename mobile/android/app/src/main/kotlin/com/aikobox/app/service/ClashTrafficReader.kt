package com.aikobox.app.service

import android.util.Log
import java.net.HttpURLConnection
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

/**
 * Streams `GET /traffic` from the core's own control API so the foreground notification can
 * show live up/down rates.
 *
 * Why HTTP and not libbox's `CommandClient`: the command client hands back `StatusMessage`,
 * a `go.Seq.Proxy` whose lifetime is owned by the Go ref map. Reading one after Go has
 * released it takes the whole process down, and the notification updater runs on its own
 * thread on a timer — precisely the shape that makes that race easy to lose. The clash API
 * answers with plain line-delimited JSON over loopback and has no such hazard.
 *
 * The endpoint emits one `{"up":N,"down":N}` object per second and never completes, so this
 * is a blocking read loop on a dedicated thread. Loopback traffic is not routed through the
 * tun, so no `protect()` is involved.
 */
class ClashTrafficReader(
    private val endpoint: ClashEndpoint,
    private val onSample: (up: Long, down: Long) -> Unit,
) {

    private val running = AtomicBoolean(false)

    @Volatile
    private var connection: HttpURLConnection? = null

    @Volatile
    private var thread: Thread? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return
        val worker = Thread({ loop() }, "aiko-traffic")
        worker.isDaemon = true
        thread = worker
        worker.start()
    }

    fun stop() {
        if (!running.compareAndSet(true, false)) return
        // Closing the socket from this thread is what unblocks the reader's blocking read;
        // interrupt() alone does nothing to a socket read.
        runCatching { connection?.disconnect() }
        connection = null
        thread?.interrupt()
        thread = null
    }

    private fun loop() {
        var backoffMs = 500L
        while (running.get()) {
            var open: HttpURLConnection? = null
            try {
                open = endpoint.open("/traffic", connectTimeoutMs = 2_000, readTimeoutMs = 0)
                connection = open
                if (open.responseCode != HttpURLConnection.HTTP_OK) {
                    throw IllegalStateException("HTTP ${open.responseCode}")
                }
                backoffMs = 500L
                open.inputStream.bufferedReader().use { reader ->
                    while (running.get()) {
                        val line = reader.readLine() ?: break
                        if (line.isBlank()) continue
                        val sample = runCatching { JSONObject(line) }.getOrNull() ?: continue
                        onSample(sample.optLong("up"), sample.optLong("down"))
                    }
                }
            } catch (e: Exception) {
                if (!running.get()) return
                Log.d(TAG, "traffic stream dropped, retrying in ${backoffMs}ms: ${e.message}")
            } finally {
                runCatching { open?.disconnect() }
                if (connection === open) connection = null
            }
            if (!running.get()) return
            try {
                Thread.sleep(backoffMs)
            } catch (e: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            }
            // A core that is up but not yet serving is normal for a second or two; a core
            // that never serves should not be hammered once per 500 ms forever.
            backoffMs = (backoffMs * 2).coerceAtMost(5_000L)
        }
    }

    private companion object {
        const val TAG = "AikoTrafficReader"
    }
}
