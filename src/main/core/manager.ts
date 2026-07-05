import { ChildProcess, execFile, spawn } from 'child_process'
import { readFile, rm, writeFile } from 'fs/promises'
import { promisify } from 'util'
import path from 'path'
import os from 'os'
import { existsSync } from 'fs'
import { app, ipcMain } from 'electron'
import { mainWindow } from '../window'
import {
  getAppConfig,
  getControledMihomoConfig,
  patchControledMihomoConfig,
  manageSmartOverride
} from '../config'
import { dataDir, coreLogPath, mihomoProfileWorkDir, mihomoWorkDir } from '../utils/dirs'
import { uploadRuntimeConfigIfChanged } from '../resolve/gistApi'
import { startMonitor } from '../resolve/trafficMonitor'
import { ensureRuntimeFiles, safeShowErrorBox } from '../utils/init'
import i18next from '../../shared/i18n'
import { managerLogger } from '../utils/logger'
import { createCappedLogWritableStream } from '../utils/logFile'
import {
  startMihomoTraffic,
  startMihomoConnections,
  startMihomoLogs,
  startMihomoMemory,
  stopMihomoConnections,
  stopMihomoTraffic,
  stopMihomoLogs,
  stopMihomoMemory,
  getAxios
} from './mihomoApi'
import { generateProfile } from './factory'
import { singboxCorePath, singboxWorkConfigPath } from './singbox'
import {
  checkAdminRestartForTun as checkAdminRestartForTunWithRestart,
  setStopCoreBeforeAdminRestart
} from './permissions'
import { cleanupStrayCoreProcesses, waitForCoreReady } from './process'
import { setPublicDNS, recoverDNS } from './dns'

// 重新导出权限相关函数
export {
  initAdminStatus,
  getSessionAdminStatus,
  checkAdminPrivileges,
  checkMihomoCorePermissions,
  checkHighPrivilegeCore,
  grantTunPermissions,
  restartAsAdmin,
  requestTunPermissions,
  showTunPermissionDialog,
  showErrorDialog,
  checkTunPermissions,
  manualGrantCorePermition
} from './permissions'

export { getDefaultDevice } from './dns'

const execFilePromise = promisify(execFile)

// 核心进程状态
let child: ChildProcess | null = null
let retry = 10
let isRestarting = false
let cachedCoreVersion = ''

function hasCoreProcess(): boolean {
  return Boolean(child && !child.killed && child.exitCode === null && child.signalCode === null)
}

async function stopPidFileCore(): Promise<void> {
  const pidPath = path.join(dataDir(), 'core.pid')
  if (!existsSync(pidPath)) return

  const pidString = await readFile(pidPath, 'utf-8').catch(() => '')
  const pid = parseInt(pidString.trim())
  if (!isNaN(pid)) {
    try {
      process.kill(pid, 0)
      process.kill(pid, 'SIGINT')
      await new Promise((resolve) => setTimeout(resolve, 1000))
      try {
        process.kill(pid, 0)
        process.kill(pid, 'SIGKILL')
      } catch {
        // ignore
      }
    } catch {
      // ignore
    }
  }

  await rm(pidPath).catch(() => {})
}

// 初始化核心相关事件监听（sing-box 无自更新，无需文件监听）
export function initCoreWatcher(): void {
  // 监听 restartCore 事件（用于 DNS 状态恢复等场景，避免循环依赖）
  ipcMain.removeAllListeners('restartCore')
  ipcMain.on('restartCore', async () => {
    await restartCore()
    mainWindow?.webContents.send('appConfigUpdated')
  })
}

// 清理核心文件监听（保留导出以兼容退出流程）
export function cleanupCoreWatcher(): void {
  // no-op for sing-box
}

// 获取 sing-box 版本（命令行输出，用于 REST 不可用时的兜底显示）
export async function getCachedCoreVersion(): Promise<string> {
  if (cachedCoreVersion) return cachedCoreVersion
  try {
    const { stdout } = await execFilePromise(singboxCorePath(), ['version'], { timeout: 5000 })
    // 输出形如: "sing-box version 1.13.14\n..."
    const match = stdout.match(/sing-box version (\S+)/)
    cachedCoreVersion = match ? `sing-box ${match[1]}` : stdout.split('\n')[0].trim()
  } catch (error) {
    managerLogger.warn('Failed to read sing-box version from CLI', error)
  }
  return cachedCoreVersion
}

// 核心配置接口
interface CoreConfig {
  corePath: string
  workDir: string
  configPath: string
  tunEnabled: boolean
  autoSetDNS: boolean
  cpuPriority: string
  detached: boolean
}

// 准备核心配置
async function prepareCore(detached: boolean, skipStop = false): Promise<CoreConfig> {
  await ensureRuntimeFiles()

  const [appConfig, mihomoConfig] = await Promise.all([getAppConfig(), getControledMihomoConfig()])

  // 旧版本内核选择（mihomo / mihomo-alpha / mihomo-smart / mihomo-specific）
  // 一律映射到唯一内核 sing-box
  const {
    autoSetDNS = true,
    diffWorkDir = false,
    mihomoCpuPriority = 'PRIORITY_NORMAL'
  } = appConfig

  const { tun } = mihomoConfig

  // 清理轻量模式遗留的后台核心
  await stopPidFileCore()

  // 管理 Smart 内核覆写配置（sing-box 下始终移除）
  await manageSmartOverride()

  // generateProfile 返回实际使用的 current，并写出转换后的 sing-box 配置
  const current = await generateProfile()
  const workDir = diffWorkDir ? mihomoProfileWorkDir(current) : mihomoWorkDir()
  await checkProfile(workDir)
  if (!skipStop && hasCoreProcess()) {
    await stopCore()
  }
  await cleanupStrayCoreProcesses()

  // 设置 DNS
  if (tun?.enable && autoSetDNS) {
    try {
      await setPublicDNS()
    } catch (error) {
      managerLogger.error('set dns failed', error)
    }
  }

  return {
    corePath: singboxCorePath(),
    workDir,
    configPath: singboxWorkConfigPath(workDir),
    tunEnabled: tun?.enable ?? false,
    autoSetDNS,
    cpuPriority: mihomoCpuPriority,
    detached
  }
}

// 启动核心进程
function spawnCoreProcess(config: CoreConfig): ChildProcess {
  const { corePath, workDir, configPath, cpuPriority, detached } = config

  const args = ['run', '-D', workDir, '-c', configPath, '--disable-color']
  managerLogger.info(`Starting sing-box: ${corePath} ${args.join(' ')}`)

  const proc = spawn(corePath, args, {
    detached,
    stdio: detached ? 'ignore' : undefined
  })

  if (process.platform === 'win32' && proc.pid) {
    try {
      os.setPriority(
        proc.pid,
        os.constants.priority[cpuPriority as keyof typeof os.constants.priority]
      )
    } catch (error) {
      managerLogger.warn('Failed to set core process priority', error)
    }
  }

  if (!detached) {
    const stdout = createCappedLogWritableStream(coreLogPath)
    const stderr = createCappedLogWritableStream(coreLogPath)
    proc.stdout?.pipe(stdout)
    proc.stderr?.pipe(stderr)
  }

  return proc
}

// 设置核心进程事件监听
function setupCoreListeners(
  proc: ChildProcess,
  _config: CoreConfig,
  resolve: (value: Promise<void>[]) => void,
  reject: (reason: unknown) => void
): void {
  let settled = false
  let lastFatalLine = ''

  const settleResolve = (value: Promise<void>[]): void => {
    if (settled) return
    settled = true
    resolve(value)
  }
  const settleReject = (reason: unknown): void => {
    if (settled) return
    settled = true
    reject(reason)
  }

  const startMihomoApiStreams = async (): Promise<void> => {
    await waitForCoreReady()
    if (proc.exitCode !== null || proc.signalCode !== null) {
      throw new Error(lastFatalLine || 'core exited before API became ready')
    }
    await getAxios(true)
    await Promise.all([
      startMihomoTraffic(),
      startMihomoConnections(),
      startMihomoLogs(),
      startMihomoMemory()
    ])
    retry = 10
  }

  const completeCoreStartup = async (): Promise<void> => {
    try {
      mainWindow?.webContents.send('groupsUpdated')
      mainWindow?.webContents.send('rulesUpdated')
      await uploadRuntimeConfigIfChanged()
    } catch (error) {
      managerLogger.warn('Failed to sync runtime config to Gist', error)
    }
  }

  proc.on('close', async (code, signal) => {
    managerLogger.info(`Core closed, code: ${code}, signal: ${signal}`)

    if (child === proc) {
      child = null
    }

    settleReject(
      new Error(lastFatalLine || `core exited unexpectedly, code: ${code}, signal: ${signal}`)
    )

    if (isRestarting) {
      managerLogger.info('Core closed during restart, skipping auto-restart')
      return
    }

    if (retry) {
      managerLogger.info('Try Restart Core')
      retry--
      await restartCore()
    } else {
      await stopCore()
    }
  })

  // sing-box 将日志输出到 stderr，宽容地同时监听两个流
  const handleCoreOutput = async (data: Buffer | string): Promise<void> => {
    const str = data.toString()

    // 记录 FATAL/ERROR 行，供启动失败时展示
    for (const line of str.split('\n')) {
      if (/FATAL|ERROR/i.test(line) && line.trim()) {
        lastFatalLine = line.trim()
      }
    }

    // TUN 权限错误（sing-box: "configure tun interface: ... operation not permitted" 等）
    if (/operation not permitted/i.test(str) && /tun/i.test(str)) {
      patchControledMihomoConfig({ tun: { enable: false } })
      mainWindow?.webContents.send('controledMihomoConfigUpdated')
      ipcMain.emit('updateTrayMenu')
      settleReject(i18next.t('tun.error.tunPermissionDenied'))
      return
    }

    // 控制器/入站端口监听冲突
    if (/address already in use/i.test(str) || /Only one usage of each socket address/i.test(str)) {
      managerLogger.error('Listen error detected:', str)
      settleReject(i18next.t('mihomo.error.externalControllerListenError'))
    }
  }

  proc.stdout?.on('data', handleCoreOutput)
  proc.stderr?.on('data', handleCoreOutput)

  // 以 clash_api 可用作为就绪信号（sing-box 无 mihomo 式的就绪日志）
  void (async () => {
    try {
      await startMihomoApiStreams()
      settleResolve([
        completeCoreStartup().catch((error) => {
          managerLogger.warn('Failed to complete core startup', error)
        })
      ])
    } catch (error) {
      settleReject(error)
    }
  })()
}

// 启动核心
export async function startCore(detached = false, skipStop = false): Promise<Promise<void>[]> {
  const config = await prepareCore(detached, skipStop)
  const proc = spawnCoreProcess(config)
  child = proc

  if (detached) {
    managerLogger.info(
      `Core process detached successfully on ${process.platform}, PID: ${proc.pid}`
    )
    proc.unref()
    return [new Promise(() => {})]
  }

  return new Promise((resolve, reject) => {
    setupCoreListeners(proc, config, resolve, reject)
  })
}

// 停止核心
export async function stopCore(force = false): Promise<void> {
  if (!force && process.platform === 'darwin') {
    try {
      await recoverDNS()
    } catch (error) {
      managerLogger.error('recover dns failed', error)
    }
  }

  if (child) {
    child.removeAllListeners()
    child.kill('SIGINT')
    child = null
  }

  stopMihomoTraffic()
  stopMihomoConnections()
  stopMihomoLogs()
  stopMihomoMemory()

  try {
    await getAxios(true)
  } catch (error) {
    managerLogger.warn('Failed to refresh axios instance:', error)
  }

  await stopPidFileCore()
}

setStopCoreBeforeAdminRestart(stopCore)

// 重启核心
export async function restartCore(): Promise<void> {
  if (isRestarting) {
    managerLogger.info('Core restart already in progress, skipping duplicate request')
    return
  }

  isRestarting = true
  let retryCount = 0
  const maxRetries = 3

  try {
    // 先显式停止核心，确保状态干净
    await stopCore()

    // 尝试启动核心，失败时重试
    while (retryCount < maxRetries) {
      try {
        // skipStop=true 因为我们已经在上面停止了核心
        await startCore(false, true)
        return // 成功启动，退出函数
      } catch (e) {
        retryCount++
        managerLogger.error(`restart core failed (attempt ${retryCount}/${maxRetries})`, e)

        if (retryCount >= maxRetries) {
          throw e
        }

        // 重试前等待一段时间
        await new Promise((resolve) => setTimeout(resolve, 1000 * retryCount))
        // 确保清理干净再重试
        await stopCore()
      }
    }
  } finally {
    isRestarting = false
  }
}

// 保持核心运行
export async function keepCoreAlive(): Promise<void> {
  try {
    await startCore(true)
    if (child?.pid) {
      await writeFile(path.join(dataDir(), 'core.pid'), child.pid.toString())
    }
  } catch (e) {
    safeShowErrorBox('mihomo.error.coreStartFailed', `${e}`)
  }
}

// 退出但保持核心运行
export async function quitWithoutCore(): Promise<void> {
  managerLogger.info(`Starting lightweight mode on platform: ${process.platform}`)
  await keepCoreAlive()
  await startMonitor(true)
  managerLogger.info('Exiting main process, core will continue running in background')
  app.exit()
}

// 检查配置文件（sing-box check）
async function checkProfile(workDir: string): Promise<void> {
  const corePath = singboxCorePath()
  const configPath = singboxWorkConfigPath(workDir)

  try {
    await execFilePromise(corePath, ['check', '-D', workDir, '-c', configPath, '--disable-color'])
  } catch (error) {
    managerLogger.error('Profile check failed', error)

    if (error instanceof Error && ('stdout' in error || 'stderr' in error)) {
      const { stdout = '', stderr = '' } = error as { stdout?: string; stderr?: string }
      managerLogger.info('Profile check stdout', stdout)
      managerLogger.info('Profile check stderr', stderr)

      const output = `${stderr}\n${stdout}`
      const errorLines = output
        .split('\n')
        .map((line) => line.replace(/^\s*(FATAL|ERROR)\S*\s*/i, '').trim())
        .filter((line) => line.length > 0)

      throw new Error(
        `${i18next.t('mihomo.error.profileCheckFailed')}:\n${
          errorLines.length > 0 ? errorLines.join('\n') : String(error)
        }`
      )
    } else {
      throw new Error(`${i18next.t('mihomo.error.profileCheckFailed')}: ${error}`)
    }
  }
}

// 权限检查入口（从 permissions.ts 调用）
export async function checkAdminRestartForTun(): Promise<void> {
  await checkAdminRestartForTunWithRestart(restartCore)
}
