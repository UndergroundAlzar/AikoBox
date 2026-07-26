package com.aikobox.app.service

import android.content.Context
import io.nekohasekai.libbox.Libbox

/**
 * The parts of libbox that are safe to call from the UI process.
 *
 * Nothing here starts, stops or touches a tunnel — that all lives in `:remote`. What is left
 * is the read-only surface the Flutter side needs synchronously: the core's version for the
 * dashboard's "core info" card, and configuration validation.
 *
 * Validation runs here on purpose. It is the **N2** gate — the Android equivalent of the
 * desktop's `sing-box check -c candidate.json` — and N2 is only worth anything if it runs
 * *before* the running core is disturbed. Answering from the UI process means a rejected
 * candidate never reaches the service at all, so a bad profile cannot cost a working tunnel
 * even for the moment it takes to say no.
 */
object LibboxProbe {

    /** sing-box version string baked into libbox at build time, e.g. "1.13.14". */
    fun coreVersion(): String = Libbox.version()

    /**
     * Validates a generated sing-box configuration without starting anything.
     *
     * @return null when the configuration is valid, otherwise the core's own error message.
     */
    fun checkConfig(context: Context, configJson: String): String? = try {
        // checkConfig resolves relative paths (rule-sets, cache files) against the paths
        // Setup declared, so an un-set-up process would reject configurations the service
        // would happily accept.
        LibboxSetup.ensure(context)
        Libbox.checkConfig(configJson)
        null
    } catch (e: Exception) {
        e.message ?: "invalid configuration"
    }

    /**
     * Reformats a configuration the way the core would write it.
     *
     * Not on the channel contract; kept because it is the cheapest way to make a
     * conversion bug legible in a bug report.
     */
    fun formatConfig(context: Context, configJson: String): String? = try {
        LibboxSetup.ensure(context)
        Libbox.formatConfig(configJson)?.value
    } catch (e: Exception) {
        null
    }
}
