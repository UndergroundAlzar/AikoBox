import { exec, spawn } from 'child_process'
import { randomBytes } from 'crypto'
import { readFile, stat } from 'fs/promises'
import { existsSync, realpathSync } from 'fs'
import path from 'path'
import { promisify } from 'util'
import { app, dialog, nativeImage, nativeTheme, shell } from 'electron'
import i18next from 'i18next'
import { dataDir, exePath, overridePath, profilePath } from '../utils/dirs'
import { singboxCorePath } from '../core/singbox'
import { stopCore } from '../core/manager'
import { triggerSysProxy } from './sysproxy'

const selectedFileCapabilities = new Map<string, number>()
const SELECTED_FILE_CAPABILITY_TTL_MS = 2 * 60 * 1000

function normalizeSelectedFilePath(filePath: string): string {
  const resolved = path.resolve(filePath)
  return process.platform === 'win32' ? resolved.toLowerCase() : resolved
}

export function consumeSelectedFileCapability(filePath: string): string {
  const resolved = realpathSync(filePath)
  const key = normalizeSelectedFilePath(resolved)
  const expiresAt = selectedFileCapabilities.get(key) ?? 0
  selectedFileCapabilities.delete(key)
  if (expiresAt < Date.now()) {
    throw new Error('File access requires a fresh selection from the native file dialog')
  }
  return resolved
}

export function grantSelectedFileCapability(filePath: string): void {
  const resolved = realpathSync(filePath)
  selectedFileCapabilities.set(
    normalizeSelectedFilePath(resolved),
    Date.now() + SELECTED_FILE_CAPABILITY_TTL_MS
  )
}

export function getFilePath(
  ext: string[],
  title?: string,
  filterName?: string
): string[] | undefined {
  const selected = dialog.showOpenDialogSync({
    title: title || i18next.t('common.dialog.selectSubscriptionFile'),
    filters: [{ name: filterName || `${ext} file`, extensions: ext }],
    properties: ['openFile']
  })
  for (const filePath of selected ?? []) {
    grantSelectedFileCapability(filePath)
  }
  return selected
}

export async function readTextFile(filePath: string): Promise<string> {
  const selected = consumeSelectedFileCapability(filePath)
  if ((await stat(selected)).size > 32 * 1024 * 1024) {
    throw new Error('Selected text file exceeds the 32 MiB limit')
  }
  return await readFile(selected, 'utf8')
}

export async function readImageFileDataURL(filePath: string): Promise<string> {
  filePath = consumeSelectedFileCapability(filePath)
  if ((await stat(filePath)).size > 16 * 1024 * 1024) {
    throw new Error('Selected image exceeds the 16 MiB limit')
  }
  const ext = path.extname(filePath).toLowerCase()
  if (['.ico', '.icns'].includes(ext)) {
    const icon = nativeImage.createFromPath(filePath)
    if (!icon.isEmpty()) return icon.toDataURL()
  }

  const mimeType =
    ext === '.jpg' || ext === '.jpeg'
      ? 'image/jpeg'
      : ext === '.webp'
        ? 'image/webp'
        : ext === '.gif'
          ? 'image/gif'
          : ext === '.ico'
            ? 'image/x-icon'
            : ext === '.icns'
              ? 'image/icns'
              : 'image/png'
  const data = await readFile(filePath)

  return `data:${mimeType};base64,${data.toString('base64')}`
}

export async function openFile(
  type: 'profile' | 'override',
  id: string,
  ext?: 'yaml' | 'js'
): Promise<void> {
  let target: string
  if (type === 'profile') {
    if (ext !== undefined) throw new Error('Profile files do not accept an extension argument')
    target = profilePath(id)
  } else if (type === 'override') {
    if (ext !== 'yaml' && ext !== 'js') throw new Error('Invalid override file extension')
    target = overridePath(id, ext)
  } else {
    throw new Error('Invalid managed file type')
  }

  if (!existsSync(target)) throw new Error('Managed configuration file does not exist')
  // Never ShellExecute a user-writable config from an elevated process. File
  // associations (especially .js) can execute code; Explorer selection cannot.
  shell.showItemInFolder(target)
}

export async function setupFirewall(): Promise<void> {
  const execPromise = promisify(exec)

  if (process.platform === 'win32') {
    // 只管理 AikoBox 自己的防火墙规则，不触碰其他应用（如上游 Mihomo Party）的规则
    const rules = [
      { name: 'AikoBox', program: exePath() },
      { name: 'AikoBox sing-box', program: singboxCorePath() }
    ]
    for (const rule of rules) {
      await execPromise(`netsh advfirewall firewall delete rule name="${rule.name}"`, {
        shell: 'cmd'
      }).catch(() => {})
      await execPromise(
        `netsh advfirewall firewall add rule name="${rule.name}" dir=in action=allow program="${rule.program}" enable=yes profile=any`,
        { shell: 'cmd' }
      )
    }
  }
}

export function setNativeTheme(theme: 'system' | 'light' | 'dark'): void {
  nativeTheme.themeSource = theme
}

export async function resetAppConfig(): Promise<void> {
  if (process.platform !== 'win32') {
    throw new Error('AikoBox reset is supported on Windows only')
  }

  // A reset is allowed only after the same network-safety preconditions used
  // for normal shutdown have succeeded. Failure leaves all user data intact.
  await triggerSysProxy(false)
  await stopCore()

  const source = path.resolve(dataDir())
  const parent = path.dirname(source)
  const token = randomBytes(12).toString('hex')
  const backup = path.join(parent, `${path.basename(source)}.reset-backup-${Date.now()}-${token}`)
  const executable = path.resolve(exePath())
  if (source === parent || path.dirname(backup) !== parent || backup === source) {
    throw new Error('Refusing to reset an unsafe data directory')
  }

  const quote = (value: string): string => `'${value.replace(/'/g, "''")}'`
  const command = [
    `$parentProcess = Get-Process -Id ${process.pid} -ErrorAction SilentlyContinue`,
    'if ($null -ne $parentProcess) { Wait-Process -Id $parentProcess.Id }',
    `$source = ${quote(source)}`,
    `$backup = ${quote(backup)}`,
    'if (Test-Path -LiteralPath $source) { Move-Item -LiteralPath $source -Destination $backup -ErrorAction Stop }',
    `Start-Process -FilePath ${quote(executable)} -WorkingDirectory ${quote(path.dirname(executable))}`
  ].join('; ')
  const encodedCommand = Buffer.from(command, 'utf16le').toString('base64')
  const helper = spawn(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-EncodedCommand', encodedCommand],
    {
      detached: true,
      stdio: 'ignore',
      windowsHide: true
    }
  )
  await new Promise<void>((resolve, reject) => {
    helper.once('spawn', resolve)
    helper.once('error', reject)
  })
  helper.unref()
  app.quit()
}
