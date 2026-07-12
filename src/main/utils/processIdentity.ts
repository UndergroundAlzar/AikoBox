import { execFile } from 'child_process'
import path from 'path'
import { promisify } from 'util'

const execFilePromise = promisify(execFile)

export interface ProcessIdentity {
  pid: number
  executablePath: string
  startTimeMs: number
  commandLine: string
}

export interface ProcessIdentityRecord extends ProcessIdentity {
  version: 2
}

export interface ParsedProcessIdentityRecord {
  pid: number
  executablePath?: string
  startTimeMs?: number
  commandLine?: string
}

function normalizeExecutablePath(value: string): string {
  const resolved = path.resolve(value)
  return process.platform === 'win32' ? resolved.toLowerCase() : resolved
}

export function sameExecutablePath(left: string, right: string): boolean {
  return normalizeExecutablePath(left) === normalizeExecutablePath(right)
}

export function parseProcessIdentityRecord(raw: string): ParsedProcessIdentityRecord | null {
  const trimmed = raw.trim()
  if (!trimmed) return null

  // A PID alone never proves ownership: Windows can reuse it and users may
  // legitimately run the bundled binary themselves. Legacy PID-only files are
  // therefore treated as stale metadata and must never authorize termination.
  if (/^\d+$/.test(trimmed)) return null

  try {
    const value = JSON.parse(trimmed) as Partial<ProcessIdentityRecord>
    const pid = value.pid
    if (
      value.version !== 2 ||
      !Number.isSafeInteger(pid) ||
      (pid ?? 0) <= 0 ||
      typeof value.executablePath !== 'string' ||
      value.executablePath.length === 0 ||
      typeof value.startTimeMs !== 'number' ||
      !Number.isFinite(value.startTimeMs) ||
      value.startTimeMs <= 0 ||
      typeof value.commandLine !== 'string' ||
      value.commandLine.length === 0
    ) {
      return null
    }

    return {
      pid: pid as number,
      executablePath: value.executablePath,
      startTimeMs: value.startTimeMs,
      commandLine: value.commandLine
    }
  } catch {
    return null
  }
}

export function matchesProcessIdentity(
  expected: ParsedProcessIdentityRecord,
  actual: ProcessIdentity,
  expectedExecutablePath: string,
  startTimeToleranceMs = 2000
): boolean {
  if (expected.pid !== actual.pid) return false
  if (!sameExecutablePath(actual.executablePath, expectedExecutablePath)) {
    return false
  }
  if (
    expected.executablePath &&
    !sameExecutablePath(expected.executablePath, expectedExecutablePath)
  ) {
    return false
  }
  if (
    expected.startTimeMs !== undefined &&
    Math.abs(expected.startTimeMs - actual.startTimeMs) > startTimeToleranceMs
  ) {
    return false
  }
  if (!expected.commandLine || expected.commandLine !== actual.commandLine) return false
  return true
}

export async function inspectWindowsProcess(pid: number): Promise<ProcessIdentity | null> {
  if (process.platform !== 'win32' || !Number.isSafeInteger(pid) || pid <= 0) return null

  const script = [
    `$cim = Get-CimInstance Win32_Process -Filter "ProcessId = ${pid}" -ErrorAction SilentlyContinue`,
    `$process = Get-Process -Id ${pid} -ErrorAction SilentlyContinue`,
    'if ($null -ne $process -and $null -ne $process.Path -and $null -ne $cim.CommandLine) {',
    '  [pscustomobject]@{',
    '    Id = $process.Id',
    '    Path = $process.Path',
    "    StartTime = $process.StartTime.ToUniversalTime().ToString('o')",
    '    CommandLine = $cim.CommandLine',
    '  } | ConvertTo-Json -Compress',
    '}'
  ].join('\n')

  try {
    const { stdout } = await execFilePromise(
      'powershell.exe',
      ['-NoProfile', '-NonInteractive', '-Command', script],
      { encoding: 'utf8', windowsHide: true, timeout: 5000 }
    )
    if (!stdout.trim()) return null
    const value = JSON.parse(stdout) as {
      Id?: number
      Path?: string
      StartTime?: string
      CommandLine?: string
    }
    const startTimeMs = Date.parse(value.StartTime ?? '')
    if (
      value.Id !== pid ||
      typeof value.Path !== 'string' ||
      value.Path.length === 0 ||
      typeof value.CommandLine !== 'string' ||
      value.CommandLine.length === 0 ||
      !Number.isFinite(startTimeMs)
    ) {
      return null
    }
    return {
      pid,
      executablePath: value.Path,
      startTimeMs,
      commandLine: value.CommandLine
    }
  } catch {
    // An inaccessible path is intentionally treated as unknown, never owned.
    return null
  }
}

export async function captureWindowsProcessIdentity(
  pid: number,
  executablePath: string
): Promise<ProcessIdentityRecord | null> {
  for (let attempt = 0; attempt < 5; attempt++) {
    const actual = await inspectWindowsProcess(pid)
    if (actual && sameExecutablePath(actual.executablePath, executablePath)) {
      return { version: 2, ...actual }
    }
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  return null
}
