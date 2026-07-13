import { mkdir, writeFile, rm, readdir, stat } from 'fs/promises'
import { existsSync } from 'fs'
import { exec } from 'child_process'
import { promisify } from 'util'
import path from 'path'
import { app, dialog } from 'electron'
import {
  getAppConfig,
  getControledMihomoConfig,
  getProfileConfig,
  patchAppConfig,
  patchControledMihomoConfig,
  setProfileConfig
} from '../config'
import { migrateLegacySubStoreProfiles } from '../config/legacySubStoreMigration'
import { startSSIDCheck } from '../sys/ssid'
import i18next, { resources } from '../../shared/i18n'
import {
  DEFAULT_MIHOMO_LAN_ALLOWED_IPS,
  DEFAULT_MIHOMO_SKIP_AUTH_PREFIXES,
  getDefaultMihomoTunDevice
} from '../../shared/appConfig'
import { stringify } from './yaml'
import {
  defaultConfig,
  defaultControledMihomoConfig,
  defaultOverrideConfig,
  defaultProfile,
  defaultProfileConfig
} from './template'
import {
  appConfigPath,
  controledMihomoConfigPath,
  dataDir,
  logDir,
  mihomoTestDir,
  mihomoWorkDir,
  overrideConfigPath,
  overrideDir,
  profileConfigPath,
  profilePath,
  profilesDir,
  rulesDir,
  themesDir
} from './dirs'
import { initLogger } from './logger'

let isInitBasicCompleted = false
let isRuntimeFilesCompleted = false
let initBasicPromise: Promise<void> | null = null
let runtimeFilesPromise: Promise<void> | null = null

export function safeShowErrorBox(titleKey: string, message: string): void {
  let title: string
  try {
    title = i18next.t(titleKey)
    if (!title || title === titleKey) throw new Error('Translation not ready')
  } catch {
    const isZh = app.getLocale().startsWith('zh')
    const lang = isZh ? resources['zh-CN'].translation : resources['en-US'].translation
    title = lang[titleKey] || (isZh ? '错误' : 'Error')
  }
  dialog.showErrorBox(title, message)
}

async function fixDataDirPermissions(): Promise<void> {
  if (process.platform !== 'darwin') return

  const dataDirPath = dataDir()
  if (!existsSync(dataDirPath)) return

  try {
    const stats = await stat(dataDirPath)
    const currentUid = process.getuid?.() || 0

    if (stats.uid === 0 && currentUid !== 0) {
      const execPromise = promisify(exec)
      const username = process.env.USER || process.env.LOGNAME
      if (username) {
        await execPromise(`chown -R "${username}:staff" "${dataDirPath}"`)
        await execPromise(`chmod -R u+rwX "${dataDirPath}"`)
      }
    }
  } catch {
    // ignore
  }
}

async function initDirs(): Promise<void> {
  await fixDataDirPermissions()

  const dirsToCreate = [
    dataDir(),
    themesDir(),
    profilesDir(),
    overrideDir(),
    rulesDir(),
    mihomoWorkDir(),
    logDir(),
    mihomoTestDir()
  ]

  await Promise.all(
    dirsToCreate.map(async (dir) => {
      if (!existsSync(dir)) {
        await mkdir(dir, { recursive: true })
      }
    })
  )
}

async function initConfig(): Promise<void> {
  const configs = [
    { path: appConfigPath(), content: defaultConfig, name: 'app config' },
    { path: profileConfigPath(), content: defaultProfileConfig, name: 'profile config' },
    { path: overrideConfigPath(), content: defaultOverrideConfig, name: 'override config' },
    { path: profilePath('default'), content: defaultProfile, name: 'default profile' },
    {
      path: controledMihomoConfigPath(),
      content: defaultControledMihomoConfig,
      name: 'mihomo config'
    }
  ]

  await Promise.all(
    configs.map(async (config) => {
      if (!existsSync(config.path)) {
        await writeFile(config.path, stringify(config.content))
      }
    })
  )
}

async function cleanup(): Promise<void> {
  const [dataFiles, logFiles] = await Promise.all([readdir(dataDir()), readdir(logDir())])

  // 清理更新缓存
  const cacheExtensions = ['.exe', '.pkg', '.7z']
  const cacheCleanup = dataFiles
    .filter((file) => cacheExtensions.some((ext) => file.endsWith(ext)))
    .map((file) => rm(path.join(dataDir(), file)).catch(() => {}))

  // 清理过期日志
  const { maxLogDays = 7 } = await getAppConfig()
  const maxAge = maxLogDays * 24 * 60 * 60 * 1000
  const datePattern = /\d{4}-\d{2}-\d{2}/

  const logCleanup = logFiles
    .filter((log) => {
      const match = log.match(datePattern)
      if (!match) return false
      const date = new Date(match[0])
      return !isNaN(date.getTime()) && Date.now() - date.getTime() > maxAge
    })
    .map((log) => rm(path.join(logDir(), log)).catch(() => {}))

  await Promise.all([...cacheCleanup, ...logCleanup])
}

async function cleanupRetiredSubStoreRuntimeFiles(): Promise<void> {
  await Promise.all(
    ['sub-store.bundle.js', 'sub-store.bundle.cjs', 'sub-store-frontend'].map((name) =>
      rm(path.join(mihomoWorkDir(), name), { recursive: true, force: true }).catch((error) =>
        initLogger.warn(`Failed to remove retired runtime file ${name}`, error)
      )
    )
  )
}

async function migrateRetiredSubStoreProfiles(): Promise<void> {
  const current = await getProfileConfig(true)
  const migrated = migrateLegacySubStoreProfiles(current)
  if (migrated.changed) await setProfileConfig(migrated.config)
}

async function migrateRetiredSiderOrder(): Promise<void> {
  const { siderOrder = [], lastSelectedSiderCard } = await getAppConfig()
  const nextOrder = siderOrder.filter((item) => item !== 'substore')
  const persistedLastSelected = lastSelectedSiderCard as string | undefined
  if (nextOrder.length !== siderOrder.length || persistedLastSelected === 'substore') {
    await patchAppConfig({
      siderOrder: nextOrder,
      lastSelectedSiderCard: persistedLastSelected === 'substore' ? 'proxy' : lastSelectedSiderCard
    })
  }
}

// 迁移：修复 appTheme
async function migrateAppTheme(): Promise<void> {
  const { appTheme = 'system' } = await getAppConfig()
  if (!['system', 'light', 'dark'].includes(appTheme)) {
    await patchAppConfig({ appTheme: 'system' })
  }
}

// 迁移：envType 字符串转数组
async function migrateEnvType(): Promise<void> {
  const { envType } = await getAppConfig()
  if (typeof envType === 'string') {
    await patchAppConfig({ envType: [envType] })
  }
}

// 迁移：禁用托盘时必须显示悬浮窗
async function migrateTraySettings(): Promise<void> {
  const { showFloatingWindow = false, disableTray = false } = await getAppConfig()
  if (!showFloatingWindow && disableTray) {
    await patchAppConfig({ disableTray: false })
  }
}

// 迁移：移除加密密码
async function migrateRemovePassword(): Promise<void> {
  const { encryptedPassword } = await getAppConfig()
  if (encryptedPassword) {
    await patchAppConfig({ encryptedPassword: undefined })
  }
}

// 迁移：mihomo 配置默认值
async function migrateMihomoConfig(): Promise<void> {
  const config = await getControledMihomoConfig()
  const patches: Partial<IMihomoConfig> = {}

  // skip-auth-prefixes
  if (!config['skip-auth-prefixes']) {
    patches['skip-auth-prefixes'] = [...DEFAULT_MIHOMO_SKIP_AUTH_PREFIXES]
  } else if (
    config['skip-auth-prefixes'].length >= 1 &&
    config['skip-auth-prefixes'][0] === DEFAULT_MIHOMO_SKIP_AUTH_PREFIXES[0] &&
    !config['skip-auth-prefixes'].includes(DEFAULT_MIHOMO_SKIP_AUTH_PREFIXES[1])
  ) {
    patches['skip-auth-prefixes'] = [
      ...DEFAULT_MIHOMO_SKIP_AUTH_PREFIXES,
      ...config['skip-auth-prefixes'].slice(1)
    ]
  }

  // 其他默认值
  if (!config.authentication) patches.authentication = []
  if (!config['bind-address']) patches['bind-address'] = '*'
  if (!config['lan-allowed-ips']) patches['lan-allowed-ips'] = [...DEFAULT_MIHOMO_LAN_ALLOWED_IPS]
  if (!config['lan-disallowed-ips']) patches['lan-disallowed-ips'] = []

  // tun device
  if (!config.tun?.device || (process.platform === 'darwin' && config.tun.device === 'Mihomo')) {
    patches.tun = {
      ...config.tun,
      device: getDefaultMihomoTunDevice(process.platform)
    }
  }

  // 移除废弃配置
  if (config['external-controller-unix']) patches['external-controller-unix'] = undefined
  if (config['external-controller-pipe']) patches['external-controller-pipe'] = undefined
  if (config['external-controller'] === undefined) patches['external-controller'] = ''

  if (Object.keys(patches).length > 0) {
    await patchControledMihomoConfig(patches)
  }
}

async function migration(): Promise<void> {
  await Promise.all([
    migrateRetiredSiderOrder(),
    migrateAppTheme(),
    migrateEnvType(),
    migrateTraySettings(),
    migrateRemovePassword(),
    migrateMihomoConfig()
  ])
}

function initDeeplink(): void {
  // 开发模式不注册 URL scheme：会把系统的 clash:// / mihomo:// 关联改写为
  // 指向 electron.exe 的临时命令，破坏本机已安装客户端的一键导入。
  if (!app.isPackaged) return
  app.setAsDefaultProtocolClient('clash')
  app.setAsDefaultProtocolClient('mihomo')
  app.setAsDefaultProtocolClient('aikobox')
}

export async function initBasic(): Promise<void> {
  if (isInitBasicCompleted) return
  if (initBasicPromise) return initBasicPromise

  initBasicPromise = (async () => {
    await initDirs()
    await initConfig()
    await migrateRetiredSubStoreProfiles()
    await cleanupRetiredSubStoreRuntimeFiles()
    await migration()

    isInitBasicCompleted = true
  })()

  try {
    await initBasicPromise
  } finally {
    initBasicPromise = null
  }
}

export async function ensureRuntimeFiles(): Promise<void> {
  if (isRuntimeFilesCompleted) return
  if (runtimeFilesPromise) return runtimeFilesPromise

  runtimeFilesPromise = (async () => {
    await initBasic()
    await cleanup()
    isRuntimeFilesCompleted = true
  })()

  try {
    await runtimeFilesPromise
  } finally {
    runtimeFilesPromise = null
  }
}

export async function init(): Promise<void> {
  // System proxy activation is intentionally not part of background init.
  // The main process applies it only after sing-box passes its API health check.
  await Promise.all([ensureRuntimeFiles(), startSSIDCheck()])
  initDeeplink()
}
