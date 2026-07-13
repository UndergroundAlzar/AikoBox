import { exec, execFile } from 'child_process'
import { promisify } from 'util'
import { readFile, stat } from 'fs/promises'
import { existsSync } from 'fs'
import path from 'path'
import { app, dialog } from 'electron'
import { getControledMihomoConfig, patchControledMihomoConfig } from '../config'
import { dataDir, mihomoCoreDir } from '../utils/dirs'
import { managerLogger } from '../utils/logger'
import {
  isExecutableWithinWindowsProgramFiles,
  isWindowsTunElevationAllowed
} from '../utils/portable'
import { checkAutoRun, enableAutoRun } from '../sys/autoRun'
import { triggerSysProxy } from '../sys/sysproxy'
import i18next from '../../shared/i18n'
import {
  inspectWindowsProcess,
  matchesProcessIdentity,
  parseProcessIdentityRecord,
  sameExecutablePath
} from '../utils/processIdentity'
import { assertIsolatedSmokeAllows } from '../utils/ciIsolatedSmoke'
import { singboxCorePath } from './singbox'
import { checkAdminPrivileges } from './admin'

const execPromise = promisify(exec)
const execFilePromise = promisify(execFile)

export async function isTrustedWindowsInstallation(): Promise<boolean> {
  if (!isWindowsTunElevationAllowed(process.execPath, process.env, app.isPackaged)) {
    return false
  }

  try {
    // Environment variables are user-controlled. Ask Windows/.NET for the
    // actual known folder and require the executable to live below it before
    // starting any elevated Electron process.
    const { stdout } = await execFilePromise(
      'powershell.exe',
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '[Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)'
      ],
      { windowsHide: true, timeout: 3000, maxBuffer: 16 * 1024 }
    )
    return isExecutableWithinWindowsProgramFiles(process.execPath, stdout.trim())
  } catch (error) {
    managerLogger.warn('Could not verify the Windows Program Files known folder', error)
    return false
  }
}

// 唯一内核：sing-box（旧的 mihomo/mihomo-alpha/mihomo-smart 配置值一律映射到 sing-box）
type StopCoreBeforeAdminRestart = (force?: boolean) => Promise<void>

let stopCoreBeforeAdminRestart: StopCoreBeforeAdminRestart | null = null

export function setStopCoreBeforeAdminRestart(stopCore: StopCoreBeforeAdminRestart): void {
  stopCoreBeforeAdminRestart = stopCore
}

export function validateCorePath(corePath: string): void {
  if (corePath.includes('..')) {
    throw new Error('Invalid core path: directory traversal detected')
  }

  const dangerousChars = /[;&|`$(){}[\]<>'"\\]/
  if (dangerousChars.test(path.basename(corePath))) {
    throw new Error('Invalid core path: contains dangerous characters')
  }

  const normalizedPath = path.normalize(path.resolve(corePath))
  const expectedDir = path.normalize(path.resolve(mihomoCoreDir()))

  if (!normalizedPath.startsWith(expectedDir + path.sep) && normalizedPath !== expectedDir) {
    throw new Error('Invalid core path: not in expected directory')
  }
}

function shellEscape(arg: string): string {
  return "'" + arg.replace(/'/g, "'\\''") + "'"
}

// 会话管理员状态缓存
let sessionAdminStatus: boolean | null = null

export async function initAdminStatus(): Promise<void> {
  if (process.platform === 'win32' && sessionAdminStatus === null) {
    sessionAdminStatus = await checkAdminPrivileges().catch(() => false)
  }
}

export function getSessionAdminStatus(): boolean {
  if (process.platform !== 'win32') {
    return true
  }
  return sessionAdminStatus ?? false
}

export { checkAdminPrivileges } from './admin'

export async function checkMihomoCorePermissions(): Promise<boolean> {
  const corePath = singboxCorePath()

  try {
    if (process.platform === 'win32') {
      if (!(await isTrustedWindowsInstallation())) {
        return false
      }
      return await checkAdminPrivileges()
    }

    if (process.platform === 'darwin' || process.platform === 'linux') {
      const stats = await stat(corePath)
      return (stats.mode & 0o4000) !== 0 && stats.uid === 0
    }
  } catch {
    return false
  }

  return false
}

export async function checkHighPrivilegeCore(): Promise<boolean> {
  try {
    const corePath = singboxCorePath()

    managerLogger.info(`Checking high privilege core: ${corePath}`)

    if (process.platform === 'win32') {
      if (!existsSync(corePath)) {
        managerLogger.info('Core file does not exist')
        return false
      }

      const hasHighPrivilegeProcess = await checkHighPrivilegeCoreProcess()
      if (hasHighPrivilegeProcess) {
        managerLogger.info('Found high privilege core process running')
        return true
      }

      const isAdmin = await checkAdminPrivileges()
      managerLogger.info(`Current process admin privileges: ${isAdmin}`)
      return isAdmin
    }

    if (process.platform === 'darwin' || process.platform === 'linux') {
      managerLogger.info('Non-Windows platform, skipping high privilege core check')
      return false
    }
  } catch (error) {
    managerLogger.error('Failed to check high privilege core', error)
    return false
  }

  return false
}

async function checkHighPrivilegeCoreProcess(): Promise<boolean> {
  try {
    if (process.platform === 'win32') {
      const corePath = singboxCorePath()
      const pidRecord = parseProcessIdentityRecord(
        await readFile(path.join(dataDir(), 'core.pid'), 'utf-8').catch(() => '')
      )
      // Never attribute an arbitrary inaccessible sing-box process to AikoBox.
      // Only a versioned ownership record written by our own spawn path is
      // eligible for the UAC handoff.
      if (
        !pidRecord?.executablePath ||
        pidRecord.startTimeMs === undefined ||
        !sameExecutablePath(pidRecord.executablePath, corePath)
      ) {
        return false
      }

      try {
        const result = await execFilePromise(
          'tasklist',
          ['/FI', `PID eq ${pidRecord.pid}`, '/FO', 'CSV', '/NH'],
          {
            windowsHide: true,
            timeout: 3000,
            maxBuffer: 1024 * 1024
          }
        )
        const match = result.stdout.match(/^"([^"]+)","(\d+)"/m)
        if (
          !match ||
          match[1].toLowerCase() !== 'sing-box.exe' ||
          Number(match[2]) !== pidRecord.pid
        ) {
          return false
        }

        const actual = await inspectWindowsProcess(pidRecord.pid)
        if (actual) {
          return matchesProcessIdentity(pidRecord, actual, corePath)
        }

        // An elevated process may hide Path/StartTime from a non-elevated
        // caller. The exact PID plus our structured journal is sufficient to
        // offer a UAC handoff; no process is terminated in this branch.
        return true
      } catch (error) {
        managerLogger.error('Failed to inspect journaled core process', error)
        return false
      }
    } else {
      const coreExecutable = 'sing-box'
      let foundProcesses = false

      try {
        const { stdout } = await execPromise(`ps aux | grep ${coreExecutable} | grep -v grep`)
        const lines = stdout
          .split('\n')
          .filter((line) => line.trim() && line.includes(coreExecutable))

        if (lines.length > 0) {
          foundProcesses = true
          managerLogger.info(`Found ${lines.length} ${coreExecutable} processes running`)

          for (const line of lines) {
            const parts = line.trim().split(/\s+/)
            if (parts.length >= 1) {
              const user = parts[0]
              managerLogger.info(`${coreExecutable} process running as user: ${user}`)

              if (user === 'root') {
                return true
              }
            }
          }
        }
      } catch {
        // ignore
      }

      if (!foundProcesses) {
        managerLogger.info('No core processes found running')
      }
    }
  } catch (error) {
    managerLogger.error('Failed to check high privilege core process', error)
  }

  return false
}

export async function grantTunPermissions(): Promise<void> {
  assertIsolatedSmokeAllows('grantTunPermissions')
  const corePath = singboxCorePath()
  validateCorePath(corePath)

  if (process.platform === 'darwin') {
    const escapedPath = shellEscape(corePath)
    const script = `do shell script "chown root:admin ${escapedPath} && chmod +sx ${escapedPath}" with administrator privileges`
    await execFilePromise('osascript', ['-e', script])
  }

  if (process.platform === 'linux') {
    await execFilePromise('pkexec', ['chown', 'root:root', corePath])
    await execFilePromise('pkexec', ['chmod', '+sx', corePath])
  }

  if (process.platform === 'win32') {
    throw new Error('Windows platform requires running as administrator')
  }
}

export async function restartAsAdmin(forTun: boolean = true): Promise<void> {
  assertIsolatedSmokeAllows('restartAsAdmin')
  if (process.platform !== 'win32') {
    throw new Error('This function is only available on Windows')
  }

  const exePath = process.execPath
  if (!(await isTrustedWindowsInstallation())) {
    throw new Error(
      'Administrator elevation is available only from the installed AikoBox in Program Files; development and portable builds support system proxy mode only'
    )
  }

  const args = process.argv
    .slice(1)
    .filter(
      (arg) => arg !== '--admin-restart-for-tun' && !arg.startsWith('--wait-for-aikobox-pid=')
    )
  const restartArgs = [
    ...args,
    ...(forTun ? ['--admin-restart-for-tun'] : []),
    `--wait-for-aikobox-pid=${process.pid}`
  ]
  const quotePowerShell = (value: string): string => `'${value.replace(/'/g, "''")}'`
  const argumentList = restartArgs.map(quotePowerShell).join(',')
  const command = `$process = Start-Process -FilePath ${quotePowerShell(exePath)} -ArgumentList @(${argumentList}) -WorkingDirectory ${quotePowerShell(path.dirname(exePath))} -Verb RunAs -PassThru; if ($null -eq $process) { exit 1 }`
  const encodedCommand = Buffer.from(command, 'utf16le').toString('base64')

  // Release the single-instance lock only for the UAC handoff. The elevated
  // instance acquires it immediately but waits for this PID before touching the
  // core. If UAC is cancelled, reacquire the lock and leave networking intact.
  app.releaseSingleInstanceLock()
  try {
    await execFilePromise(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-EncodedCommand', encodedCommand],
      { windowsHide: true, timeout: 120000 }
    )
  } catch (error) {
    app.requestSingleInstanceLock()
    managerLogger.warn('Administrator restart was cancelled or failed; keeping current core', error)
    throw error
  }

  // UAC was accepted and the elevated replacement is waiting. Restore the
  // user's previous proxy before stopping this instance's core.
  try {
    await triggerSysProxy(false)
  } catch (error) {
    app.requestSingleInstanceLock()
    managerLogger.error(
      'Administrator handoff aborted because the system proxy could not be restored',
      error
    )
    throw error
  }
  try {
    managerLogger.info('Stopping core after elevated replacement was accepted...')
    await stopCoreBeforeAdminRestart?.(true)
  } catch (error) {
    managerLogger.warn('Failed to stop core before restart:', error)
  }

  managerLogger.info('Elevated replacement accepted, quitting current instance')
  app.exit(0)
}

export async function requestTunPermissions(): Promise<void> {
  if (process.platform === 'win32') {
    await restartAsAdmin()
  } else {
    const hasPermissions = await checkMihomoCorePermissions()
    if (!hasPermissions) {
      await grantTunPermissions()
    }
  }
}

export async function showTunPermissionDialog(): Promise<boolean> {
  managerLogger.info('Preparing TUN permission dialog...')

  const title = i18next.t('tun.permissions.title') || '需要管理员权限'
  const message =
    i18next.t('tun.permissions.message') ||
    '启用 TUN 模式需要管理员权限，是否现在重启应用获取权限？'
  const confirmText = i18next.t('common.confirm') || '确认'
  const cancelText = i18next.t('common.cancel') || '取消'

  const choice = dialog.showMessageBoxSync({
    type: 'warning',
    title,
    message,
    buttons: [confirmText, cancelText],
    defaultId: 0,
    cancelId: 1
  })

  managerLogger.info(`TUN permission dialog choice: ${choice}`)
  return choice === 0
}

export async function showErrorDialog(title: string, message: string): Promise<void> {
  const okText = i18next.t('common.confirm') || '确认'

  dialog.showMessageBoxSync({
    type: 'error',
    title,
    message,
    buttons: [okText],
    defaultId: 0
  })
}

export async function validateTunPermissionsOnStartup(): Promise<void> {
  const { tun } = await getControledMihomoConfig()

  if (!tun?.enable) {
    return
  }

  const hasPermissions = await checkMihomoCorePermissions()

  if (!hasPermissions) {
    // 启动时没有权限，静默禁用 TUN，不弹窗打扰用户
    managerLogger.warn(
      'TUN is enabled but insufficient permissions detected, auto-disabling TUN...'
    )
    await patchControledMihomoConfig({ tun: { enable: false } })

    managerLogger.info('TUN auto-disabled due to insufficient permissions on startup')
  } else {
    managerLogger.info('TUN permissions validated successfully')
  }
}

export async function checkAdminRestartForTun(): Promise<void> {
  if (process.argv.includes('--admin-restart-for-tun')) {
    managerLogger.info('Detected admin restart for TUN mode, auto-enabling TUN...')

    if (process.platform === 'win32' && !(await isTrustedWindowsInstallation())) {
      await patchControledMihomoConfig({ tun: { enable: false } }).catch((error) =>
        managerLogger.error('Failed to persist the unsafe TUN disable', error)
      )
      throw new Error(
        'Refusing TUN elevation outside the installed AikoBox directory in Program Files'
      )
    }

    try {
      if (process.platform === 'win32') {
        const hasAdminPrivileges = await checkAdminPrivileges()
        if (hasAdminPrivileges) {
          await patchControledMihomoConfig({ tun: { enable: true }, dns: { enable: true } })

          const autoRunEnabled = await checkAutoRun()
          if (autoRunEnabled) {
            await enableAutoRun()
          }

          managerLogger.info('TUN mode enabled before starting the elevated core')
        } else {
          managerLogger.warn('Admin restart detected but no admin privileges found')
        }
      }
    } catch (error) {
      managerLogger.error('Failed to auto-enable TUN after admin restart', error)
    }
  } else {
    await validateTunPermissionsOnStartup()
  }
}

export function checkTunPermissions(): Promise<boolean> {
  return checkMihomoCorePermissions()
}

export function manualGrantCorePermition(): Promise<void> {
  return grantTunPermissions()
}
