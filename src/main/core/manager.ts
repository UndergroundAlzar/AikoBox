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
  getProfileConfig,
  patchControledMihomoConfig,
  manageSmartOverride
} from '../config'
import { dataDir, coreLogPath, mihomoProfileWorkDir, mihomoWorkDir } from '../utils/dirs'
import { uploadRuntimeConfigIfChanged } from '../resolve/gistApi'
import { ensureRuntimeFiles, safeShowErrorBox } from '../utils/init'
import i18next from '../../shared/i18n'
import { managerLogger } from '../utils/logger'
import { createCappedLogWritableStream } from '../utils/logFile'
import { writeFileAtomically } from '../config/remoteResource'
import { parse, stringify } from '../utils/yaml'
import {
  getStaleSystemProxyCoreEndpoint,
  resumeStaleSystemProxyDependency,
  setSystemProxyCoreEndpoint,
  setSystemProxyCoreReady,
  triggerSysProxy
} from '../sys/sysproxy'
import {
  captureWindowsProcessIdentity,
  inspectWindowsProcess,
  matchesProcessIdentity,
  parseProcessIdentityRecord
} from '../utils/processIdentity'
import { assertIsolatedSmokeAllows } from '../utils/ciIsolatedSmoke'
import { mapCoreListenError } from './listenError'
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
import {
  discardPendingRuntimeConfig,
  generateProfile,
  getPendingRuntimeConfig,
  promotePendingRuntimeConfig,
  restoreRuntimeConfig
} from './factory'
import {
  setActiveControllerFromSingboxConfig,
  deriveProxyPortFromSingboxConfig,
  runtimeLastGoodProfilePath,
  runtimeProfilePath,
  singboxCandidateConfigPath,
  singboxCorePath,
  singboxLastGoodConfigPath,
  singboxRecoveryConfigPath,
  singboxWorkConfigPath
} from './singbox'
import type { SingboxRecoverySlot } from './singbox/configPaths'
import {
  markActiveConfigGood,
  promoteCandidateConfig,
  restoreLastGoodConfig
} from './singbox/configStore'
import {
  checkAdminRestartForTun as checkAdminRestartForTunWithRestart,
  setStopCoreBeforeAdminRestart
} from './permissions'
import { waitForCoreReady, waitForTcpPort } from './process'
import { setPublicDNS, recoverDNS } from './dns'
import { CrashRestartPolicy } from './restartPolicy'
import { preflightWindowsTunCandidate } from './tunPreflight'
import { SerialTaskQueue } from './serialTaskQueue'
import {
  applyStagedCoreUpdate,
  commitCoreUpdateSelectionChange,
  resolveSingboxCorePathForExecution,
  rollbackCoreUpdateSelection,
  stageCoreUpdate,
  undoCoreUpdateSelectionChange
} from './singbox/coreUpdateService'
import type { CoreUpdateResult } from './singbox/coreUpdater'
import { runCoreUpdateTransaction } from './coreUpdateTransaction'
import { ExactEndpointGuardian, isExactEndpointGuardianShutdown } from './exactEndpointGuardian'
import { getHealthyProxyEndpoint } from './healthyProxyEndpoint'
import { recoverFromStoredCandidates } from './storedRecoveryPool'
import {
  assertPinnedRequiredProxyEndpoint,
  assertRequiredProxyEndpoint,
  pinRequiredProxyEndpoint,
  type RequiredProxyEndpoint
} from './singbox/requiredProxyEndpoint'

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
let activeCore: { process: ChildProcess; config: CoreConfig } | null = null
let isRestarting = false
const restartQueue = new SerialTaskQueue()
let cachedCoreVersion = ''
const crashRestartPolicy = new CrashRestartPolicy()
const LKG_STABILITY_WINDOW_MS = 60_000
const lkgCommitTimers = new Map<ChildProcess, NodeJS.Timeout>()
const exactEndpointGuardian = new ExactEndpointGuardian()

export class CoreCandidateRejectedError extends Error {
  readonly cause: unknown

  constructor(cause: unknown) {
    super('The candidate configuration was rejected; last-known-good is running')
    this.name = 'CoreCandidateRejectedError'
    this.cause = cause
  }
}

function hasCoreProcess(): boolean {
  return Boolean(child && !child.killed && child.exitCode === null && child.signalCode === null)
}

export class CoreShutdownInProgressError extends Error {
  constructor() {
    super('AikoBox is shutting down; refusing to start another sing-box process')
    this.name = 'CoreShutdownInProgressError'
  }
}

function assertCoreSpawnAllowedDuringShutdown(): void {
  if (isExactEndpointGuardianShutdown()) throw new CoreShutdownInProgressError()
}

function cancelStableLkgCommit(proc: ChildProcess): void {
  const timer = lkgCommitTimers.get(proc)
  if (timer) clearTimeout(timer)
  lkgCommitTimers.delete(proc)
}

function scheduleStableLkgCommit(proc: ChildProcess, workDir: string): void {
  cancelStableLkgCommit(proc)
  const timer = setTimeout(() => {
    lkgCommitTimers.delete(proc)
    if (child !== proc || proc.killed || proc.exitCode !== null || proc.signalCode !== null) {
      return
    }
    void markActiveConfigGood(workDir).catch((error) => {
      managerLogger.warn('Failed to persist stable last-known-good sing-box config', error)
    })
  }, LKG_STABILITY_WINDOW_MS)
  timer.unref()
  lkgCommitTimers.set(proc, timer)
}

async function stopPidFileCore(): Promise<void> {
  const pidPath = path.join(dataDir(), 'core.pid')
  if (!existsSync(pidPath)) return

  const record = parseProcessIdentityRecord(await readFile(pidPath, 'utf-8').catch(() => ''))
  if (record) {
    const expectedCorePath = await resolveSingboxCorePathForExecution()
    const actual = process.platform === 'win32' ? await inspectWindowsProcess(record.pid) : null
    const owned = actual ? matchesProcessIdentity(record, actual, expectedCorePath) : false
    if (owned) {
      try {
        process.kill(record.pid, 'SIGINT')
        await new Promise((resolve) => setTimeout(resolve, 1000))
        const stillRunning = await inspectWindowsProcess(record.pid)
        if (stillRunning && matchesProcessIdentity(record, stillRunning, expectedCorePath)) {
          process.kill(record.pid, 'SIGKILL')
        }
      } catch {
        // The owned process may already have exited.
      }
    } else {
      managerLogger.warn(
        `Ignored stale core.pid because PID ${record.pid} is not AikoBox's sing-box`
      )
    }
  }

  await rm(pidPath).catch(() => {})
}

async function persistCoreIdentity(proc: ChildProcess, corePath: string): Promise<void> {
  if (process.platform !== 'win32' || !proc.pid) return
  const identity = await captureWindowsProcessIdentity(proc.pid, corePath)
  if (!identity) {
    managerLogger.warn(`Could not capture process identity for sing-box PID ${proc.pid}`)
    return
  }
  await writeFile(path.join(dataDir(), 'core.pid'), JSON.stringify(identity))
}

async function removeCoreIdentity(pid: number | undefined): Promise<void> {
  if (!pid) return
  const pidPath = path.join(dataDir(), 'core.pid')
  const record = parseProcessIdentityRecord(await readFile(pidPath, 'utf-8').catch(() => ''))
  if (record?.pid === pid) {
    await rm(pidPath, { force: true }).catch(() => {})
  }
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
    const corePath = await resolveSingboxCorePathForExecution()
    const { stdout } = await execFilePromise(corePath, ['version'], { timeout: 5000 })
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
  proxyHost: string
  mixedPort: number
}

async function enforceRequiredProxyEndpoint(
  config: CoreConfig,
  requiredEndpoint?: RequiredProxyEndpoint,
  recoverySlot: SingboxRecoverySlot = 'active',
  runtimeProfileOverride?: string,
  sourceConfigOverride?: Record<string, unknown>,
  publishActive = true
): Promise<CoreConfig> {
  if (!requiredEndpoint) return config
  const endpoint = assertRequiredProxyEndpoint(requiredEndpoint)
  const current =
    sourceConfigOverride ??
    (JSON.parse(await readFile(config.configPath, 'utf8')) as Record<string, unknown>)
  const pinned = pinRequiredProxyEndpoint(current, endpoint)
  const serialized = `${JSON.stringify(pinned, null, 2)}\n`
  const snapshotPath = singboxRecoveryConfigPath(config.workDir, recoverySlot, endpoint.port)

  // Validate an immutable slot-specific snapshot first. Candidate and LKG
  // recovery must never share the mutable active path used by config rollback.
  await writeFileAtomically(snapshotPath, serialized)
  await checkProfile(config.workDir, snapshotPath, config.corePath)
  if (publishActive) {
    await writeFileAtomically(singboxWorkConfigPath(config.workDir), serialized)
  }

  const runtimePath = runtimeProfilePath(config.workDir)
  const runtimeSource =
    runtimeProfileOverride ?? (existsSync(runtimePath) ? await readFile(runtimePath, 'utf8') : null)
  if (runtimeSource !== null) {
    const runtime = parse(runtimeSource) as Record<string, unknown>
    runtime['mixed-port'] = endpoint.port
    const runtimeText = stringify(runtime)
    if (publishActive) await writeFileAtomically(runtimePath, runtimeText)
    restoreRuntimeConfig(runtimeText)
  }
  if (publishActive) setActiveControllerFromSingboxConfig(pinned)
  return {
    ...config,
    configPath: snapshotPath,
    proxyHost: endpoint.host,
    mixedPort: endpoint.port
  }
}

interface PreparedColdStartConfig {
  config: CoreConfig
  recoverySlot: SingboxRecoverySlot
  runtimeProfile?: string
  sourceConfig?: Record<string, unknown>
}

async function prepareColdStartLastGood(
  detached: boolean
): Promise<PreparedColdStartConfig | null> {
  const [appConfig, profileConfig] = await Promise.all([getAppConfig(), getProfileConfig(true)])
  const workDir = appConfig.diffWorkDir
    ? mihomoProfileWorkDir(profileConfig.current)
    : mihomoWorkDir()
  const restored = await restoreLastGoodConfig(workDir, { retainActiveAsRejected: false })
  if (!restored) return null

  restoreRuntimeConfig(restored.runtimeProfile)
  setActiveControllerFromSingboxConfig(restored.config)
  const corePath = await resolveSingboxCorePathForExecution()
  await checkProfile(workDir, singboxWorkConfigPath(workDir), corePath)
  const inbounds = Array.isArray(restored.config.inbounds) ? restored.config.inbounds : []
  const tunEnabled = inbounds.some(
    (value) =>
      value && typeof value === 'object' && (value as Record<string, unknown>).type === 'tun'
  )

  return {
    recoverySlot: 'last-good',
    runtimeProfile: restored.runtimeProfile,
    config: {
      corePath,
      workDir,
      configPath: singboxWorkConfigPath(workDir),
      tunEnabled,
      autoSetDNS: appConfig.autoSetDNS ?? true,
      cpuPriority: appConfig.mihomoCpuPriority ?? 'PRIORITY_NORMAL',
      detached,
      proxyHost: '127.0.0.1',
      mixedPort: deriveProxyPortFromSingboxConfig(restored.config) ?? 7890
    }
  }
}

async function prepareRequiredRecoveryCandidates(
  detached: boolean
): Promise<PreparedColdStartConfig[]> {
  const [appConfig, profileConfig] = await Promise.all([getAppConfig(), getProfileConfig(true)])
  const workDir = appConfig.diffWorkDir
    ? mihomoProfileWorkDir(profileConfig.current)
    : mihomoWorkDir()
  const corePath = await resolveSingboxCorePathForExecution()
  const candidates: PreparedColdStartConfig[] = []
  const sources: Array<{
    configPath: string
    runtimePath: string
    recoverySlot: SingboxRecoverySlot
  }> = [
    {
      configPath: singboxLastGoodConfigPath(workDir),
      runtimePath: runtimeLastGoodProfilePath(workDir),
      recoverySlot: 'last-good'
    },
    {
      configPath: singboxWorkConfigPath(workDir),
      runtimePath: runtimeProfilePath(workDir),
      recoverySlot: 'active'
    }
  ]

  for (const source of sources) {
    if (!existsSync(source.configPath)) continue
    const stored = JSON.parse(await readFile(source.configPath, 'utf8')) as Record<string, unknown>
    const inbounds = Array.isArray(stored.inbounds) ? stored.inbounds : []
    candidates.push({
      recoverySlot: source.recoverySlot,
      sourceConfig: stored,
      runtimeProfile: existsSync(source.runtimePath)
        ? await readFile(source.runtimePath, 'utf8')
        : undefined,
      config: {
        corePath,
        workDir,
        configPath: source.configPath,
        tunEnabled: inbounds.some(
          (value) =>
            value && typeof value === 'object' && (value as Record<string, unknown>).type === 'tun'
        ),
        autoSetDNS: appConfig.autoSetDNS ?? true,
        cpuPriority: appConfig.mihomoCpuPriority ?? 'PRIORITY_NORMAL',
        detached,
        proxyHost: '127.0.0.1',
        mixedPort: deriveProxyPortFromSingboxConfig(stored) ?? 7890
      }
    })
  }
  return candidates
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
  const mixedPort = mihomoConfig['mixed-port'] ?? 7890

  // 管理 Smart 内核覆写配置（sing-box 下始终移除）
  await manageSmartOverride()

  // generateProfile 返回实际使用的 current，并写出转换后的 sing-box 配置
  const current = await generateProfile()
  const workDir = diffWorkDir ? mihomoProfileWorkDir(current) : mihomoWorkDir()
  const candidatePath = singboxCandidateConfigPath(workDir)
  if (tun?.enable) {
    const runtimeConfig = getPendingRuntimeConfig()
    const tunDecision = await preflightWindowsTunCandidate({
      candidatePath,
      activeConfigPath: singboxWorkConfigPath(workDir),
      runtimeTun: runtimeConfig?.tun,
      hasRunningCore: hasCoreProcess()
    })
    for (const change of tunDecision.changes) {
      managerLogger.warn(
        `TUN address ${change.from} conflicted with a Windows route; selected ${change.to}`
      )
    }
  }
  const corePath = await resolveSingboxCorePathForExecution()
  await checkProfile(workDir, candidatePath, corePath)
  const candidateConfig = JSON.parse(await readFile(candidatePath, 'utf8')) as Record<
    string,
    unknown
  >

  // Publish both candidate files before touching the healthy old process. A
  // disk failure therefore cannot create an avoidable connectivity outage.
  await promoteCandidateConfig(workDir)

  // Do not touch a running/legacy core until the replacement is converted and
  // validated. An invalid subscription therefore leaves current traffic intact.
  if (!skipStop && hasCoreProcess()) {
    await triggerSysProxy(false)
    await stopCore()
  } else {
    await stopPidFileCore()
  }
  setActiveControllerFromSingboxConfig(candidateConfig)

  // 设置 DNS
  if (tun?.enable && autoSetDNS) {
    try {
      await setPublicDNS()
    } catch (error) {
      managerLogger.error('set dns failed', error)
    }
  }

  return {
    corePath,
    workDir,
    configPath: singboxWorkConfigPath(workDir),
    tunEnabled: tun?.enable ?? false,
    autoSetDNS,
    cpuPriority: mihomoCpuPriority,
    detached,
    proxyHost: '127.0.0.1',
    mixedPort
  }
}

// 启动核心进程
function spawnCoreProcess(config: CoreConfig): ChildProcess {
  // The single choke point every core spawn goes through. Guardian recovery,
  // the stored-candidate pool and the normal start path all land here, so this
  // is the only place that can guarantee a quit is never raced by a fresh
  // sing-box.exe that would outlive the app holding the TUN adapter.
  assertCoreSpawnAllowedDuringShutdown()

  const { corePath, workDir, configPath, cpuPriority, detached } = config

  const args = ['run', '-D', workDir, '-c', configPath, '--disable-color']
  managerLogger.info(`Starting sing-box: ${corePath} ${args.join(' ')}`)

  setSystemProxyCoreReady(false)
  const proc = spawn(corePath, args, {
    detached,
    stdio: detached ? 'ignore' : undefined
  })
  activeCore = { process: proc, config }

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

/**
 * If WinINET cannot be restored after an unexpected core exit, stopping is not
 * a safe option: Windows may still point at this exact loopback endpoint. Keep
 * retrying the already-validated runtime configuration with a bounded delay
 * until its listener reports the endpoint healthy again. This path never
 * regenerates or promotes a candidate configuration.
 */
async function startExactEndpointConfigOnce(config: CoreConfig): Promise<CoreConfig> {
  const healthy = getHealthyProxyEndpoint()
  if (hasCoreProcess() && healthy?.host === config.proxyHost && healthy.port === config.mixedPort) {
    if (activeCore?.process === child) return activeCore.config
    throw new Error('The exact endpoint is healthy but its running configuration is unknown')
  }
  if (hasCoreProcess()) {
    managerLogger.warn(
      'Stopping the current AikoBox-owned core because it has not proven the required WinINET endpoint'
    )
    await stopCore()
    await new Promise((resolve) => setTimeout(resolve, 250))
  }

  const corePath = await resolveSingboxCorePathForExecution()
  const executionConfig = { ...config, corePath }
  const snapshotText = await readFile(executionConfig.configPath, 'utf8')
  const snapshot = JSON.parse(snapshotText) as Record<string, unknown>
  assertPinnedRequiredProxyEndpoint(snapshot, {
    host: executionConfig.proxyHost,
    port: executionConfig.mixedPort
  })
  await checkProfile(executionConfig.workDir, executionConfig.configPath, corePath)
  if ((await readFile(executionConfig.configPath, 'utf8')) !== snapshotText) {
    throw new Error('Recovery snapshot changed during validation')
  }
  // Controller secrets are generated per converted snapshot. Restore the
  // exact snapshot controller inside the serialized guardian attempt so A/B
  // failover never polls another candidate's API.
  setActiveControllerFromSingboxConfig(snapshot)
  const guardianProc = spawnCoreProcess(executionConfig)
  child = guardianProc
  await new Promise<Promise<void>[]>((resolve, reject) => {
    setupCoreListeners(guardianProc, executionConfig, resolve, reject)
  })
  const ready = getHealthyProxyEndpoint()
  if (
    !hasCoreProcess() ||
    ready?.host !== executionConfig.proxyHost ||
    ready.port !== executionConfig.mixedPort
  ) {
    throw new Error('The core started without proving the required proxy endpoint')
  }
  return executionConfig
}

async function restartProxyGuardian(config: CoreConfig): Promise<void> {
  return exactEndpointGuardian.ensure({
    endpoint: { host: config.proxyHost, port: config.mixedPort },
    isHealthy: () => {
      const healthy = getHealthyProxyEndpoint()
      return Boolean(
        hasCoreProcess() &&
        healthy &&
        healthy.host === config.proxyHost &&
        healthy.port === config.mixedPort
      )
    },
    attempt: async () => void (await startExactEndpointConfigOnce(config)),
    onAttemptError: (error, attempt) => {
      managerLogger.error(
        `Proxy guardian restart failed (attempt ${attempt}); WinINET restoration is still pending`,
        error
      )
    }
  })
}

async function publishRequiredRecoveryConfig(
  config: CoreConfig,
  endpoint: RequiredProxyEndpoint,
  runtimeProfile?: string
): Promise<void> {
  const serialized = await readFile(config.configPath, 'utf8')
  await writeFileAtomically(singboxWorkConfigPath(config.workDir), serialized)
  const parsed = JSON.parse(serialized) as Record<string, unknown>
  setActiveControllerFromSingboxConfig(parsed)

  if (runtimeProfile !== undefined) {
    const runtime = parse(runtimeProfile) as Record<string, unknown>
    runtime['mixed-port'] = endpoint.port
    const runtimeText = stringify(runtime)
    await writeFileAtomically(runtimeProfilePath(config.workDir), runtimeText)
    restoreRuntimeConfig(runtimeText)
  }
}

async function resumeRequiredSystemProxyDependency(
  config: CoreConfig,
  requiredEndpoint?: RequiredProxyEndpoint,
  alternateConfigs: CoreConfig[] = []
): Promise<void> {
  if (!requiredEndpoint) return
  const endpoint = assertRequiredProxyEndpoint(requiredEndpoint)

  while (!isExactEndpointGuardianShutdown()) {
    const [primary, ...alternates] = [config, ...alternateConfigs].map((candidate) =>
      restartProxyGuardian(candidate)
    )
    // Only the primary guardian is awaited; the alternates exist to join an
    // already-running recovery for the same endpoint. One for a different
    // endpoint rejects immediately, and an unattached rejection here would
    // surface as a process-wide unhandledRejection.
    for (const alternate of alternates) {
      alternate.catch((error) => {
        managerLogger.warn('Alternate exact-endpoint guardian did not join recovery', error)
      })
    }
    await primary
    const stale = getStaleSystemProxyCoreEndpoint()
    if (!stale) return
    if (stale.host !== endpoint.host || stale.port !== endpoint.port) {
      throw new Error('The stale WinINET dependency changed during exact-endpoint recovery')
    }
    try {
      await resumeStaleSystemProxyDependency()
      return
    } catch (error) {
      managerLogger.error(
        'The exact proxy endpoint changed before stale WinINET ownership could resume; retrying',
        error
      )
      await new Promise((resolve) => setTimeout(resolve, 1_000))
    }
  }
}

async function waitForRequiredRecoveryConfig(
  detached: boolean,
  endpoint: RequiredProxyEndpoint,
  cause: unknown
): Promise<void> {
  discardPendingRuntimeConfig()
  safeShowErrorBox(
    'mihomo.error.coreStartFailed',
    `Windows still depends on the previous AikoBox proxy endpoint. AikoBox will keep retrying a validated local recovery configuration on that exact endpoint.\n\n${String(cause)}`
  )

  let attempt = 0
  // Quitting wins. `recoverFromStoredCandidates` reaches `spawnCoreProcess`
  // without going through the guardian, so this loop needs its own exit or the
  // shutdown refusal below would just be retried after the backoff.
  while (!isExactEndpointGuardianShutdown()) {
    attempt += 1
    try {
      const candidates = await prepareRequiredRecoveryCandidates(detached)
      if (candidates.length === 0) {
        throw new Error('No active or last-known-good recovery config is available')
      }
      await recoverFromStoredCandidates(candidates, {
        prepare: (prepared) =>
          enforceRequiredProxyEndpoint(
            prepared.config,
            endpoint,
            prepared.recoverySlot,
            prepared.runtimeProfile,
            prepared.sourceConfig,
            false
          ),
        startOnce: startExactEndpointConfigOnce,
        publish: (runningConfig, prepared) =>
          publishRequiredRecoveryConfig(runningConfig, endpoint, prepared.runtimeProfile),
        resume: (runningConfig) => resumeRequiredSystemProxyDependency(runningConfig, endpoint),
        onCandidateError: async (prepared, error) => {
          managerLogger.error(
            `Stored ${prepared.recoverySlot} recovery config could not restore the exact endpoint`,
            error
          )
          await new Promise((resolve) => setTimeout(resolve, 250))
        },
        onPublishError: (_prepared, publishError) => {
          managerLogger.error(
            'The exact endpoint is healthy, but its active recovery mirror could not be persisted',
            publishError
          )
        }
      })
      return
    } catch (error) {
      // recoverFromStoredCandidates wraps per-candidate failures in an
      // AggregateError, so ask the flag rather than inspecting the cause.
      if (isExactEndpointGuardianShutdown()) break
      managerLogger.error(
        `Exact-endpoint recovery configuration attempt ${attempt} failed; WinINET recovery remains active`,
        error
      )
      const delayMs = Math.min(30_000, 1_000 * 2 ** Math.min(attempt - 1, 5))
      await new Promise((resolve) => setTimeout(resolve, delayMs))
    }
  }
  managerLogger.info('Exact-endpoint recovery stopped because AikoBox is shutting down')
}

// 设置核心进程事件监听
function setupCoreListeners(
  proc: ChildProcess,
  config: CoreConfig,
  resolve: (value: Promise<void>[]) => void,
  reject: (reason: unknown) => void
): void {
  let settled = false
  let startupFailed = false
  let startupReady = false
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
  const failStartup = (reason: unknown): void => {
    startupFailed = true
    setSystemProxyCoreReady(false)
    settleReject(reason)
    if (proc.exitCode === null && proc.signalCode === null) {
      proc.kill('SIGINT')
    }
  }

  const userFacingFatal = (raw: string): string => mapCoreListenError(raw, config.mixedPort) ?? raw

  const startMihomoApiStreams = async (): Promise<void> => {
    await Promise.all([waitForCoreReady(), waitForTcpPort(config.proxyHost, config.mixedPort)])
    if (proc.exitCode !== null || proc.signalCode !== null) {
      throw new Error(
        (lastFatalLine && userFacingFatal(lastFatalLine)) || 'core exited before API became ready'
      )
    }
    await getAxios(true)
    promotePendingRuntimeConfig()
    await Promise.all([
      startMihomoTraffic(),
      startMihomoConnections(),
      startMihomoLogs(),
      startMihomoMemory()
    ])
    setSystemProxyCoreEndpoint(config.proxyHost, config.mixedPort)
    setSystemProxyCoreReady(true)
    startupReady = true
    await persistCoreIdentity(proc, config.corePath).catch((error) => {
      managerLogger.warn('Failed to persist sing-box process identity', error)
    })
    scheduleStableLkgCommit(proc, config.workDir)
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
    cancelStableLkgCommit(proc)

    if (child === proc) {
      child = null
    }
    if (activeCore?.process === proc) activeCore = null
    await removeCoreIdentity(proc.pid)
    setSystemProxyCoreReady(false)

    settleReject(
      new Error(
        (lastFatalLine && userFacingFatal(lastFatalLine)) ||
          `core exited unexpectedly, code: ${code}, signal: ${signal}`
      )
    )

    if (startupFailed || !startupReady) {
      managerLogger.info('Core closed before startup completed, skipping background auto-restart')
      return
    }

    let proxyRestored = false
    try {
      await triggerSysProxy(false)
      proxyRestored = true
    } catch (error) {
      managerLogger.error('Failed to restore system proxy after core exit', error)
    }

    if (!proxyRestored) {
      managerLogger.error(
        'WinINET may still depend on the exited core; bypassing the crash circuit and keeping the endpoint guardian active'
      )
      // An Electron event listener has nowhere to deliver a rejection, and the
      // guardian now rejects on shutdown and on a competing endpoint. Absorb it
      // here instead of relying on the process-wide unhandledRejection net, and
      // tell the user when WinINET is left pointing at a core that is gone.
      try {
        await restartProxyGuardian(config)
      } catch (error) {
        if (error instanceof CoreShutdownInProgressError || isExactEndpointGuardianShutdown()) {
          managerLogger.info('Endpoint guardian stood down because AikoBox is shutting down')
          return
        }
        managerLogger.error(
          'The endpoint guardian could not restore the required proxy endpoint; WinINET may still point at a stopped core',
          error
        )
        safeShowErrorBox(
          'mihomo.error.coreStartFailed',
          `Windows is still pointed at the AikoBox proxy endpoint ${config.proxyHost}:${config.mixedPort}, but the core could not be restarted. Check the system proxy settings before closing AikoBox.\n\n${String(error)}`
        )
      }
      return
    }

    if (isRestarting || restartQueue.hasPending()) {
      managerLogger.info('Core closed during restart, skipping auto-restart')
      return
    }

    const restartDecision = crashRestartPolicy.recordCrash()
    if (!restartDecision.allowed) {
      managerLogger.error(
        `Core crash-loop circuit opened after ${restartDecision.crashCount} exits; automatic restart disabled`
      )
      await stopCore()
      safeShowErrorBox(
        'mihomo.error.coreStartFailed',
        'sing-box exited repeatedly. Automatic restart has been stopped and the previous system proxy was restored. Please inspect the core log before restarting it manually.'
      )
      return
    }

    managerLogger.warn(
      `Unexpected core exit ${restartDecision.crashCount}; retrying in ${restartDecision.delayMs}ms`
    )
    await new Promise((resolve) => setTimeout(resolve, restartDecision.delayMs))
    if (hasCoreProcess() || isRestarting) {
      managerLogger.info('Core was already restarted while crash retry was waiting')
      return
    }

    try {
      await restartCore()
    } catch (error) {
      managerLogger.error('Automatic core restart failed; system proxy remains restored', error)
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
      failStartup(i18next.t('tun.error.tunPermissionDenied'))
      return
    }

    // 混合端口/入站监听冲突（Windows WSAEADDRINUSE / POSIX EADDRINUSE）
    const portConflictMessage = mapCoreListenError(str, config.mixedPort)
    if (portConflictMessage) {
      managerLogger.error(
        `Listen error detected (mixed-port ${config.mixedPort} occupied):\n${portConflictMessage}\nraw: ${str}`
      )
      failStartup(portConflictMessage)
    }
  }

  proc.stdout?.on('data', handleCoreOutput)
  proc.stderr?.on('data', handleCoreOutput)

  proc.on('error', (error) => {
    if (child === proc) child = null
    if (activeCore?.process === proc) activeCore = null
    const mapped = mapCoreListenError(String(error), config.mixedPort)
    if (mapped) {
      managerLogger.error(
        `Core process error (mixed-port ${config.mixedPort} occupied):\n${mapped}\nraw: ${String(error)}`
      )
      failStartup(mapped)
      return
    }
    failStartup(error)
  })

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
      failStartup(error)
    }
  })()
}

// 启动核心
export async function startCore(
  detached = false,
  skipStop = false,
  reportCandidateFallback = false,
  requiredProxyEndpoint?: RequiredProxyEndpoint
): Promise<Promise<void>[]> {
  assertIsolatedSmokeAllows('startCore')
  let config: CoreConfig
  let preparationError: unknown
  try {
    config = await enforceRequiredProxyEndpoint(
      await prepareCore(detached, skipStop),
      requiredProxyEndpoint,
      'candidate'
    )
  } catch (error) {
    preparationError = error
    if (hasCoreProcess() || detached) throw error
    if (requiredProxyEndpoint) {
      await waitForRequiredRecoveryConfig(detached, requiredProxyEndpoint, error)
      return []
    }
    const fallback = await prepareColdStartLastGood(detached).catch((fallbackError) => {
      managerLogger.error('Failed to prepare cold-start last-known-good config', fallbackError)
      return null
    })
    if (!fallback) {
      discardPendingRuntimeConfig()
      throw error
    }
    config = fallback.config
    managerLogger.error(
      'Candidate preparation failed on cold start; starting last-known-good config',
      error
    )
  }
  // Re-verify an AppData-managed binary immediately before every execution.
  // If it changed since candidate validation, fail closed instead of spawning.
  const executionCorePath = await resolveSingboxCorePathForExecution()
  if (executionCorePath !== config.corePath) {
    // The selected managed core may have changed after configuration
    // preparation. Re-check the immutable snapshot with the newly verified
    // executable instead of entering a guardian that can never use it.
    await checkProfile(config.workDir, config.configPath, executionCorePath)
    config = { ...config, corePath: executionCorePath }
  }
  const proc = spawnCoreProcess(config)
  child = proc

  if (detached) {
    managerLogger.info(
      `Core process detached successfully on ${process.platform}, PID: ${proc.pid}`
    )
    proc.unref()
    return [new Promise(() => {})]
  }

  let result: Promise<void>[]
  try {
    result = await new Promise<Promise<void>[]>((resolve, reject) => {
      setupCoreListeners(proc, config, resolve, reject)
    })
  } catch (error) {
    await new Promise((resolve) => setTimeout(resolve, 250))
    const restored = await restoreLastGoodConfig(config.workDir)
    if (!restored) {
      discardPendingRuntimeConfig()
      if (requiredProxyEndpoint) {
        safeShowErrorBox(
          'mihomo.error.coreStartFailed',
          'Windows still depends on the previous AikoBox proxy endpoint. AikoBox will keep retrying the already validated configuration instead of leaving WinINET on a dead port.'
        )
        await resumeRequiredSystemProxyDependency(config, requiredProxyEndpoint)
        return []
      }
      throw error
    }
    restoreRuntimeConfig(restored.runtimeProfile)
    setActiveControllerFromSingboxConfig(restored.config)

    managerLogger.error(
      'New configuration failed at runtime; starting last-known-good config',
      error
    )
    let fallbackConfig: CoreConfig
    try {
      fallbackConfig = await enforceRequiredProxyEndpoint(
        {
          ...config,
          configPath: singboxWorkConfigPath(config.workDir),
          mixedPort: deriveProxyPortFromSingboxConfig(restored.config) ?? config.mixedPort
        },
        requiredProxyEndpoint,
        'last-good'
      )
    } catch (fallbackPreparationError) {
      managerLogger.error(
        'Last-known-good configuration could not be pinned to the required WinINET endpoint',
        fallbackPreparationError
      )
      if (requiredProxyEndpoint) {
        safeShowErrorBox(
          'mihomo.error.coreStartFailed',
          'Windows still depends on the previous AikoBox proxy endpoint. AikoBox will keep retrying the validated candidate on that exact endpoint.'
        )
        await resumeRequiredSystemProxyDependency(config, requiredProxyEndpoint)
        return []
      }
      throw error
    }
    const fallbackProc = spawnCoreProcess(fallbackConfig)
    child = fallbackProc
    let fallbackResult: Promise<void>[]
    try {
      fallbackResult = await new Promise<Promise<void>[]>((resolve, reject) => {
        setupCoreListeners(fallbackProc, fallbackConfig, resolve, reject)
      })
    } catch (fallbackError) {
      managerLogger.error('Last-known-good configuration also failed to start', fallbackError)
      if (requiredProxyEndpoint) {
        safeShowErrorBox(
          'mihomo.error.coreStartFailed',
          'Windows still depends on the previous AikoBox proxy endpoint. AikoBox will keep retrying the last-known-good configuration on that exact endpoint.'
        )
        await resumeRequiredSystemProxyDependency(fallbackConfig, requiredProxyEndpoint, [config])
        return []
      }
      throw error
    }
    safeShowErrorBox(
      'mihomo.error.coreStartFailed',
      `The new configuration was rejected. AikoBox restored the last-known-good configuration.\n\n${String(error)}`
    )
    if (reportCandidateFallback) {
      throw new CoreCandidateRejectedError(error)
    }
    await resumeRequiredSystemProxyDependency(fallbackConfig, requiredProxyEndpoint)
    return fallbackResult
  }

  if (preparationError) {
    safeShowErrorBox(
      'mihomo.error.coreStartFailed',
      `The current configuration could not be prepared. AikoBox started the last-known-good configuration.\n\n${String(preparationError)}`
    )
    if (reportCandidateFallback) {
      throw new CoreCandidateRejectedError(preparationError)
    }
  }
  await resumeRequiredSystemProxyDependency(config, requiredProxyEndpoint)
  return result
}

// 停止核心
export async function stopCore(force = false): Promise<void> {
  setSystemProxyCoreReady(false)
  if (!force && process.platform === 'darwin') {
    try {
      await recoverDNS()
    } catch (error) {
      managerLogger.error('recover dns failed', error)
    }
  }

  if (child) {
    if (activeCore?.process === child) activeCore = null
    cancelStableLkgCommit(child)
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
async function performRestart(): Promise<void> {
  isRestarting = true
  let retryCount = 0
  const maxRetries = 3

  try {
    // 尝试启动核心，失败时重试
    while (retryCount < maxRetries) {
      try {
        // startCore validates the candidate while the current core is still
        // alive, then transactionally restores WinINET and swaps processes.
        await startCore(false, false, true)
        const { sysProxy } = await getAppConfig()
        if (sysProxy.enable) {
          await triggerSysProxy(true)
        }
        return // 成功启动，退出函数
      } catch (e) {
        if (e instanceof CoreCandidateRejectedError) {
          // The fallback endpoint is already healthy. Re-enable the user's
          // owned system proxy before reporting rejection so profile callers
          // can roll back their source transaction without an outage.
          const { sysProxy } = await getAppConfig()
          if (sysProxy.enable) {
            await triggerSysProxy(true)
          }
          throw e
        }
        retryCount++
        managerLogger.error(`restart core failed (attempt ${retryCount}/${maxRetries})`, e)

        if (retryCount >= maxRetries) {
          throw e
        }

        // 重试前等待一段时间
        await new Promise((resolve) => setTimeout(resolve, 1000 * retryCount))
      }
    }
  } finally {
    isRestarting = false
  }
}

export function restartCore(): Promise<void> {
  return restartQueue.enqueue(performRestart)
}

export function installCoreUpdate(version: string): Promise<CoreUpdateResult> {
  return restartQueue.enqueue(async () => {
    return runCoreUpdateTransaction({
      select: async () => {
        const staged = await stageCoreUpdate(version)
        const selection = await applyStagedCoreUpdate(staged.token)
        cachedCoreVersion = ''
        return selection
      },
      restoreSelection: async () => {
        await undoCoreUpdateSelectionChange()
        cachedCoreVersion = ''
      },
      restart: performRestart,
      commitSelection: commitCoreUpdateSelectionChange,
      onRecoveryRestartError: (error) =>
        managerLogger.error('Failed to restart after core update rollback', error)
    })
  })
}

export function rollbackCoreUpdate(): Promise<CoreUpdateResult> {
  return restartQueue.enqueue(() =>
    runCoreUpdateTransaction({
      select: async () => {
        const selection = await rollbackCoreUpdateSelection()
        cachedCoreVersion = ''
        return selection
      },
      restoreSelection: async () => {
        await undoCoreUpdateSelectionChange()
        cachedCoreVersion = ''
      },
      restart: performRestart,
      commitSelection: commitCoreUpdateSelectionChange,
      onRecoveryRestartError: (error) =>
        managerLogger.error('Failed to restart after undoing core rollback', error)
    })
  )
}

export async function setTunEnabled(enable: boolean): Promise<void> {
  assertIsolatedSmokeAllows('setTunEnabled')
  const current = await getControledMihomoConfig()
  const previousTunEnabled = current.tun?.enable ?? false
  const previousDnsEnabled = current.dns?.enable ?? false
  if (previousTunEnabled === enable) return

  await patchControledMihomoConfig(
    enable ? { tun: { enable: true }, dns: { enable: true } } : { tun: { enable: false } }
  )

  try {
    await restartCore()
  } catch (error) {
    await patchControledMihomoConfig({
      tun: { enable: previousTunEnabled },
      dns: { enable: previousDnsEnabled }
    })
    try {
      await restartCore()
    } catch (rollbackError) {
      managerLogger.error('Failed to restart core after rolling back TUN state', rollbackError)
    }
    throw error
  }
}

// 保持核心运行
export async function keepCoreAlive(): Promise<void> {
  try {
    await startCore(true)
    if (child?.pid) {
      if (process.platform === 'win32') {
        await persistCoreIdentity(child, singboxCorePath())
      } else {
        await writeFile(path.join(dataDir(), 'core.pid'), child.pid.toString())
      }
    }
  } catch (e) {
    safeShowErrorBox('mihomo.error.coreStartFailed', `${e}`)
  }
}

// 退出但保持核心运行
export async function quitWithoutCore(): Promise<void> {
  if (process.platform === 'win32') {
    // A detached TUN/core cannot provide crash-safe proxy rollback on Windows.
    // Keep the small main/tray process as the guardian and discard only the
    // renderer window; it will be recreated on demand from the tray.
    managerLogger.info('Windows safe background mode: keeping guardian process alive')
    if (mainWindow && !mainWindow.isDestroyed()) {
      mainWindow.destroy()
    }
    return
  }

  managerLogger.info(`Starting lightweight mode on platform: ${process.platform}`)
  await keepCoreAlive()
  managerLogger.info('Exiting main process, core will continue running in background')
  app.exit()
}

// 检查配置文件（sing-box check）
async function checkProfile(
  workDir: string,
  configPath = singboxWorkConfigPath(workDir),
  corePath = singboxCorePath()
): Promise<void> {
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
  await checkAdminRestartForTunWithRestart()
}
