import { execFileSync } from 'child_process'

export interface WindowsProxyRegistryValue {
  exists: boolean
  kind?: string
  data?: string
}

export interface WindowsProxyRegistrySnapshot {
  version: 1
  values: Record<string, WindowsProxyRegistryValue>
}

const targets = [
  ['internet', 'Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', 'ProxyEnable'],
  ['internet', 'Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', 'ProxyServer'],
  ['internet', 'Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', 'ProxyOverride'],
  ['internet', 'Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings', 'AutoConfigURL'],
  [
    'connections',
    'Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\Connections',
    'DefaultConnectionSettings'
  ],
  [
    'connections',
    'Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings\\Connections',
    'SavedLegacySettings'
  ]
] as const

function encodedPowerShell(script: string): string {
  return Buffer.from(script, 'utf16le').toString('base64')
}

function runPowerShell(script: string, env?: NodeJS.ProcessEnv): string {
  return execFileSync(
    'powershell.exe',
    ['-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', encodedPowerShell(script)],
    {
      encoding: 'utf8',
      windowsHide: true,
      timeout: 5000,
      maxBuffer: 1024 * 1024,
      env: env ? { ...process.env, ...env } : process.env
    }
  )
}

export function isWindowsProxyRegistrySnapshot(
  value: unknown
): value is WindowsProxyRegistrySnapshot {
  if (!value || typeof value !== 'object') return false
  const snapshot = value as Partial<WindowsProxyRegistrySnapshot>
  if (snapshot.version !== 1 || !snapshot.values || typeof snapshot.values !== 'object') {
    return false
  }
  return Object.values(snapshot.values).every(
    (entry) =>
      entry &&
      typeof entry === 'object' &&
      typeof entry.exists === 'boolean' &&
      (!entry.exists || (typeof entry.kind === 'string' && typeof entry.data === 'string'))
  )
}

export function sameWindowsProxyRegistrySnapshot(
  left: WindowsProxyRegistrySnapshot,
  right: WindowsProxyRegistrySnapshot
): boolean {
  return JSON.stringify(left) === JSON.stringify(right)
}

export function captureWindowsProxyRegistry(): WindowsProxyRegistrySnapshot {
  if (process.platform !== 'win32') throw new Error('WinINET registry snapshot is Windows-only')
  const targetJson = JSON.stringify(targets)
  const script = `
$ErrorActionPreference = 'Stop'
$targets = ConvertFrom-Json @'
${targetJson}
'@
$values = [ordered]@{}
foreach ($target in $targets) {
  $id = "$($target[0])/$($target[2])"
  $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($target[1], $false)
  if ($null -eq $key -or -not ($key.GetValueNames() -contains $target[2])) {
    $values[$id] = [ordered]@{ exists = $false }
    if ($null -ne $key) { $key.Dispose() }
    continue
  }
  try {
    $kind = $key.GetValueKind($target[2]).ToString()
    $raw = $key.GetValue($target[2], $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $data = if ($raw -is [byte[]]) { [Convert]::ToBase64String($raw) } else { [Convert]::ToString($raw, [Globalization.CultureInfo]::InvariantCulture) }
    $values[$id] = [ordered]@{ exists = $true; kind = $kind; data = $data }
  } finally { $key.Dispose() }
}
[ordered]@{ version = 1; values = $values } | ConvertTo-Json -Compress -Depth 5
`
  const parsed = JSON.parse(runPowerShell(script).trim()) as unknown
  if (!isWindowsProxyRegistrySnapshot(parsed)) {
    throw new Error('PowerShell returned an invalid WinINET registry snapshot')
  }
  return parsed
}

export function restoreWindowsProxyRegistry(snapshot: WindowsProxyRegistrySnapshot): void {
  if (process.platform !== 'win32') throw new Error('WinINET registry restore is Windows-only')
  if (!isWindowsProxyRegistrySnapshot(snapshot))
    throw new Error('Invalid WinINET registry snapshot')
  const targetJson = JSON.stringify(targets)
  const script = `
$ErrorActionPreference = 'Stop'
$snapshot = ConvertFrom-Json $env:AIKOBOX_PROXY_SNAPSHOT
$targets = ConvertFrom-Json @'
${targetJson}
'@
foreach ($target in $targets) {
  $id = "$($target[0])/$($target[2])"
  $entry = $snapshot.values.$id
  $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($target[1], $true)
  try {
    if (-not $entry.exists) {
      $key.DeleteValue($target[2], $false)
      continue
    }
    $kind = [Microsoft.Win32.RegistryValueKind]::$($entry.kind)
    $value = switch ($kind) {
      'Binary' { [Convert]::FromBase64String([string]$entry.data); break }
      'DWord' { [Convert]::ToUInt32([string]$entry.data, [Globalization.CultureInfo]::InvariantCulture); break }
      'QWord' { [Convert]::ToUInt64([string]$entry.data, [Globalization.CultureInfo]::InvariantCulture); break }
      default { [string]$entry.data }
    }
    $key.SetValue($target[2], $value, $kind)
  } finally { $key.Dispose() }
}
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class AikoBoxWinInetNotify {
  [DllImport("wininet.dll", SetLastError=true)]
  public static extern bool InternetSetOption(IntPtr hInternet, int option, IntPtr buffer, int length);
}
'@
[void][AikoBoxWinInetNotify]::InternetSetOption([IntPtr]::Zero, 39, [IntPtr]::Zero, 0)
[void][AikoBoxWinInetNotify]::InternetSetOption([IntPtr]::Zero, 37, [IntPtr]::Zero, 0)
`
  runPowerShell(script, { AIKOBOX_PROXY_SNAPSHOT: JSON.stringify(snapshot) })
}
