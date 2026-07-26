package com.aikobox.app.service

import android.content.Context
import android.content.SharedPreferences

/**
 * Time-windowed circuit breaker for unexpected core exits.
 *
 * A direct port of `src/main/core/restartPolicy.ts`, including the detail that makes it
 * useful: **a successful start does not reset the history.** A core that comes up, serves
 * for forty seconds and dies is still in a crash loop, and forgiving it on every start turns
 * the breaker into an infinite retry.
 *
 * Android forces one change on the desktop design. On the desktop the core is a child
 * process and the supervisor outlives it, so the history can live in memory. Here the core
 * *is* the process: a Go panic takes `:remote` down with it and `START_STICKY` brings back a
 * brand new one with no memory of anything. The history is therefore persisted, in
 * `:remote`'s own private preferences — a file the UI process never touches, so no
 * cross-process `SharedPreferences` coherency question arises.
 */
class CrashRestartPolicy(
    private val preferences: SharedPreferences,
    private val windowMs: Long = DEFAULT_WINDOW_MS,
    private val maxRestarts: Int = DEFAULT_MAX_RESTARTS,
    private val baseDelayMs: Long = DEFAULT_BASE_DELAY_MS,
    private val maxDelayMs: Long = DEFAULT_MAX_DELAY_MS,
) {

    init {
        require(windowMs > 0 && maxRestarts >= 0 && baseDelayMs >= 0 && maxDelayMs >= baseDelayMs) {
            "Invalid crash restart policy options"
        }
    }

    /**
     * @param allowed false once the breaker has tripped; the caller must give up and say so.
     * @param crashCount crashes inside the window, including this one.
     * @param delayMs how long to wait before trying again.
     */
    data class Decision(val allowed: Boolean, val crashCount: Int, val delayMs: Long)

    /** Records an unexpected exit and says whether another attempt is warranted. */
    @Synchronized
    fun recordCrash(now: Long = System.currentTimeMillis()): Decision {
        val cutoff = now - windowMs
        // `timestamp <= now` also discards entries from the future, which a clock change
        // between boots can produce and which would otherwise pin the breaker open.
        val history = read().filter { it > cutoff && it <= now } + now
        write(history)

        val crashCount = history.size
        if (crashCount > maxRestarts) {
            return Decision(allowed = false, crashCount = crashCount, delayMs = 0)
        }
        var delay = baseDelayMs
        repeat(crashCount - 1) { delay *= 2 }
        return Decision(allowed = true, crashCount = crashCount, delayMs = delay.coerceAtMost(maxDelayMs))
    }

    /** Called after a clean, user-initiated stop: there is nothing to hold against the core. */
    @Synchronized
    fun reset() {
        preferences.edit().remove(KEY_HISTORY).apply()
    }

    private fun read(): List<Long> = preferences.getString(KEY_HISTORY, "")
        .orEmpty()
        .split(',')
        .mapNotNull { it.trim().toLongOrNull() }

    private fun write(history: List<Long>) {
        preferences.edit()
            .putString(KEY_HISTORY, history.takeLast(MAX_HISTORY).joinToString(","))
            .apply()
    }

    companion object {
        const val DEFAULT_WINDOW_MS = 2L * 60L * 1000L
        const val DEFAULT_MAX_RESTARTS = 5
        const val DEFAULT_BASE_DELAY_MS = 1_000L
        const val DEFAULT_MAX_DELAY_MS = 30L * 1000L

        private const val KEY_HISTORY = "crash.history"
        private const val MAX_HISTORY = 32

        /** Private to the `:remote` process; nothing else reads or writes it. */
        const val PREFERENCES_NAME = "aikobox.remote"

        fun open(context: Context): CrashRestartPolicy =
            CrashRestartPolicy(context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE))
    }
}
