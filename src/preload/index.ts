import { contextBridge, ipcRenderer, webUtils } from 'electron'

// 允许的 invoke channels 白名单
const validInvokeChannels = [
  // Mihomo API
  'mihomoVersion',
  'mihomoCloseConnection',
  'mihomoCloseAllConnections',
  'mihomoRules',
  'mihomoRulesDisable',
  'mihomoProxies',
  'mihomoGroups',
  'mihomoProxyProviders',
  'mihomoUpdateProxyProviders',
  'mihomoRuleProviders',
  'mihomoUpdateRuleProviders',
  'mihomoChangeProxy',
  'mihomoUnfixedProxy',
  'mihomoUpgradeGeo',
  'mihomoUpgrade',
  'mihomoUpgradeUI',
  'mihomoProxyDelay',
  'mihomoGroupDelay',
  'patchMihomoConfig',
  'mihomoSmartGroupWeights',
  'mihomoSmartFlushCache',
  // AutoRun
  'checkAutoRun',
  'enableAutoRun',
  'disableAutoRun',
  // Config
  'getAppConfig',
  'patchAppConfig',
  'getControledMihomoConfig',
  'patchControledMihomoConfig',
  'resetAppConfig',
  // Profile
  'getProfileConfig',
  'setProfileConfig',
  'getCurrentProfileItem',
  'getProfileItem',
  'getProfileStr',
  'setProfileStr',
  'addProfileItem',
  'removeProfileItem',
  'updateProfileItem',
  'changeCurrentProfile',
  'addProfileUpdater',
  'removeProfileUpdater',
  // Override
  'getOverrideConfig',
  'setOverrideConfig',
  'getOverrideItem',
  'addOverrideItem',
  'removeOverrideItem',
  'updateOverrideItem',
  'getOverride',
  'setOverride',
  // File
  'getFileStr',
  'setFileStr',
  'convertMrsRuleset',
  'getRuntimeConfig',
  'getRuntimeConfigStr',
  'getSmartOverrideContent',
  'getRuleStr',
  'setRuleStr',
  'getFilePath',
  'readTextFile',
  'readImageFileDataURL',
  'openFile',
  // Core
  'restartCore',
  'mihomoHotReloadConfig',
  'startMonitor',
  'quitWithoutCore',
  // System
  'triggerSysProxy',
  'setTunEnabled',
  'checkTunPermissions',
  'grantTunPermissions',
  'manualGrantCorePermition',
  'checkAdminPrivileges',
  'restartAsAdmin',
  'checkMihomoCorePermissions',
  'requestTunPermissions',
  'checkHighPrivilegeCore',
  'showTunPermissionDialog',
  'showErrorDialog',
  'openUWPTool',
  'setupFirewall',
  'getInterfaces',
  'setNativeTheme',
  'copyEnv',
  // Update
  'checkUpdate',
  'downloadAndInstallUpdate',
  'checkCoreUpdate',
  'installCoreUpdate',
  'rollbackCoreUpdate',
  'getVersion',
  'platform',
  // Backup
  'webdavBackup',
  'webdavRestore',
  'listWebdavBackups',
  'webdavDelete',
  'reinitWebdavBackupScheduler',
  'exportLocalBackup',
  'importLocalBackup',
  // SubStore
  'startSubStoreFrontendServer',
  'stopSubStoreFrontendServer',
  'startSubStoreBackendServer',
  'stopSubStoreBackendServer',
  'subStorePort',
  'subStoreFrontendPort',
  'subStoreBackendPrefix',
  'subStoreSubs',
  'subStoreCollections',
  // Theme
  'resolveThemes',
  'fetchThemes',
  'importThemes',
  'readTheme',
  'writeTheme',
  'applyTheme',
  // Tray
  'showTrayIcon',
  'closeTrayIcon',
  'updateTrayIcon',
  'updateTrayIconImmediate',
  // Window
  'showMainWindow',
  'closeMainWindow',
  'triggerMainWindow',
  'showFloatingWindow',
  'closeFloatingWindow',
  'showContextMenu',
  'setTitleBarOverlay',
  'setAlwaysOnTop',
  'isAlwaysOnTop',
  'openDevTools',
  'createHeapSnapshot',
  'relaunchApp',
  'quitApp',
  // Shortcut
  'registerShortcut',
  // Plugin
  'getPluginConfig',
  'previewPlugin',
  'installPlugin',
  'loginPlugin',
  'removePlugin',
  'updatePluginProfile',
  // Misc
  'getGistUrl',
  'generateGistAgeKeyPair',
  'exportGistAgeSecretKey',
  'fetchIPInfo',
  'measureLatency',
  'getImageDataURL',
  'getIconDataURL',
  'getAppName',
  'changeLanguage'
] as const

// 允许的 on/removeListener channels 白名单
const validListenChannels = [
  'mihomoLogs',
  'mihomoConnections',
  'mihomoTraffic',
  'mihomoMemory',
  'appConfigUpdated',
  'controledMihomoConfigUpdated',
  'profileConfigUpdated',
  'groupsUpdated',
  'rulesUpdated',
  'updateDownloadProgress',
  'pluginConfigUpdated'
] as const

// 允许的 send channels 白名单
const validSendChannels = ['updateTrayMenu', 'updateFloatingWindow', 'trayIconUpdate'] as const

type InvokeChannel = (typeof validInvokeChannels)[number]
type ListenChannel = (typeof validListenChannels)[number]
type SendChannel = (typeof validSendChannels)[number]

type IpcListener = (event: Electron.IpcRendererEvent, ...args: unknown[]) => void
type RegisteredIpcListener = (event: Electron.IpcRendererEvent, ...args: unknown[]) => void
const listenerMap = new Map<ListenChannel, Map<IpcListener, RegisteredIpcListener>>()
// Preserve the historical callback signature without exposing the real event.sender
// (which is ipcRenderer and would bypass the channel whitelist).
const safeRendererEvent = Object.freeze({}) as Electron.IpcRendererEvent

// 安全的 IPC API，只暴露白名单内的 channels
const electronAPI = {
  ipcRenderer: {
    invoke: (channel: InvokeChannel, ...args: unknown[]): Promise<unknown> => {
      if (validInvokeChannels.includes(channel)) {
        return ipcRenderer.invoke(channel, ...args)
      }
      return Promise.reject(new Error(`Invalid invoke channel: ${channel}`))
    },
    send: (channel: SendChannel, ...args: unknown[]): void => {
      if (validSendChannels.includes(channel)) {
        ipcRenderer.send(channel, ...args)
      }
    },
    on: (channel: ListenChannel, listener: IpcListener): void => {
      if (validListenChannels.includes(channel)) {
        let listeners = listenerMap.get(channel)
        if (!listeners) {
          listeners = new Map()
          listenerMap.set(channel, listeners)
        }
        if (listeners.has(listener)) return

        const registeredListener: RegisteredIpcListener = (_event, ...args) => {
          listener(safeRendererEvent, ...args)
        }
        listeners.set(listener, registeredListener)
        ipcRenderer.on(channel, registeredListener)
      }
    },
    removeListener: (channel: ListenChannel, listener: IpcListener): void => {
      if (validListenChannels.includes(channel)) {
        const listeners = listenerMap.get(channel)
        const registeredListener = listeners?.get(listener)
        if (!registeredListener) return
        ipcRenderer.removeListener(channel, registeredListener)
        listeners?.delete(listener)
        if (listeners?.size === 0) listenerMap.delete(channel)
      }
    },
    removeAllListeners: (channel: ListenChannel): void => {
      if (validListenChannels.includes(channel)) {
        const listeners = listenerMap.get(channel)
        if (listeners) {
          listeners.forEach((registeredListener) => {
            ipcRenderer.removeListener(channel, registeredListener)
          })
          listeners.clear()
          listenerMap.delete(channel)
        }
      }
    }
  },
  process: {
    platform: process.platform
  }
}

const api = {
  webUtils: {
    getPathForFile: (file: File): string => {
      const filePath = webUtils.getPathForFile(file)
      const granted = ipcRenderer.sendSync('grantSelectedFileCapability', filePath)
      if (granted !== true) throw new Error('The main process rejected the selected file')
      return filePath
    }
  }
}

if (process.contextIsolated) {
  try {
    contextBridge.exposeInMainWorld('electron', electronAPI)
    contextBridge.exposeInMainWorld('api', api)
  } catch (error) {
    console.error(error)
  }
} else {
  // @ts-ignore (define in dts)
  window.electron = electronAPI
  // @ts-ignore (define in dts)
  window.api = api
}
