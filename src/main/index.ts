import { execFileSync, execSync } from 'child_process'
import { electronApp, optimizer } from '@electron-toolkit/utils'
import { app, dialog } from 'electron'
import i18next from 'i18next'
import { initI18n } from '../shared/i18n'
import { registerIpcMainHandlers } from './utils/ipc'
import { getAppConfig, patchAppConfig, patchControledMihomoConfig } from './config'
import {
  startCore,
  checkAdminRestartForTun,
  checkHighPrivilegeCore,
  restartAsAdmin,
  initAdminStatus,
  checkAdminPrivileges,
  initCoreWatcher
} from './core/manager'
import { createTray } from './resolve/tray'
import { init, initBasic, safeShowErrorBox } from './utils/init'
import { initShortcut } from './resolve/shortcut'
import { initProfileUpdater } from './core/profileUpdater'
import { showFloatingWindow } from './resolve/floatingWindow'
import { logger, createLogger } from './utils/logger'
import { initWebdavBackupScheduler } from './resolve/backup'
import {
  createWindow,
  mainWindow,
  showMainWindow,
  triggerMainWindow,
  closeMainWindow
} from './window'
import { handleDeepLink } from './deeplink'
import {
  fixUserDataPermissions,
  setupPlatformSpecifics,
  setupAppLifecycle,
  getSystemLanguage
} from './lifecycle'
import { appConfigPath, configurePortableUserData } from './utils/dirs'
import { readDisableHardwareAccelerationSync } from './utils/hardwareAcceleration'
import {
  getStaleSystemProxyCoreEndpoint,
  recoverStaleSystemProxy,
  triggerSysProxy
} from './sys/sysproxy'
import { isCiIsolatedSmokeMode } from './utils/ciIsolatedSmoke'

const ciIsolatedSmoke = isCiIsolatedSmokeMode()

function getWindowsPowerShellMajorVersion(): number | null {
  if (ciIsolatedSmoke) return 5
  // 仅 PS 3.0+ 写入 \3\ 键（\1\ 键恒为 2.0，不可用）。
  try {
    const stdout = execFileSync(
      'reg',
      [
        'query',
        'HKLM\\SOFTWARE\\Microsoft\\PowerShell\\3\\PowerShellEngine',
        '/v',
        'PowerShellVersion'
      ],
      { encoding: 'utf8', timeout: 5000 }
    )
    const version = stdout.match(/PowerShellVersion\s+REG_\w+\s+([^\s]+)/)?.[1]
    const major = version ? parseInt(version.split('.')[0], 10) : NaN
    return isNaN(major) ? null : major
  } catch (error) {
    // 退出码 1 = 键不存在（Win7 仅 PS 2.0）；超时被杀或其他异常视为未知，不阻断。
    const err = error as { killed?: boolean; status?: number | null }
    return !err.killed && err.status === 1 ? 2 : null
  }
}

async function waitForPreviousAikoBoxInstance(): Promise<void> {
  const raw = process.argv
    .find((arg) => arg.startsWith('--wait-for-aikobox-pid='))
    ?.split('=', 2)[1]
  if (!raw) return

  const pid = Number(raw)
  if (!Number.isInteger(pid) || pid <= 0 || pid === process.pid) {
    throw new Error('Invalid AikoBox handoff PID')
  }

  const deadline = Date.now() + 30000
  while (Date.now() < deadline) {
    try {
      process.kill(pid, 0)
    } catch {
      return
    }
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  throw new Error(`Previous AikoBox process ${pid} did not exit during administrator handoff`)
}

// PowerShell 版本过低必须在 app 启动前提示并退出，因此保持同步执行
// Isolated CI smoke never shells out to reg/mshta.
if (process.platform === 'win32' && !ciIsolatedSmoke) {
  try {
    const major = getWindowsPowerShellMajorVersion()
    if (major !== null && major < 5) {
      const isZh = Intl.DateTimeFormat().resolvedOptions().locale?.startsWith('zh')
      const title = isZh ? '需要更新 PowerShell' : 'PowerShell Update Required'
      const message = isZh
        ? `检测到您的 PowerShell 版本为 ${major}.x，部分功能需要 PowerShell 5.1 才能正常运行。\\n\\n请访问 Microsoft 官网下载并安装 Windows Management Framework 5.1。`
        : `Detected PowerShell version ${major}.x. Some features require PowerShell 5.1.\\n\\nPlease install Windows Management Framework 5.1 from the Microsoft website.`
      execSync(
        `mshta "javascript:var sh=new ActiveXObject('WScript.Shell');sh.Popup('${message}',0,'${title}',48);close()"`,
        { timeout: 60000 }
      )
      process.exit(0)
    }
  } catch {
    // ignore
  }
}

configurePortableUserData()

// Must precede app.whenReady(); the userData path is only final after
// configurePortableUserData().
if (readDisableHardwareAccelerationSync(appConfigPath())) {
  app.disableHardwareAcceleration()
}

const mainLogger = createLogger('Main')

// AikoBox owns the WinINET journal and supervises the core. Dying on a stray
// rejection would strand the system proxy on a dead port, so log and continue.
// The handler must never be able to produce a rejection of its own:
// Logger.error is async and logToConsole runs outside writeToFile's own guard,
// so an unattached promise here would re-enter this handler forever.
process.on('unhandledRejection', (reason) => {
  mainLogger.error('Unhandled promise rejection', reason).catch(() => {
    try {
      console.error('[Main] Unhandled promise rejection', reason)
    } catch {
      // nothing left to report with
    }
  })
})

export { mainWindow, showMainWindow, triggerMainWindow, closeMainWindow }

const gotTheLock = app.requestSingleInstanceLock()
if (!gotTheLock) {
  app.quit()
}

async function initApp(): Promise<void> {
  await fixUserDataPermissions()
}

initApp().catch((e) => {
  safeShowErrorBox('common.error.initFailed', `${e}`)
  app.quit()
})

setupPlatformSpecifics()
setupAppLifecycle()

let proxySafetyReady = true
let staleProxyCoreEndpoint: { host: string; port: number } | null = null

app.on('second-instance', async (_event, commandline) => {
  showMainWindow()
  const url = commandline.pop()
  if (!url) return
  try {
    await handleDeepLink(url)
  } catch (e) {
    await mainLogger.warn('Failed to handle deep link', e)
  }
})

app.on('open-url', async (_event, url) => {
  showMainWindow()
  try {
    await handleDeepLink(url)
  } catch (e) {
    await mainLogger.warn('Failed to handle deep link', e)
  }
})

const initPromise = (async () => {
  try {
    await waitForPreviousAikoBoxInstance()
  } catch (error) {
    safeShowErrorBox('common.error.initFailed', `${error}`)
    app.quit()
    throw error
  }

  await initBasic()

  if (!ciIsolatedSmoke) {
    try {
      await recoverStaleSystemProxy()
    } catch (error) {
      proxySafetyReady = false
      staleProxyCoreEndpoint = getStaleSystemProxyCoreEndpoint()
      mainLogger.error(
        'System proxy recovery failed; automatic proxy activation is disabled',
        error
      )
      // Do not present this as a fatal "application init failed". Proxy recovery
      // is best-effort when another client (e.g. Bettbox) owns WinINET.
      mainLogger.warn(
        `System proxy recovery skipped: ${error instanceof Error ? error.message : String(error)}`
      )
    }
  } else {
    mainLogger.info('CI isolated smoke: skipping system proxy recovery')
  }

  const adminPromise: Promise<boolean> =
    process.platform === 'win32' && !ciIsolatedSmoke
      ? checkAdminPrivileges().catch(() => false)
      : Promise.resolve(true)

  const appConfigPromise = (async () => {
    try {
      const cfg = await getAppConfig()
      if (!cfg.language) {
        const systemLanguage = getSystemLanguage()
        await patchAppConfig({ language: systemLanguage })
        cfg.language = systemLanguage
      }
      await initI18n({ lng: cfg.language })
      return cfg
    } catch (e) {
      safeShowErrorBox('common.error.initFailed', `${e}`)
      app.quit()
      throw e
    }
  })()

  await adminPromise
  await initAdminStatus()

  if (process.platform === 'win32' && !ciIsolatedSmoke) {
    const isAdmin = await adminPromise
    if (!isAdmin) {
      try {
        const hasHighPrivilegeCore = await checkHighPrivilegeCore()
        if (hasHighPrivilegeCore) {
          try {
            await appConfigPromise
          } catch {
            await initI18n({ lng: 'zh-CN' })
          }
          const choice = dialog.showMessageBoxSync({
            type: 'warning',
            title: i18next.t('core.highPrivilege.title'),
            message: i18next.t('core.highPrivilege.message'),
            buttons: [i18next.t('common.confirm'), i18next.t('common.cancel')],
            defaultId: 0,
            cancelId: 1
          })

          if (choice === 0) {
            try {
              await restartAsAdmin(false)
              app.exit(0)
            } catch (error) {
              safeShowErrorBox('common.error.adminRequired', `${error}`)
              app.exit(1)
            }
          } else {
            app.exit(0)
          }
        }
      } catch (e) {
        mainLogger.error('Failed to check high privilege core', e)
      }
    }
  }

  return appConfigPromise
})()

app.whenReady().then(async () => {
  electronApp.setAppUserModelId('com.aikobox.app')

  const appConfig = await initPromise

  app.on('browser-window-created', (_, window) => {
    optimizer.watchWindowShortcuts(window)
  })

  registerIpcMainHandlers()

  const createWindowPromise = createWindow()
  const runtimeInitPromise = init().catch((error) => {
    mainLogger.error('Failed to initialize background services', error)
  })

  let coreStarted = false
  const coreStartPromise = (async (): Promise<void> => {
    if (ciIsolatedSmoke) {
      mainLogger.info('CI isolated smoke: refusing to start core, TUN, or system proxy')
      return
    }
    try {
      initCoreWatcher()
      // Resolve persisted/elevated TUN intent before any core process starts.
      // This prevents a guaranteed permission failure from racing config writes.
      await checkAdminRestartForTun()
      if (staleProxyCoreEndpoint) {
        // Raw WinINET CAS says we must not overwrite external changes, yet it
        // still depends on our old endpoint. Bind the recovered core to that
        // exact port before any generated candidate is allowed to start.
        await patchControledMihomoConfig({ 'mixed-port': staleProxyCoreEndpoint.port })
      }
      const startPromises = await startCore(
        false,
        false,
        false,
        staleProxyCoreEndpoint ?? undefined
      )
      if (startPromises.length > 0) {
        startPromises[0].then(async () => {
          await Promise.allSettled([
            initProfileUpdater().catch((e) => mainLogger.warn('Failed to init profile updater', e)),
            initWebdavBackupScheduler().catch((e) =>
              mainLogger.warn('Failed to init webdav backup scheduler', e)
            )
          ])
        })
      }
      coreStarted = true

      const { sysProxy } = await getAppConfig()
      if (!staleProxyCoreEndpoint && sysProxy.enable) {
        if (!proxySafetyReady)
          throw new Error('System proxy safety recovery failed; refusing to change WinINET')
        await triggerSysProxy(true)
      }
    } catch (e) {
      safeShowErrorBox('mihomo.error.coreStartFailed', `${e}`)
    }
  })()

  await createWindowPromise

  const { showFloatingWindow: showFloating = false, disableTray = false } = appConfig
  const uiTasks: Promise<void>[] = [initShortcut()]

  if (showFloating) {
    uiTasks.push(
      (async () => {
        try {
          await showFloatingWindow()
        } catch (error) {
          await logger.error('Failed to create floating window on startup', error)
        }
      })()
    )
  }

  if (!disableTray) {
    uiTasks.push(createTray())
  }

  await Promise.all(uiTasks)
  void runtimeInitPromise
  await coreStartPromise

  if (coreStarted) {
    mainWindow?.webContents.send('core-started')
  }

  app.on('activate', () => {
    showMainWindow()
  })
})
