import path from 'path'
import v8 from 'v8'
import { readFile, writeFile } from 'fs/promises'
import { app, ipcMain } from 'electron'
import i18next from 'i18next'
import {
  mihomoChangeProxy,
  mihomoCloseAllConnections,
  mihomoCloseConnection,
  mihomoGroupDelay,
  mihomoGroups,
  mihomoProxies,
  mihomoProxyDelay,
  mihomoProxyProviders,
  mihomoRuleProviders,
  mihomoRules,
  mihomoUnfixedProxy,
  mihomoUpdateProxyProviders,
  mihomoUpdateRuleProviders,
  mihomoUpgrade,
  mihomoUpgradeGeo,
  mihomoUpgradeUI,
  mihomoHotReloadConfig,
  mihomoVersion,
  patchMihomoConfig,
  mihomoSmartGroupWeights,
  mihomoSmartFlushCache,
  mihomoRulesDisable
} from '../core/mihomoApi'
import { checkAutoRun, disableAutoRun, enableAutoRun } from '../sys/autoRun'
import {
  getAppConfig,
  patchAppConfig,
  getControledMihomoConfig,
  patchControledMihomoConfig,
  getProfileConfig,
  getCurrentProfileItem,
  getProfileItem,
  addProfileItem,
  removeProfileItem,
  changeCurrentProfile,
  getProfileStr,
  getFileStr,
  setFileStr,
  setProfileStr,
  updateProfileItem,
  setProfileConfig,
  getOverrideConfig,
  setOverrideConfig,
  getOverrideItem,
  addOverrideItem,
  removeOverrideItem,
  getOverride,
  setOverride,
  updateOverrideItem,
  convertMrsRuleset
} from '../config'
import {
  quitWithoutCore,
  restartCore,
  checkTunPermissions,
  grantTunPermissions,
  manualGrantCorePermition,
  checkAdminPrivileges,
  checkMihomoCorePermissions,
  requestTunPermissions,
  checkHighPrivilegeCore,
  showTunPermissionDialog,
  showErrorDialog,
  setTunEnabled,
  installCoreUpdate,
  rollbackCoreUpdate
} from '../core/manager'
import { triggerSysProxy } from '../sys/sysproxy'
import { checkUpdate, downloadAndInstallUpdate } from '../resolve/autoUpdater'
import {
  getFilePath,
  grantSelectedFileCapability,
  openFile,
  readImageFileDataURL,
  readTextFile,
  resetAppConfig,
  setNativeTheme,
  setupFirewall
} from '../sys/misc'
import { getRuntimeConfig, getRuntimeConfigStr } from '../core/factory'
import {
  listWebdavBackups,
  webdavBackup,
  webdavDelete,
  webdavRestore,
  exportLocalBackup,
  importLocalBackup,
  reinitScheduler
} from '../resolve/backup'
import { getInterfaces } from '../sys/interface'
import {
  closeTrayIcon,
  copyEnv,
  showTrayIcon,
  updateTrayIcon,
  updateTrayIconImmediate
} from '../resolve/tray'
import { registerShortcut } from '../resolve/shortcut'
import { closeMainWindow, mainWindow, showMainWindow, triggerMainWindow } from '../window'
import {
  applyTheme,
  fetchThemes,
  importThemes,
  readTheme,
  resolveThemes,
  writeTheme
} from '../resolve/theme'
import { exportGistAgeSecretKey, generateGistAgeKeyPair, getGistUrl } from '../resolve/gistApi'
import { closeFloatingWindow, showContextMenu, showFloatingWindow } from '../resolve/floatingWindow'
import { addProfileUpdater, removeProfileUpdater } from '../core/profileUpdater'
import {
  previewPlugin,
  installPlugin,
  loginPlugin,
  removePlugin,
  updatePluginProfile
} from '../resolve/plugin'
import { getPluginConfig } from '../config/plugin'
import { checkCoreUpdate } from '../core/singbox/coreUpdateService'
import { getImageDataURL } from './image'
import { get as httpGet } from './chromeRequest'
import { getIconDataURL } from './icon'
import { getAppName } from './appName'
import { logDir, rulePath } from './dirs'
import { assertTrustedIpcSender } from './electronSecurity'
import { type IpcErrorEnvelope, toIpcErrorEnvelope } from './ipcError'
import {
  DEFAULT_LATENCY_TARGETS,
  IP_INFO_ENDPOINTS,
  assertAllowedUrl,
  assertPublicHttpUrl
} from './rendererUrlGuard'

// eslint-disable-next-line @typescript-eslint/no-explicit-any
type AsyncFn = (...args: any[]) => Promise<any>
// eslint-disable-next-line @typescript-eslint/no-explicit-any
type SyncFn = (...args: any[]) => any
const rendererRoot = path.join(__dirname, '../renderer')

function wrapAsync<T extends AsyncFn>(
  fn: T
): (...args: Parameters<T>) => Promise<ReturnType<T> | IpcErrorEnvelope> {
  return async (...args) => {
    try {
      return await fn(...args)
    } catch (e) {
      return toIpcErrorEnvelope(e)
    }
  }
}

function registerHandlers(handlers: Record<string, AsyncFn | SyncFn>, async = true): void {
  for (const [channel, handler] of Object.entries(handlers)) {
    if (async) {
      ipcMain.handle(channel, (event, ...args) => {
        assertTrustedIpcSender(event, rendererRoot, undefined, !app.isPackaged)
        return wrapAsync(handler as AsyncFn)(...args)
      })
    } else {
      ipcMain.handle(channel, (event, ...args) => {
        assertTrustedIpcSender(event, rendererRoot, undefined, !app.isPackaged)
        return (handler as SyncFn)(...args)
      })
    }
  }
}

async function getRuleStr(id: string): Promise<string> {
  return await readFile(rulePath(id), 'utf-8')
}

async function setRuleStr(id: string, str: string): Promise<void> {
  await writeFile(rulePath(id), str, 'utf-8')
}

async function getSmartOverrideContent(): Promise<string | null> {
  try {
    const override = await getOverrideItem('smart-core-override')
    return override?.file || null
  } catch {
    return null
  }
}

async function fetchIPInfo(url: string): Promise<unknown> {
  const target = assertAllowedUrl(url, IP_INFO_ENDPOINTS)
  const res = await httpGet<unknown>(target, {
    timeout: 10000,
    responseType: 'json',
    maxBodyBytes: 1024 * 1024
  })
  return res.data
}

async function measureLatency(url: string): Promise<number | null> {
  const { networkLatencyTargets = [] } = await getAppConfig()
  // 校验放在 try 之外：不在允许列表里是攻击信号，不该被伪装成一次普通的探测失败
  const target = assertAllowedUrl(url, [
    ...DEFAULT_LATENCY_TARGETS,
    ...networkLatencyTargets.map((item) => item.url)
  ])
  try {
    const t0 = Date.now()
    await httpGet<unknown>(target, {
      timeout: 5000,
      responseType: 'text',
      maxBodyBytes: 256 * 1024
    })
    return Date.now() - t0
  } catch {
    return null
  }
}

// 图标 URL 来自订阅内容而不是固定列表，只能按“必须是公网 http(s)”来收敛
async function getGroupIconDataURL(url: string): Promise<string> {
  return await getImageDataURL(assertPublicHttpUrl(url))
}

async function changeLanguage(lng: string): Promise<void> {
  await i18next.changeLanguage(lng)
  ipcMain.emit('updateTrayMenu')
}

async function setTitleBarOverlay(overlay: Electron.TitleBarOverlayOptions): Promise<void> {
  if (mainWindow && typeof mainWindow.setTitleBarOverlay === 'function') {
    mainWindow.setTitleBarOverlay(overlay)
  }
}

const asyncHandlers: Record<string, AsyncFn> = {
  // Mihomo API
  mihomoVersion,
  mihomoCloseConnection,
  mihomoCloseAllConnections,
  mihomoRules,
  mihomoRulesDisable,
  mihomoProxies,
  mihomoGroups,
  mihomoProxyProviders,
  mihomoUpdateProxyProviders,
  mihomoRuleProviders,
  mihomoUpdateRuleProviders,
  mihomoChangeProxy,
  mihomoUnfixedProxy,
  mihomoUpgradeGeo,
  mihomoUpgrade,
  mihomoUpgradeUI,
  mihomoProxyDelay,
  mihomoGroupDelay,
  patchMihomoConfig,
  mihomoSmartGroupWeights,
  mihomoSmartFlushCache,
  // AutoRun
  checkAutoRun,
  enableAutoRun,
  disableAutoRun,
  // Config
  getAppConfig,
  patchAppConfig,
  getControledMihomoConfig,
  patchControledMihomoConfig,
  // Profile
  getProfileConfig,
  setProfileConfig,
  getCurrentProfileItem,
  getProfileItem,
  getProfileStr,
  setProfileStr,
  addProfileItem,
  removeProfileItem,
  updateProfileItem,
  changeCurrentProfile,
  addProfileUpdater,
  removeProfileUpdater,
  // Override
  getOverrideConfig,
  setOverrideConfig,
  getOverrideItem,
  addOverrideItem,
  removeOverrideItem,
  updateOverrideItem,
  getOverride,
  setOverride,
  // File
  getFileStr,
  setFileStr,
  convertMrsRuleset,
  getRuntimeConfig,
  getRuntimeConfigStr,
  getSmartOverrideContent,
  getRuleStr,
  setRuleStr,
  readTextFile,
  openFile,
  // Core
  restartCore,
  mihomoHotReloadConfig,
  quitWithoutCore,
  // System
  triggerSysProxy,
  setTunEnabled,
  checkTunPermissions,
  grantTunPermissions,
  manualGrantCorePermition,
  checkAdminPrivileges,
  restartAsAdmin: requestTunPermissions,
  checkMihomoCorePermissions,
  requestTunPermissions,
  checkHighPrivilegeCore,
  showTunPermissionDialog,
  showErrorDialog,
  setupFirewall,
  copyEnv,
  // Update
  checkUpdate,
  downloadAndInstallUpdate,
  checkCoreUpdate,
  installCoreUpdate,
  rollbackCoreUpdate,
  // Backup
  webdavBackup,
  webdavRestore,
  listWebdavBackups,
  webdavDelete,
  reinitWebdavBackupScheduler: reinitScheduler,
  exportLocalBackup,
  importLocalBackup,
  // Theme
  resolveThemes,
  fetchThemes,
  importThemes,
  readTheme,
  writeTheme,
  applyTheme,
  // Tray
  showTrayIcon,
  closeTrayIcon,
  updateTrayIcon,
  // Floating Window
  showFloatingWindow,
  closeFloatingWindow,
  showContextMenu,
  // Plugin
  getPluginConfig,
  previewPlugin,
  installPlugin,
  loginPlugin,
  removePlugin,
  updatePluginProfile,
  // Misc
  getGistUrl,
  generateGistAgeKeyPair,
  exportGistAgeSecretKey,
  fetchIPInfo,
  measureLatency,
  getImageDataURL: getGroupIconDataURL,
  readImageFileDataURL,
  getIconDataURL,
  getAppName,
  changeLanguage,
  setTitleBarOverlay,
  registerShortcut,
  resetAppConfig
}

const syncHandlers: Record<string, SyncFn> = {
  getFilePath,
  getInterfaces,
  setNativeTheme,
  getVersion: () => app.getVersion(),
  platform: () => process.platform,
  updateTrayIconImmediate,
  showMainWindow,
  closeMainWindow,
  triggerMainWindow,
  setAlwaysOnTop: (alwaysOnTop: boolean) => mainWindow?.setAlwaysOnTop(alwaysOnTop),
  isAlwaysOnTop: () => mainWindow?.isAlwaysOnTop(),
  openDevTools: () => {
    if (!app.isPackaged) mainWindow?.webContents.openDevTools()
  },
  createHeapSnapshot: () => v8.writeHeapSnapshot(path.join(logDir(), `${Date.now()}.heapsnapshot`)),
  relaunchApp: () => {
    app.relaunch()
    app.quit()
  },
  quitApp: () => app.quit()
}

export function registerIpcMainHandlers(): void {
  registerHandlers(asyncHandlers, true)
  registerHandlers(syncHandlers, false)
  ipcMain.removeAllListeners('grantSelectedFileCapability')
  ipcMain.on('grantSelectedFileCapability', (event, filePath: unknown) => {
    try {
      assertTrustedIpcSender(event, rendererRoot, undefined, !app.isPackaged)
      if (typeof filePath !== 'string' || !filePath) throw new Error('Invalid selected file path')
      grantSelectedFileCapability(filePath)
      event.returnValue = true
    } catch {
      event.returnValue = false
    }
  })
}
