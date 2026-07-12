import { ChildProcess, spawn } from 'child_process'
import path from 'path'
import { existsSync } from 'fs'
import { readFile, rm, writeFile } from 'fs/promises'
import { dataDir, resourcesFilesDir } from '../utils/dirs'
import { getAppConfig } from '../config'
import { managerLogger } from '../utils/logger'
import {
  captureWindowsProcessIdentity,
  inspectWindowsProcess,
  matchesProcessIdentity,
  parseProcessIdentityRecord
} from '../utils/processIdentity'

let child: ChildProcess | null = null

function monitorExecutablePath(): string {
  return path.join(resourcesFilesDir(), 'TrafficMonitor/TrafficMonitor.exe')
}

async function stopJournaledMonitor(): Promise<void> {
  const pidPath = path.join(dataDir(), 'monitor.pid')
  if (!existsSync(pidPath)) return

  try {
    const record = parseProcessIdentityRecord(await readFile(pidPath, 'utf-8'))
    if (!record) {
      managerLogger.warn('Ignored invalid TrafficMonitor PID journal')
      return
    }

    const actual = await inspectWindowsProcess(record.pid)
    if (actual && matchesProcessIdentity(record, actual, monitorExecutablePath())) {
      process.kill(record.pid, 'SIGINT')
    } else if (actual) {
      managerLogger.warn(
        `Ignored stale TrafficMonitor PID ${record.pid} because its process identity changed`
      )
    }
  } catch (error) {
    managerLogger.warn('Failed to inspect or stop journaled TrafficMonitor process', error)
  } finally {
    await rm(pidPath, { force: true }).catch(() => {})
  }
}

export async function startMonitor(detached = false): Promise<void> {
  if (process.platform !== 'win32') return
  await stopMonitor()
  await stopJournaledMonitor()
  const { showTraffic = false } = await getAppConfig()
  if (!showTraffic) return
  const executablePath = monitorExecutablePath()
  child = spawn(executablePath, [], {
    cwd: path.join(resourcesFilesDir(), 'TrafficMonitor'),
    detached: detached,
    stdio: detached ? 'ignore' : undefined
  })
  if (detached) {
    if (child && child.pid) {
      const identity = await captureWindowsProcessIdentity(child.pid, executablePath)
      if (identity) {
        await writeFile(path.join(dataDir(), 'monitor.pid'), JSON.stringify(identity))
      } else {
        managerLogger.warn('TrafficMonitor started but its process identity could not be captured')
      }
    }
    child.unref()
  }
}

async function stopMonitor(): Promise<void> {
  if (child && child.exitCode === null && child.signalCode === null) {
    child.kill('SIGINT')
  }
  child = null
}
