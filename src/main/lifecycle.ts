import { spawn, exec, execFileSync } from 'child_process'
import { promisify } from 'util'
import { stat } from 'fs/promises'
import { existsSync } from 'fs'
import { app, dialog, powerMonitor, type WindowSessionEndEvent } from 'electron'
import { stopCore, cleanupCoreWatcher } from './core/manager'
import { primeAdminPrivilegesCache } from './core/admin'
import {
  beginExactEndpointGuardianShutdown,
  cancelExactEndpointGuardianShutdown
} from './core/exactEndpointGuardian'
import {
  beginSystemProxyShutdown,
  cancelSystemProxyShutdown,
  disableSysProxySync,
  triggerSysProxy
} from './sys/sysproxy'
import { isCiIsolatedSmokeMode } from './utils/ciIsolatedSmoke'
import { exePath } from './utils/dirs'

interface ExitCleanupAttempt {
  /** Whether the synchronous emergency restore proved WinINET safe. */
  proxyRestoredSynchronously: boolean
  completion: Promise<boolean>
}

let startExitCleanup: (() => ExitCleanupAttempt) | null = null
let saveWindowStateBeforeExit: () => void = () => {}
let finishBlockedWindowsSessionEnd: ((attempt: ExitCleanupAttempt) => void) | null = null
let exitApprovedForWindowClose = false

export function isExitApprovedForWindowClose(): boolean {
  return exitApprovedForWindowClose
}

/**
 * Avoid a lifecycle -> window -> lifecycle import cycle while still keeping
 * all proxy/core shutdown authority in this module.
 */
export function setLifecycleWindowStateSaver(saver: () => void): void {
  saveWindowStateBeforeExit = saver
}

export function handleWindowsQuerySessionEnd(event: WindowSessionEndEvent): void {
  if (process.platform !== 'win32' || !startExitCleanup) return

  const attempt = startExitCleanup()
  if (!attempt.proxyRestoredSynchronously) {
    // Returning from WM_QUERYENDSESSION while WinINET still targets AikoBox
    // lets Windows terminate the core and strand the user's network.
    event.preventDefault()
    finishBlockedWindowsSessionEnd?.(attempt)
  }
}

export function handleWindowsSessionEnd(): void {
  if (process.platform !== 'win32' || !startExitCleanup) return
  // session-end cannot be cancelled. Starting the same transaction still
  // performs the synchronous emergency restore before this handler returns.
  startExitCleanup()
}

export function customRelaunch(): void {
  const script = `while kill -0 ${process.pid} 2>/dev/null; do
  sleep 0.1
done
${process.argv.join(' ')} & disown
exit
`
  spawn('sh', ['-c', script], {
    detached: true,
    stdio: 'ignore'
  })
}

export async function fixUserDataPermissions(): Promise<void> {
  if (process.platform !== 'darwin') return

  const userDataPath = app.getPath('userData')
  if (!existsSync(userDataPath)) return

  try {
    const stats = await stat(userDataPath)
    const currentUid = process.getuid?.() || 0

    if (stats.uid === 0 && currentUid !== 0) {
      const execPromise = promisify(exec)
      const username = process.env.USER || process.env.LOGNAME
      if (username) {
        await execPromise(`chown -R "${username}:staff" "${userDataPath}"`)
        await execPromise(`chmod -R u+rwX "${userDataPath}"`)
      }
    }
  } catch {
    // ignore
  }
}

export function setupPlatformSpecifics(): void {
  if (process.platform === 'linux') {
    app.relaunch = customRelaunch
  }

  // https://github.com/electron/electron/issues/43278
  // https://github.com/electron/electron/issues/36698
  const electronMajor = parseInt(process.versions.electron.split('.')[0], 10) || 0
  if (process.platform === 'win32' && !exePath().startsWith('C') && electronMajor < 38) {
    app.commandLine.appendSwitch('in-process-gpu')
  }

  // Isolated CI smoke must not shell out to fltmc (elevation probe).
  if (process.platform === 'win32' && !isCiIsolatedSmokeMode()) {
    const elevated = isWindowsElevatedSync()
    if (elevated) {
      primeAdminPrivilegesCache(true)
      app.commandLine.appendSwitch('disable-gpu-sandbox')
    }
  }
}

function isWindowsElevatedSync(): boolean {
  if (process.platform !== 'win32') return false
  try {
    execFileSync('fltmc', [], { stdio: 'ignore', windowsHide: true, timeout: 800 })
    return true
  } catch {
    return false
  }
}

export function setupAppLifecycle(): void {
  let sysProxyDisabled = false
  exitApprovedForWindowClose = false
  let activeCleanup: ExitCleanupAttempt | null = null
  let blockedSessionContinuation: ExitCleanupAttempt | null = null
  let beforeQuitContinuationPending = false

  const withTimeout = async (promise: Promise<void>, timeout: number): Promise<boolean> => {
    let timeoutId: NodeJS.Timeout | null = null

    try {
      return await Promise.race([
        promise.then(() => true).catch(() => false),
        new Promise<boolean>((resolve) => {
          timeoutId = setTimeout(() => resolve(false), timeout)
        })
      ])
    } finally {
      if (timeoutId) clearTimeout(timeoutId)
    }
  }

  startExitCleanup = (): ExitCleanupAttempt => {
    if (activeCleanup) return activeCleanup

    saveWindowStateBeforeExit() // 硬退出补一次落盘
    beginSystemProxyShutdown()
    // Must be set before stopCore() below: an endpoint guardian or a stored
    // recovery attempt that spawns after the kill leaves a sing-box.exe holding
    // the TUN adapter with no owner left to stop it.
    beginExactEndpointGuardianShutdown()

    // Isolated CI smoke never enables system proxy; skip WinINET restore entirely.
    const isolatedSmoke = isCiIsolatedSmokeMode()

    // This call is deliberately before the first Promise/await. Windows
    // session-end may give us no asynchronous grace period at all.
    const proxyRestoredSynchronously =
      isolatedSmoke || (process.platform !== 'darwin' && disableSysProxySync())
    sysProxyDisabled = proxyRestoredSynchronously

    const attempt = {} as ExitCleanupAttempt
    attempt.proxyRestoredSynchronously = proxyRestoredSynchronously
    attempt.completion = (async (): Promise<boolean> => {
      // Always enqueue a serialized disable behind any already-running enable.
      // A successful synchronous restore alone cannot close that queue race.
      // Isolated smoke skips triggerSysProxy (assertIsolatedSmokeAllows would throw).
      const asyncRestoreSucceeded = isolatedSmoke
        ? true
        : await withTimeout(triggerSysProxy(false), 1200)
      sysProxyDisabled = sysProxyDisabled || asyncRestoreSucceeded

      // Never stop the core/watchdog while WinINET may still point at it.
      if (!sysProxyDisabled) return false

      cleanupCoreWatcher()
      const coreStopped = await withTimeout(stopCore(), 1200)
      return coreStopped
    })().finally(() => {
      if (activeCleanup === attempt && !sysProxyDisabled) {
        activeCleanup = null
        cancelSystemProxyShutdown()
        // The quit was abandoned (the app stays open to protect WinINET), so
        // endpoint recovery has to be allowed to run again.
        cancelExactEndpointGuardianShutdown()
      }
    })
    activeCleanup = attempt
    return attempt
  }

  finishBlockedWindowsSessionEnd = (attempt): void => {
    if (blockedSessionContinuation === attempt) return
    blockedSessionContinuation = attempt
    void attempt.completion.then((safeToExit) => {
      if (blockedSessionContinuation === attempt) blockedSessionContinuation = null
      if (!safeToExit) return
      exitApprovedForWindowClose = true
      app.quit()
    })
  }

  app.on('window-all-closed', () => {
    // Keep the app and tray alive when lightweight tray mode destroys the renderer window.
  })

  app.on('before-quit', async (e) => {
    if (exitApprovedForWindowClose) return
    e.preventDefault()
    if (beforeQuitContinuationPending) return
    if (!startExitCleanup) return
    beforeQuitContinuationPending = true
    const safeToExit = await startExitCleanup().completion
    if (safeToExit) {
      exitApprovedForWindowClose = true
      app.quit()
      return
    }
    beforeQuitContinuationPending = false

    // Keep the guardian alive rather than leaving WinINET pointing to a core
    // that is about to disappear. The ownership journal remains for retry.
    dialog.showErrorBox(
      'AikoBox could not restore the system proxy',
      'AikoBox is staying open to protect your network connection. Check the system proxy settings, then try exiting again.'
    )
  })

  powerMonitor.on('shutdown', async () => {
    // Keep one shutdown authority. Do not force-exit while WinINET may still
    // reference our core; the OS can terminate us later if shutdown proceeds.
    if (!startExitCleanup) return
    const safeToExit = await startExitCleanup().completion
    if (safeToExit) {
      exitApprovedForWindowClose = true
      app.exit()
    }
  })

  app.on('will-quit', () => {
    // Isolated CI smoke never touches WinINET; skip emergency restore.
    if (!sysProxyDisabled && !isCiIsolatedSmokeMode()) {
      sysProxyDisabled = disableSysProxySync()
    }
  })
}

export function getSystemLanguage(): 'zh-CN' | 'en-US' {
  const locale = app.getLocale()
  return locale.startsWith('zh') ? 'zh-CN' : 'en-US'
}
