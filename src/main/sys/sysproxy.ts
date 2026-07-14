import { promisify } from 'util'
import { exec } from 'child_process'
import fs, {
  mkdirSync,
  readFileSync,
  readdirSync,
  renameSync,
  statSync,
  unlinkSync,
  writeFileSync
} from 'fs'
import path from 'path'
import {
  getAutoProxy,
  getSystemProxy,
  setAutoProxy,
  setSystemProxy,
  triggerAutoProxy,
  triggerManualProxy
} from 'sysproxy-rs'
import { net } from 'electron'
import axios from 'axios'
import { getAppConfig } from '../config'
import { pacPort, startPacServer, stopPacServer } from '../resolve/server'
import { proxyLogger } from '../utils/logger'
import { dataDir } from '../utils/dirs'
import {
  getHealthyProxyEndpoint,
  setHealthyProxyEndpoint,
  setHealthyProxyReady
} from '../core/healthyProxyEndpoint'
import { assertIsolatedSmokeAllows } from '../utils/ciIsolatedSmoke'
import {
  createOwnedSystemProxyRecord,
  isOwnedSystemProxyRecord,
  normalizeSystemProxyState,
  sameSystemProxyState,
  type OwnedSystemProxyRecord,
  type SystemProxyState
} from './systemProxyOwnership'
import {
  captureWindowsProxyRegistry,
  restoreWindowsProxyRegistry,
  sameWindowsProxyRegistrySnapshot
} from './windowsProxyRegistry'

let triggerSysProxyTimer: NodeJS.Timeout | null = null
let proxyOperation: Promise<void> = Promise.resolve()
let systemProxyShutdown = false
const helperSocketPath = '/tmp/mihomo-party-helper.sock'

// 是否由本应用设置过系统代理。
// 只有 AikoBox 自己启用过系统代理时才允许清除系统代理，
// 避免启动/退出时误清其他代理软件（或用户手动）设置的系统代理。
let sysProxyAppliedByApp = false
let ownedSystemProxy: OwnedSystemProxyRecord | null = null

function legacyOwnershipStatePath(): string {
  return path.join(dataDir(), 'system-proxy-owner.json')
}

function ownershipStatePaths(): string[] {
  const directory = dataDir()
  let names: string[] = []
  try {
    names = readdirSync(directory)
  } catch {
    // The data directory need not exist before the first transaction.
  }
  return [
    legacyOwnershipStatePath(),
    ...names
      .filter((name) => /^system-proxy-owner\.[^.]+\.[^.]+\.json$/.test(name))
      .map((name) => path.join(directory, name))
  ]
}

function readWindowsProxyState(): SystemProxyState {
  return normalizeSystemProxyState({
    manual: getSystemProxy(),
    auto: getAutoProxy()
  })
}

function applyWindowsProxyState(state: SystemProxyState): void {
  const normalized = normalizeSystemProxyState(state)
  setSystemProxy(normalized.manual)
  setAutoProxy(normalized.auto)
  const actual = readWindowsProxyState()
  if (!sameSystemProxyState(actual, normalized)) {
    throw new Error('Windows did not accept the requested system proxy state')
  }
}

function readOwnershipRecord(): OwnedSystemProxyRecord | null {
  const candidates: { record: OwnedSystemProxyRecord; mtimeMs: number }[] = []
  for (const candidate of ownershipStatePaths()) {
    try {
      const parsed = JSON.parse(readFileSync(candidate, 'utf8')) as unknown
      if (isOwnedSystemProxyRecord(parsed)) {
        candidates.push({ record: parsed, mtimeMs: statSync(candidate).mtimeMs })
      }
    } catch {
      // Ignore missing, incomplete, or corrupt generations.
    }
  }
  candidates.sort(
    (left, right) =>
      (right.record.revision ?? 0) - (left.record.revision ?? 0) || right.mtimeMs - left.mtimeMs
  )
  return candidates[0]?.record ?? null
}

function persistOwnershipRecord(record: OwnedSystemProxyRecord): void {
  const directory = dataDir()
  mkdirSync(directory, { recursive: true })
  record.revision = (record.revision ?? 0) + 1
  const nonce = `${Date.now()}-${Math.random().toString(16).slice(2)}`
  const target = path.join(directory, `system-proxy-owner.${record.revision}.${nonce}.json`)
  const temporary = `${target}.tmp`
  writeFileSync(temporary, JSON.stringify(record), { encoding: 'utf8', mode: 0o600 })
  try {
    renameSync(temporary, target)
  } catch (error) {
    try {
      unlinkSync(temporary)
    } catch {
      // Ignore temporary cleanup failure.
    }
    throw error
  }

  // The new immutable generation is durable before older generations are
  // removed, so a crash can never create an unlink-before-rename journal gap.
  for (const candidate of ownershipStatePaths()) {
    if (candidate === target) continue
    try {
      unlinkSync(candidate)
    } catch {
      // Multiple valid generations are safe; recovery selects the newest.
    }
  }
}

function clearOwnershipRecord(): void {
  ownedSystemProxy = null
  for (const candidate of ownershipStatePaths()) {
    try {
      unlinkSync(candidate)
    } catch {
      // Missing state is already clean.
    }
  }
}

type RestoreOwnedProxyResult = 'restored' | 'external-independent' | 'still-dependent'

function restoreOwnedWindowsProxy(record: OwnedSystemProxyRecord): RestoreOwnedProxyResult {
  const current = readWindowsProxyState()
  const currentRegistry = record.previousRegistry ? captureWindowsProxyRegistry() : undefined
  const exactPrevious =
    record.previousRegistry &&
    currentRegistry &&
    sameWindowsProxyRegistrySnapshot(currentRegistry, record.previousRegistry)
  if (
    exactPrevious ||
    (!record.previousRegistry && sameSystemProxyState(current, record.previous))
  ) {
    clearOwnershipRecord()
    sysProxyAppliedByApp = false
    return 'restored'
  }

  const exactApplied =
    record.appliedRegistry &&
    currentRegistry &&
    sameWindowsProxyRegistrySnapshot(currentRegistry, record.appliedRegistry)
  const simplifiedOwned = record.ownedStates.some((state) => sameSystemProxyState(current, state))
  // Once the complete applied registry image is known, a raw mismatch means a
  // newer actor changed WinINET even if the simplified host/port still looks
  // identical. Preserve that newer state.
  const fullyOwned = record.appliedRegistry ? Boolean(exactApplied) : simplifiedOwned
  const manualOwned =
    !record.appliedRegistry &&
    sameSystemProxyState({ manual: current.manual, auto: record.applied.auto }, record.applied)
  const autoOwned =
    !record.appliedRegistry &&
    sameSystemProxyState({ manual: record.applied.manual, auto: current.auto }, record.applied)

  if (!fullyOwned && !manualOwned && !autoOwned) {
    const stillUsesOwnedManual =
      record.applied.manual.enable &&
      current.manual.enable &&
      current.manual.host === record.applied.manual.host &&
      current.manual.port === record.applied.manual.port
    const stillUsesOwnedPac =
      record.applied.auto.enable &&
      current.auto.enable &&
      current.auto.url === record.applied.auto.url
    if (stillUsesOwnedManual || stillUsesOwnedPac) {
      void proxyLogger.error(
        'WinINET changed outside AikoBox but still points at AikoBox; keeping the core and ownership journal alive'
      )
      return 'still-dependent'
    }
    void proxyLogger.warn(
      'System proxy changed after AikoBox applied it; preserving the newer external state'
    )
    clearOwnershipRecord()
    sysProxyAppliedByApp = false
    return 'external-independent'
  }

  record.phase = 'restoring'
  persistOwnershipRecord(record)

  if (fullyOwned && record.previousRegistry) {
    restoreWindowsProxyRegistry(record.previousRegistry)
    const restoredRegistry = captureWindowsProxyRegistry()
    if (!sameWindowsProxyRegistrySnapshot(restoredRegistry, record.previousRegistry)) {
      throw new Error('Windows did not restore the complete WinINET registry state')
    }
  } else if (fullyOwned) {
    applyWindowsProxyState(record.previous)
  } else {
    const restored: SystemProxyState = {
      manual: manualOwned ? record.previous.manual : current.manual,
      auto: autoOwned ? record.previous.auto : current.auto
    }
    applyWindowsProxyState(restored)
  }
  clearOwnershipRecord()
  sysProxyAppliedByApp = false
  return 'restored'
}

/**
 * Recover a proxy transaction left behind by a crash. Restoration only happens
 * when the current Windows proxy still exactly matches what AikoBox applied;
 * a newer proxy owned by another application is never overwritten.
 */
export async function recoverStaleSystemProxy(): Promise<void> {
  if (process.platform !== 'win32') return
  const record = readOwnershipRecord()
  if (!record) return

  try {
    const result = restoreOwnedWindowsProxy(record)
    if (result === 'restored') {
      await proxyLogger.info('Recovered the system proxy state left by a previous AikoBox run')
    } else if (result === 'still-dependent') {
      // Keep the journal so the main process can bind the core to the old port.
      throw new Error('WinINET still depends on the previous AikoBox core endpoint')
    }
  } catch (error) {
    await proxyLogger.error('Failed to recover the previous system proxy state', error)
    // A corrupt or incompatible journal must not brick startup. Drop ownership
    // records so the next launch does not re-enter this path; leave WinINET
    // alone (Bettbox/other clients may currently own it).
    const message = error instanceof Error ? error.message : String(error)
    if (!/still depends on the previous AikoBox core endpoint/i.test(message)) {
      clearOwnershipRecord()
      await proxyLogger.warn(
        'Cleared unrecoverable system-proxy ownership journal; continuing without auto system proxy'
      )
      return
    }
    throw error
  }
}

export function getStaleSystemProxyCoreEndpoint(): { host: string; port: number } | null {
  if (process.platform !== 'win32') return null
  const record = readOwnershipRecord()
  if (!record) return null
  if (record.coreEndpoint) return { ...record.coreEndpoint }
  if (
    record.applied.manual.enable &&
    record.applied.manual.host &&
    record.applied.manual.port > 0
  ) {
    return { host: record.applied.manual.host, port: record.applied.manual.port }
  }
  return null
}

/**
 * Keep a crash journal's exact loopback dependency alive without rewriting
 * WinINET. This is used only when raw CAS says another actor changed registry
 * details while the simplified proxy still points at AikoBox.
 */
export async function resumeStaleSystemProxyDependency(): Promise<void> {
  if (process.platform !== 'win32') return
  const record = readOwnershipRecord()
  const expected = getStaleSystemProxyCoreEndpoint()
  const healthy = getHealthyProxyEndpoint()
  if (!record || !expected || !healthy) {
    throw new Error('Cannot resume an unverified stale system proxy dependency')
  }
  if (healthy.host !== expected.host || healthy.port !== expected.port) {
    throw new Error(
      `Healthy core endpoint ${healthy.host}:${healthy.port} does not match stale WinINET endpoint ${expected.host}:${expected.port}`
    )
  }
  if (record.applied.auto.enable) await startPacServer(healthy.port)
  ownedSystemProxy = record
  sysProxyAppliedByApp = true
  await proxyLogger.warn(
    'Resumed the stale AikoBox proxy endpoint without overwriting externally changed WinINET data'
  )
}

export function setSystemProxyCoreReady(ready: boolean): void {
  setHealthyProxyReady(ready)
}

export function setSystemProxyCoreEndpoint(host: string, port: number): void {
  setHealthyProxyEndpoint(host, port)
}

export function beginSystemProxyShutdown(): void {
  systemProxyShutdown = true
  if (triggerSysProxyTimer) {
    clearTimeout(triggerSysProxyTimer)
    triggerSysProxyTimer = null
  }
}

export function cancelSystemProxyShutdown(): void {
  systemProxyShutdown = false
}

const defaultBypass: string[] = (() => {
  switch (process.platform) {
    case 'linux':
      return ['localhost', '127.0.0.1', '192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12', '::1']
    case 'darwin':
      return [
        '127.0.0.1',
        '192.168.0.0/16',
        '10.0.0.0/8',
        '172.16.0.0/12',
        'localhost',
        '*.local',
        '*.crashlytics.com',
        '<local>'
      ]
    case 'win32':
      return [
        'localhost',
        '127.*',
        '192.168.*',
        '10.*',
        '172.16.*',
        '172.17.*',
        '172.18.*',
        '172.19.*',
        '172.20.*',
        '172.21.*',
        '172.22.*',
        '172.23.*',
        '172.24.*',
        '172.25.*',
        '172.26.*',
        '172.27.*',
        '172.28.*',
        '172.29.*',
        '172.30.*',
        '172.31.*',
        '<local>'
      ]
    default:
      return ['localhost', '127.0.0.1', '192.168.0.0/16', '10.0.0.0/8', '172.16.0.0/12', '::1']
  }
})()

async function triggerSysProxyInternal(enable: boolean): Promise<void> {
  if (enable && systemProxyShutdown) {
    throw new Error('Refusing to enable the system proxy while AikoBox is exiting')
  }
  if (!enable) {
    if (triggerSysProxyTimer) {
      clearTimeout(triggerSysProxyTimer)
      triggerSysProxyTimer = null
    }
    await disableSysProxy()
    return
  }

  if (net.isOnline()) {
    if (!getHealthyProxyEndpoint()) {
      throw new Error('Refusing to enable the system proxy before sing-box is healthy')
    }
    await disableSysProxy()
    await enableSysProxy()
  } else {
    if (triggerSysProxyTimer) clearTimeout(triggerSysProxyTimer)
    triggerSysProxyTimer = setTimeout(() => {
      void triggerSysProxy(enable).catch((error) =>
        proxyLogger.warn('Deferred proxy enable failed', error)
      )
    }, 5000)
  }
}

export function triggerSysProxy(enable: boolean): Promise<void> {
  assertIsolatedSmokeAllows('triggerSysProxy')
  if (enable && systemProxyShutdown) {
    return Promise.reject(new Error('Refusing to enable the system proxy while AikoBox is exiting'))
  }
  const operation = proxyOperation.then(() => triggerSysProxyInternal(enable))
  proxyOperation = operation.catch(() => {})
  return operation
}

async function enableSysProxy(): Promise<void> {
  const { sysProxy } = await getAppConfig()
  if (systemProxyShutdown) {
    throw new Error('Refusing to enable the system proxy while AikoBox is exiting')
  }
  const { mode, host, bypass = defaultBypass } = sysProxy
  const healthyEndpoint = getHealthyProxyEndpoint()
  if (!healthyEndpoint) {
    throw new Error('Refusing to enable the system proxy without a verified core endpoint')
  }
  const port = healthyEndpoint.port
  const proxyHost = healthyEndpoint.host
  if (host && host !== proxyHost) {
    await proxyLogger.warn(
      `Ignoring configured system proxy host ${host}; using verified endpoint ${proxyHost}`
    )
  }
  // PAC must target the port of the core that actually passed health checks.
  // This differs from configuredPort when a rejected candidate fell back to LKG.
  await startPacServer(port)
  if (systemProxyShutdown) {
    await stopPacServer()
    throw new Error('Refusing to enable the system proxy while AikoBox is exiting')
  }

  if (process.platform === 'win32') {
    const previousRegistry = captureWindowsProxyRegistry()
    const previous = readWindowsProxyState()
    const applied: SystemProxyState =
      mode === 'auto'
        ? {
            manual: { enable: false, host: '', port: 0, bypass: '' },
            auto: { enable: true, url: `http://127.0.0.1:${pacPort}/pac` }
          }
        : {
            manual: { enable: true, host: proxyHost, port, bypass: bypass.join(',') },
            auto: { enable: false, url: '' }
          }
    const intermediate: SystemProxyState = {
      manual: applied.manual,
      auto: previous.auto
    }
    const record = createOwnedSystemProxyRecord(
      previous,
      applied,
      [intermediate],
      process.pid,
      previousRegistry,
      healthyEndpoint
    )

    // Persist intent before touching WinINET so a crash at any later point can
    // be recovered safely on the next launch.
    persistOwnershipRecord(record)
    try {
      applyWindowsProxyState(applied)
      record.appliedRegistry = captureWindowsProxyRegistry()
      record.phase = 'applied'
      persistOwnershipRecord(record)
      ownedSystemProxy = record
      sysProxyAppliedByApp = true
    } catch (error) {
      try {
        restoreWindowsProxyRegistry(previousRegistry)
        if (!sameWindowsProxyRegistrySnapshot(captureWindowsProxyRegistry(), previousRegistry)) {
          throw new Error('Windows did not restore the original WinINET registry state')
        }
        clearOwnershipRecord()
        sysProxyAppliedByApp = false
      } catch (rollbackError) {
        // Keep the journal: the next launch can retry from every known partial
        // state. Losing this record would turn a recoverable failure into a
        // persistent dead proxy.
        await proxyLogger.error('Failed to roll back a partial system proxy update', rollbackError)
      }
      await proxyLogger.error('Failed to enable system proxy transactionally', error)
      throw error
    }
  } else if (process.platform === 'darwin') {
    // macOS 需要 helper 提权
    if (mode === 'auto') {
      await helperRequest(() =>
        axios.post(
          'http://localhost/pac',
          { url: `http://127.0.0.1:${pacPort}/pac` },
          { socketPath: helperSocketPath }
        )
      )
    } else {
      await helperRequest(() =>
        axios.post(
          'http://localhost/global',
          { host: proxyHost, port: port.toString(), bypass: bypass.join(',') },
          { socketPath: helperSocketPath }
        )
      )
    }
    sysProxyAppliedByApp = true
  } else {
    // Windows / Linux 直接使用 sysproxy-rs
    try {
      if (mode === 'auto') {
        triggerAutoProxy(true, `http://127.0.0.1:${pacPort}/pac`)
      } else {
        triggerManualProxy(true, proxyHost, port, bypass.join(','))
      }
      sysProxyAppliedByApp = true
    } catch (error) {
      await proxyLogger.error('Failed to enable system proxy', error)
      throw error
    }
  }
}

async function disableSysProxy(): Promise<void> {
  if (process.platform === 'win32') {
    const record = ownedSystemProxy || readOwnershipRecord()
    if (!record) {
      sysProxyAppliedByApp = false
      await stopPacServer()
      return
    }
    try {
      const result = restoreOwnedWindowsProxy(record)
      if (result === 'still-dependent') {
        throw new Error('WinINET still points at AikoBox after an external proxy change')
      }
      await stopPacServer()
    } catch (error) {
      await proxyLogger.error('Failed to restore the previous system proxy state', error)
      throw error
    }
    return
  }

  await stopPacServer()

  // 系统代理不是本应用设置的，绝不主动清除（可能属于其他代理软件）
  if (!sysProxyAppliedByApp) return

  if (process.platform === 'darwin') {
    await helperRequest(() => axios.get('http://localhost/off', { socketPath: helperSocketPath }))
    sysProxyAppliedByApp = false
  } else {
    // Windows / Linux 直接使用 sysproxy-rs
    try {
      triggerAutoProxy(false, '')
      triggerManualProxy(false, '', 0, '')
      sysProxyAppliedByApp = false
    } catch (error) {
      await proxyLogger.error('Failed to disable system proxy', error)
      throw error
    }
  }
}

export function disableSysProxySync(): boolean {
  if (process.platform === 'darwin') return false
  if (process.platform === 'win32') {
    const record = ownedSystemProxy || readOwnershipRecord()
    if (!record) return true
    try {
      const result = restoreOwnedWindowsProxy(record)
      return result !== 'still-dependent' && readOwnershipRecord() === null
    } catch {
      // The async shutdown path will retry. Never clear another app's proxy.
      return false
    }
  }
  if (!sysProxyAppliedByApp) return true
  try {
    triggerAutoProxy(false, '')
    triggerManualProxy(false, '', 0, '')
    sysProxyAppliedByApp = false
    return true
  } catch {
    return false
  }
}

function isSocketFileExists(): boolean {
  try {
    return fs.existsSync(helperSocketPath)
  } catch {
    return false
  }
}

async function isHelperRunning(): Promise<boolean> {
  try {
    const execPromise = promisify(exec)
    const { stdout } = await execPromise('pgrep -f party.mihomo.helper')
    return stdout.trim().length > 0
  } catch {
    return false
  }
}

async function startHelperService(): Promise<void> {
  const execPromise = promisify(exec)
  const shell = `launchctl kickstart -k system/party.mihomo.helper`
  const command = `do shell script "${shell}" with administrator privileges`
  await execPromise(`osascript -e '${command}'`)
  await new Promise((resolve) => setTimeout(resolve, 1500))
}

async function requestSocketRecreation(): Promise<void> {
  try {
    const execPromise = promisify(exec)
    const shell = `pkill -USR1 -f party.mihomo.helper`
    const command = `do shell script "${shell}" with administrator privileges`
    await execPromise(`osascript -e '${command}'`)
    await new Promise((resolve) => setTimeout(resolve, 1000))
  } catch (error) {
    await proxyLogger.error('Failed to send signal to helper', error)
    throw error
  }
}

async function helperRequest(requestFn: () => Promise<unknown>, maxRetries = 2): Promise<unknown> {
  let lastError: Error | null = null

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      return await requestFn()
    } catch (error) {
      lastError = error as Error
      const errCode = (error as NodeJS.ErrnoException).code
      const errMsg = (error as Error).message || ''

      if (
        attempt < maxRetries &&
        (errCode === 'ECONNREFUSED' ||
          errCode === 'ENOENT' ||
          errMsg.includes('connect ECONNREFUSED') ||
          errMsg.includes('ENOENT'))
      ) {
        await proxyLogger.info(
          `Helper request failed (attempt ${attempt + 1}/${maxRetries + 1}), checking helper status...`
        )

        const helperRunning = await isHelperRunning()
        const socketExists = isSocketFileExists()

        if (!helperRunning) {
          await proxyLogger.info('Helper process not running, starting service...')
          try {
            await startHelperService()
            await proxyLogger.info('Helper service started, retrying...')
            continue
          } catch (startError) {
            await proxyLogger.warn('Failed to start helper service', startError)
          }
        } else if (!socketExists) {
          await proxyLogger.info('Socket file missing but helper running, requesting recreation...')
          try {
            await requestSocketRecreation()
            await proxyLogger.info('Socket recreation requested, retrying...')
            continue
          } catch (signalError) {
            await proxyLogger.warn('Failed to request socket recreation', signalError)
          }
        }
      }

      if (attempt === maxRetries) {
        throw lastError
      }
    }
  }

  throw lastError
}
