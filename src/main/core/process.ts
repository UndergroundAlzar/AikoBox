import { exec, execFile } from 'child_process'
import path from 'path'
import { promisify } from 'util'
import { managerLogger } from '../utils/logger'
import { getAxios } from './mihomoApi'
import { singboxCorePath } from './singbox'

const execPromise = promisify(exec)
const execFilePromise = promisify(execFile)

// 常量
const CORE_READY_MAX_RETRIES = 30
const CORE_READY_RETRY_INTERVAL_MS = 100

/**
 * 清理游离的 sing-box 进程（崩溃残留 / 轻量模式遗留），
 * 避免端口占用导致新核心启动失败。
 *
 * 安全约束：只清理可执行文件路径与本应用自带 sidecar 完全一致的进程，
 * 绝不按进程名批量杀（避免误杀用户自行运行的其他内核实例）。
 */
export async function cleanupStrayCoreProcesses(thorough = false): Promise<void> {
  if (process.platform === 'win32') {
    await cleanupWindowsStrayProcesses(thorough)
  } else {
    await cleanupUnixStrayProcesses()
  }
}

function isOwnCorePath(candidate: string | null | undefined, corePath: string): boolean {
  if (!candidate) return false
  try {
    const a = path.resolve(candidate)
    const b = path.resolve(corePath)
    if (process.platform === 'win32') {
      return a.toLowerCase() === b.toLowerCase()
    }
    return a === b
  } catch {
    return false
  }
}

async function cleanupWindowsStrayProcesses(thorough = false): Promise<void> {
  const corePath = singboxCorePath()
  try {
    const { stdout } = await execPromise(
      `powershell -NoProfile -Command "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Select-Object Id,Path | ConvertTo-Json"`,
      { encoding: 'utf8', windowsHide: true, timeout: thorough ? 20000 : 15000 }
    )

    if (!stdout.trim()) return

    let processArray: { Id?: number; Path?: string | null }[] = []
    try {
      const processes = JSON.parse(stdout)
      processArray = Array.isArray(processes) ? processes : [processes]
    } catch (parseError) {
      managerLogger.warn('Failed to parse process list JSON:', parseError)
      return
    }

    let killed = 0
    for (const proc of processArray) {
      const pid = proc.Id
      // Path 为空（无权限读取）的进程一律跳过，宁可漏杀不可误杀
      if (!pid || pid === process.pid || !isOwnCorePath(proc.Path, corePath)) continue
      await terminateProcess(pid)
      killed++
    }

    if (killed > 0) {
      // 给进程留出退出窗口，避免端口占用导致后续启动失败
      await new Promise((resolve) => setTimeout(resolve, thorough ? 1000 : 200))
    }
  } catch (error) {
    managerLogger.warn('Stray core process cleanup failed:', error)
  }
}

async function cleanupUnixStrayProcesses(): Promise<void> {
  const corePath = singboxCorePath()
  try {
    const { stdout } = await execPromise('pgrep -x sing-box || true')
    const pids = stdout
      .split('\n')
      .map((line) => parseInt(line.trim()))
      .filter((pid) => !isNaN(pid) && pid !== process.pid)

    for (const pid of pids) {
      let argv0 = ''
      try {
        const { stdout: args } = await execFilePromise('ps', ['-o', 'args=', '-p', String(pid)])
        argv0 = args.trim().split(/\s+/)[0] || ''
      } catch {
        continue
      }
      if (!isOwnCorePath(argv0, corePath)) continue
      await terminateProcess(pid)
    }
  } catch (error) {
    managerLogger.warn('Unix stray core process cleanup failed:', error)
  }
}

async function terminateProcess(pid: number): Promise<void> {
  try {
    process.kill(pid, 0)
    process.kill(pid, 'SIGTERM')
    managerLogger.info(`Terminated stray core process ${pid}`)
  } catch (error: unknown) {
    if ((error as { code?: string })?.code !== 'ESRCH') {
      managerLogger.warn(`Failed to terminate process ${pid}:`, error)
    }
  }
}

export async function waitForCoreReady(): Promise<void> {
  for (let i = 0; i < CORE_READY_MAX_RETRIES; i++) {
    try {
      const axios = await getAxios(true)
      await axios.get('/')
      managerLogger.info(
        `Core ready after ${i + 1} attempts (${(i + 1) * CORE_READY_RETRY_INTERVAL_MS}ms)`
      )
      return
    } catch {
      if (i === 0) {
        managerLogger.info('Waiting for core to be ready...')
      }

      if (i === CORE_READY_MAX_RETRIES - 1) {
        managerLogger.warn(
          `Core not ready after ${CORE_READY_MAX_RETRIES} attempts, proceeding anyway`
        )
        return
      }

      await new Promise((resolve) => setTimeout(resolve, CORE_READY_RETRY_INTERVAL_MS))
    }
  }
}
