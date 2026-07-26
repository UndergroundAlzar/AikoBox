package com.aikobox.app.service

import android.content.Context
import android.util.Log
import io.nekohasekai.libbox.Libbox
import io.nekohasekai.libbox.SetupOptions
import java.io.File

/**
 * Idempotent `Libbox.setup()`, once per process.
 *
 * Android runs `onCreate` per process, and this app has two: the Flutter UI process, which
 * needs libbox only for `version()` and `checkConfig()`, and `:remote`, which runs the core
 * itself. Both must call `setup()` before touching anything else, and neither can see the
 * other's `AtomicBoolean` — hence "once per process" rather than "once".
 *
 * The paths deliberately match `mobile/lib/core/paths.dart`, so the Go side resolves
 * relative paths inside a config against the same directory the Dart side wrote that config
 * into. `getApplicationSupportDirectory()` in `path_provider` is `Context.getFilesDir()`, so
 * `<filesDir>/work` here is `AikoDirs.workDir` there.
 */
object LibboxSetup {

    private const val TAG = "AikoLibboxSetup"

    /** sing-box keeps this many log lines in its own ring buffer for the command server. */
    private const val LOG_MAX_LINES = 300L

    private var done = false
    private var appliedLocale: String? = null

    /**
     * Runs `Libbox.setup()` if this process has not done so yet.
     *
     * @param localeTag BCP-47 tag for the core's own diagnostics, or null to leave the
     *   locale alone. Passing a new tag after setup re-applies just the locale, which is
     *   cheap and is the only part of the setup that legitimately changes at runtime.
     * @throws Exception when libbox refuses to initialise; the caller must not proceed.
     */
    @Synchronized
    @Throws(Exception::class)
    fun ensure(context: Context, localeTag: String? = null) {
        if (!done) {
            val filesDir = context.filesDir
            val workDir = File(filesDir, AikoCoreContract.WORK_DIR)
            if (!workDir.isDirectory && !workDir.mkdirs() && !workDir.isDirectory) {
                throw IllegalStateException("android: cannot create ${workDir.absolutePath}")
            }
            val options = SetupOptions().apply {
                basePath = filesDir.absolutePath
                workingPath = workDir.absolutePath
                tempPath = context.cacheDir.absolutePath
                // Go's netpoller mis-detects the stack on some Android kernels; SFA sets
                // this unconditionally and so do we.
                fixAndroidStack = true
                // 0 => the command server listens on a unix socket under basePath rather
                // than on a TCP port. A TCP control port on a VPN app is an attack surface
                // we have no reason to open.
                commandServerListenPort = 0
                logMaxLines = LOG_MAX_LINES
                debug = false
            }
            Libbox.setup(options)
            done = true
            Log.i(TAG, "libbox ${Libbox.version()} initialised at ${filesDir.absolutePath}")
        }
        if (localeTag != null && localeTag != appliedLocale) {
            runCatching { Libbox.setLocale(localeTag) }
                .onFailure { Log.w(TAG, "setLocale($localeTag) failed", it) }
            appliedLocale = localeTag
        }
    }

    /** The active configuration on disk, i.e. whatever the Dart side last promoted. */
    fun activeConfigFile(context: Context): File =
        File(context.filesDir, AikoCoreContract.WORK_ACTIVE_CONFIG)
}
