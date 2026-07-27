import https from 'https'
import os from 'os'
import { existsSync, readFileSync } from 'fs'
import { lstat, mkdir, mkdtemp, readFile, readdir, rename, rm, stat, writeFile } from 'fs/promises'
import { dirname, join } from 'path'
import type { Readable } from 'stream'
import dayjs from 'dayjs'
import AdmZip from 'adm-zip'
import { Cron } from 'croner'
import { dialog } from 'electron'
import i18next from 'i18next'
import { systemLogger } from '../utils/logger'
import {
  appConfigPath,
  controledMihomoConfigPath,
  dataDir,
  overrideConfigPath,
  overrideDir,
  profileConfigPath,
  profilesDir,
  rulesDir,
  subStoreDir,
  themesDir
} from '../utils/dirs'
import {
  getAppConfig,
  getControledMihomoConfig,
  getOverrideConfig,
  getProfileConfig
} from '../config'
import { runProfileStorageTransaction } from '../config/profileStorageTransaction'
import { parse, stringify } from '../utils/yaml'

let backupCronJob: Cron | null = null

const RESTORABLE_ENTRIES = new Set([
  'config.yaml',
  'mihomo.yaml',
  'profiles.yaml',
  'override.yaml',
  'themes',
  'profiles',
  'override',
  'rules',
  'substore'
])
const RESTORABLE_DIRECTORIES = new Set(['themes', 'profiles', 'override', 'rules', 'substore'])
const MAX_BACKUP_ARCHIVE_BYTES = 64 * 1024 * 1024
const MAX_BACKUP_EXPANDED_BYTES = 256 * 1024 * 1024
const BACKUP_METADATA_ENTRY = 'backup-metadata.json'
const REMOTE_OMITTED_APP_CONFIG_KEYS = [
  'githubToken',
  'gistAgeSecretKey',
  'webdavPassword',
  'encryptedPassword'
] as const
const REMOTE_OMITTED_BACKUP_ENTRIES = ['profiles.yaml', 'profiles', 'substore'] as const

interface BackupMetadata {
  version: 1
  omittedAppConfigKeys?: string[]
  omittedBackupEntries?: string[]
}

interface WebDAVContext {
  client: ReturnType<Awaited<typeof import('webdav/dist/node/index.js')>['createClient']>
  webdavDir: string
  webdavMaxBackups: number
}

function sanitizeDeviceNameForFilename(name: string): string {
  const withoutControlChars = Array.from(name)
    .filter((char) => char.charCodeAt(0) >= 32)
    .join('')

  const sanitized = withoutControlChars
    .trim()
    .replace(/[<>:"/\\|?*]/g, '-')
    .replace(/\s+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-+|-+$/g, '')

  return sanitized || 'unknown-device'
}

function getWebDAVBackupPrefix(): string {
  const deviceName = sanitizeDeviceNameForFilename(os.hostname())
  return `${process.platform}_${deviceName}`
}

async function getWebDAVClient(): Promise<WebDAVContext> {
  const { createClient } = await import('webdav/dist/node/index.js')
  const {
    webdavUrl = '',
    webdavUsername = '',
    webdavPassword = '',
    webdavDir = 'aikobox',
    webdavMaxBackups = 0,
    webdavIgnoreCert = false
  } = await getAppConfig()

  const clientOptions: Parameters<typeof createClient>[1] = {
    username: webdavUsername,
    password: webdavPassword
  }

  if (webdavIgnoreCert) {
    clientOptions.httpsAgent = new https.Agent({
      rejectUnauthorized: false
    })
  }

  const client = createClient(webdavUrl, clientOptions)

  return { client, webdavDir, webdavMaxBackups }
}

export function createBackupZip(options: { omitAppConfigSecrets?: boolean } = {}): AdmZip {
  const zip = new AdmZip()

  const files = [
    appConfigPath(),
    controledMihomoConfigPath(),
    profileConfigPath(),
    overrideConfigPath()
  ]

  const folders = [
    { path: themesDir(), name: 'themes' },
    { path: profilesDir(), name: 'profiles' },
    { path: overrideDir(), name: 'override' },
    { path: rulesDir(), name: 'rules' },
    { path: subStoreDir(), name: 'substore' }
  ]

  for (const file of files) {
    if (existsSync(file)) {
      if (options.omitAppConfigSecrets && file === profileConfigPath()) {
        continue
      }
      if (file === appConfigPath() && options.omitAppConfigSecrets) {
        const config = (parse(readFileSync(file, 'utf8')) || {}) as Record<string, unknown>
        for (const key of REMOTE_OMITTED_APP_CONFIG_KEYS) delete config[key]
        zip.addFile('config.yaml', Buffer.from(stringify(config), 'utf8'))
      } else {
        zip.addLocalFile(file)
      }
    }
  }

  for (const { path, name } of folders) {
    if (
      options.omitAppConfigSecrets &&
      REMOTE_OMITTED_BACKUP_ENTRIES.includes(name as (typeof REMOTE_OMITTED_BACKUP_ENTRIES)[number])
    ) {
      continue
    }
    if (existsSync(path)) {
      zip.addLocalFolder(path, name)
    }
  }

  if (options.omitAppConfigSecrets) {
    const metadata: BackupMetadata = {
      version: 1,
      omittedAppConfigKeys: [...REMOTE_OMITTED_APP_CONFIG_KEYS],
      omittedBackupEntries: [...REMOTE_OMITTED_BACKUP_ENTRIES]
    }
    zip.addFile(BACKUP_METADATA_ENTRY, Buffer.from(`${JSON.stringify(metadata)}\n`, 'utf8'))
  }

  return zip
}

function restorableTopLevelEntries(zip: AdmZip, metadata: BackupMetadata | null): string[] {
  const entries = new Set<string>()
  const omittedEntries = new Set(metadata?.omittedBackupEntries || [])
  let expandedBytes = 0

  for (const entry of zip.getEntries()) {
    const normalized = entry.entryName.replace(/\\/g, '/')
    const parts = normalized.split('/').filter(Boolean)
    if (
      normalized.startsWith('/') ||
      /^[A-Za-z]:/.test(normalized) ||
      parts.length === 0 ||
      parts.includes('..')
    ) {
      throw new Error(`Unsafe backup entry: ${entry.entryName}`)
    }

    const topLevel = parts[0]
    if (topLevel === BACKUP_METADATA_ENTRY && parts.length === 1) continue
    if (!RESTORABLE_ENTRIES.has(topLevel)) {
      throw new Error(`Unsupported backup entry: ${entry.entryName}`)
    }
    if (parts.length > 1 && !RESTORABLE_DIRECTORIES.has(topLevel)) {
      throw new Error(`Unsafe backup entry: ${entry.entryName}`)
    }
    expandedBytes += entry.header.size
    if (expandedBytes > MAX_BACKUP_EXPANDED_BYTES) {
      throw new Error('Expanded backup exceeds 256 MiB')
    }
    if (omittedEntries.has(topLevel)) continue
    entries.add(topLevel)
  }

  if (entries.size === 0) throw new Error('Backup contains no restorable data')
  return [...entries]
}

function backupMetadata(zip: AdmZip): BackupMetadata | null {
  const entry = zip.getEntry(BACKUP_METADATA_ENTRY)
  if (!entry) return null
  const parsed = JSON.parse(entry.getData().toString('utf8')) as Partial<BackupMetadata>
  if (parsed.version !== 1 || !Array.isArray(parsed.omittedAppConfigKeys)) {
    throw new Error('Backup metadata is invalid or unsupported')
  }
  return {
    version: 1,
    omittedAppConfigKeys: parsed.omittedAppConfigKeys.filter((key) => typeof key === 'string'),
    omittedBackupEntries: Array.isArray(parsed.omittedBackupEntries)
      ? parsed.omittedBackupEntries.filter(
          (entry) => typeof entry === 'string' && RESTORABLE_ENTRIES.has(entry)
        )
      : []
  }
}

async function preserveOmittedAppConfigSecrets(
  stagingDir: string,
  metadata: BackupMetadata | null
): Promise<void> {
  if (!metadata?.omittedAppConfigKeys?.length) return
  const stagedPath = join(stagingDir, 'config.yaml')
  if (!existsSync(stagedPath) || !existsSync(appConfigPath())) return

  const [stagedText, currentText] = await Promise.all([
    readFile(stagedPath, 'utf8'),
    readFile(appConfigPath(), 'utf8')
  ])
  const staged = (parse(stagedText) || {}) as Record<string, unknown>
  const current = (parse(currentText) || {}) as Record<string, unknown>
  for (const key of metadata.omittedAppConfigKeys) {
    if (Object.prototype.hasOwnProperty.call(current, key)) staged[key] = current[key]
  }
  await writeFile(stagedPath, stringify(staged), 'utf8')
}

async function assertNoLinks(target: string): Promise<void> {
  const stat = await lstat(target)
  if (stat.isSymbolicLink()) throw new Error('Backup contains a symbolic link')
  if (!stat.isDirectory()) return

  for (const child of await readdir(target)) {
    await assertNoLinks(join(target, child))
  }
}

async function refreshRestoredConfigCaches(): Promise<void> {
  await getAppConfig(true)
  await getControledMihomoConfig(true)
  await getProfileConfig(true)
  await getOverrideConfig(true)
}

interface ReplacedEntry {
  name: string
  hadOriginal: boolean
}

async function rollbackReplacedEntries(
  replaced: ReplacedEntry[],
  rollbackDir: string
): Promise<void> {
  for (const { name, hadOriginal } of [...replaced].reverse()) {
    const target = join(dataDir(), name)
    await rm(target, { recursive: true, force: true })
    if (hadOriginal) {
      await rename(join(rollbackDir, name), target)
    }
  }
}

async function restoreBackupZip(zip: AdmZip): Promise<void> {
  const metadata = backupMetadata(zip)
  const entries = restorableTopLevelEntries(zip, metadata)
  const restoreRoot = await mkdtemp(join(dirname(dataDir()), '.aikobox-restore-'))
  const stagingDir = join(restoreRoot, 'staging')
  const rollbackDir = join(restoreRoot, 'rollback')
  const replaced: ReplacedEntry[] = []
  let keepRecoveryData = false

  try {
    await Promise.all([mkdir(stagingDir), mkdir(rollbackDir)])
    zip.extractAllTo(stagingDir, true)

    for (const name of entries) {
      const staged = join(stagingDir, name)
      if (!existsSync(staged)) throw new Error(`Backup entry was not extracted: ${name}`)
      await assertNoLinks(staged)
    }
    await preserveOmittedAppConfigSecrets(stagingDir, metadata)

    for (const name of entries) {
      const target = join(dataDir(), name)
      const hadOriginal = existsSync(target)
      if (hadOriginal) await rename(target, join(rollbackDir, name))
      replaced.push({ name, hadOriginal })
      await rename(join(stagingDir, name), target)
    }

    await refreshRestoredConfigCaches()
    const { restartCore } = await import('../core/manager')
    await restartCore()
  } catch (restoreError) {
    const rollbackErrors: unknown[] = []
    let diskRollbackSucceeded = true

    try {
      await rollbackReplacedEntries(replaced, rollbackDir)
    } catch (error) {
      diskRollbackSucceeded = false
      keepRecoveryData = true
      rollbackErrors.push(error)
    }

    if (replaced.length > 0 && diskRollbackSucceeded) {
      try {
        await refreshRestoredConfigCaches()
      } catch (error) {
        rollbackErrors.push(error)
      }

      try {
        const { restartCore } = await import('../core/manager')
        await restartCore()
      } catch (error) {
        rollbackErrors.push(error)
      }
    }

    if (rollbackErrors.length > 0) {
      throw new AggregateError(
        [restoreError, ...rollbackErrors],
        keepRecoveryData
          ? `Backup restore failed and the previous state could not be fully restored; recovery data was retained at ${restoreRoot}`
          : 'Backup restore failed and the previous runtime state could not be fully restored'
      )
    }
    throw restoreError
  } finally {
    if (!keepRecoveryData) {
      await rm(restoreRoot, { recursive: true, force: true })
    }
  }
}

async function enqueueBackupRestore(zip: AdmZip): Promise<void> {
  await runProfileStorageTransaction(() => restoreBackupZip(zip))
}

export async function webdavBackup(): Promise<boolean> {
  const { client, webdavDir, webdavMaxBackups } = await getWebDAVClient()
  const zip = createBackupZip({ omitAppConfigSecrets: true })
  const date = new Date()
  const backupPrefix = getWebDAVBackupPrefix()
  const zipFileName = `${backupPrefix}_${dayjs(date).format('YYYY-MM-DD_HH-mm-ss')}.zip`

  try {
    await client.createDirectory(webdavDir)
  } catch {
    // ignore
  }

  const result = await client.putFileContents(`${webdavDir}/${zipFileName}`, zip.toBuffer())

  if (webdavMaxBackups > 0) {
    try {
      const fileList = await client.getDirectoryContents(webdavDir, { glob: '*.zip' })

      const currentPlatformFiles = fileList.filter((file) => {
        return file.basename.startsWith(`${backupPrefix}_`)
      })

      currentPlatformFiles.sort((a, b) => {
        const timeA = a.basename.match(/_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})\.zip$/)?.[1] || ''
        const timeB = b.basename.match(/_(\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2})\.zip$/)?.[1] || ''
        return timeB.localeCompare(timeA)
      })

      if (currentPlatformFiles.length > webdavMaxBackups) {
        const filesToDelete = currentPlatformFiles.slice(webdavMaxBackups)

        for (let i = 0; i < filesToDelete.length; i++) {
          const file = filesToDelete[i]
          await client.deleteFile(`${webdavDir}/${file.basename}`)

          if (i < filesToDelete.length - 1) {
            await new Promise((resolve) => setTimeout(resolve, 500))
          }
        }
      }
    } catch (error) {
      await systemLogger.error('Failed to clean up old backup files', error)
    }
  }

  return result
}

export async function webdavRestore(filename: string): Promise<void> {
  const { client, webdavDir } = await getWebDAVClient()
  const safeFilename = assertWebdavBackupFilename(filename)
  const zipData = await downloadBoundedBuffer(
    client.createReadStream(`${webdavDir}/${safeFilename}`),
    MAX_BACKUP_ARCHIVE_BYTES
  )
  const zip = new AdmZip(zipData)
  await enqueueBackupRestore(zip)
}

export async function downloadBoundedBuffer(stream: Readable, limit: number): Promise<Buffer> {
  const chunks: Buffer[] = []
  let total = 0
  for await (const chunk of stream) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string)
    total += buffer.length
    if (total > limit) {
      stream.destroy()
      throw new Error('Backup archive exceeds 64 MiB')
    }
    chunks.push(buffer)
  }
  return Buffer.concat(chunks)
}

export async function listWebdavBackups(): Promise<string[]> {
  const { client, webdavDir } = await getWebDAVClient()
  const files = await client.getDirectoryContents(webdavDir, { glob: '*.zip' })
  return files.map((file) => file.basename)
}

export async function webdavDelete(filename: string): Promise<void> {
  const { client, webdavDir } = await getWebDAVClient()
  await client.deleteFile(`${webdavDir}/${assertWebdavBackupFilename(filename)}`)
}

export function assertWebdavBackupFilename(filename: string): string {
  const value = String(filename)
  const hasControlCharacter = Array.from(value).some((char) => char.charCodeAt(0) < 32)
  if (
    value !== value.trim() ||
    !value.toLowerCase().endsWith('.zip') ||
    value.includes('..') ||
    hasControlCharacter ||
    /[<>:"/\\|?*%#]/u.test(value)
  ) {
    throw new Error('Invalid WebDAV backup filename')
  }
  return value
}

/**
 * 初始化 WebDAV 定时备份任务
 */
export async function initWebdavBackupScheduler(): Promise<void> {
  try {
    // 先停止现有的定时任务
    if (backupCronJob) {
      backupCronJob.stop()
      backupCronJob = null
    }

    const { webdavBackupCron } = await getAppConfig()

    // 如果配置了 Cron 表达式，则启动定时任务
    if (webdavBackupCron) {
      backupCronJob = new Cron(webdavBackupCron, async () => {
        try {
          await webdavBackup()
          await systemLogger.info('WebDAV backup completed successfully via cron job')
        } catch (error) {
          await systemLogger.error('Failed to execute WebDAV backup via cron job', error)
        }
      })

      await systemLogger.info(`WebDAV backup scheduler initialized with cron: ${webdavBackupCron}`)
      await systemLogger.info(`WebDAV backup scheduler nextRun: ${backupCronJob.nextRun()}`)
    } else {
      await systemLogger.info('WebDAV backup scheduler disabled (no cron expression configured)')
    }
  } catch (error) {
    await systemLogger.error('Failed to initialize WebDAV backup scheduler', error)
  }
}

/**
 * 停止 WebDAV 定时备份任务
 */
export async function stopWebdavBackupScheduler(): Promise<void> {
  if (backupCronJob) {
    backupCronJob.stop()
    backupCronJob = null
    await systemLogger.info('WebDAV backup scheduler stopped')
  }
}

/**
 * 重新初始化 WebDAV 定时备份任务
 * 先停止现有任务，然后重新启动
 */
export async function reinitScheduler(): Promise<void> {
  await systemLogger.info('Reinitializing WebDAV backup scheduler...')
  await stopWebdavBackupScheduler()
  await initWebdavBackupScheduler()
  await systemLogger.info('WebDAV backup scheduler reinitialized successfully')
}

/**
 * 导出本地备份
 */
export async function exportLocalBackup(): Promise<boolean> {
  const zip = createBackupZip()

  const date = new Date()
  const zipFileName = `aikobox-backup-${dayjs(date).format('YYYY-MM-DD_HH-mm-ss')}.zip`
  const result = await dialog.showSaveDialog({
    title: i18next.t('localBackup.export.title'),
    defaultPath: zipFileName,
    filters: [
      { name: 'ZIP Files', extensions: ['zip'] },
      { name: 'All Files', extensions: ['*'] }
    ]
  })

  if (!result.canceled && result.filePath) {
    zip.writeZip(result.filePath)
    await systemLogger.info(`Local backup exported to: ${result.filePath}`)
    return true
  }
  return false
}

/**
 * 导入本地备份
 */
export async function importLocalBackup(): Promise<boolean> {
  const result = await dialog.showOpenDialog({
    title: i18next.t('localBackup.import.title'),
    filters: [
      { name: 'ZIP Files', extensions: ['zip'] },
      { name: 'All Files', extensions: ['*'] }
    ],
    properties: ['openFile']
  })

  if (!result.canceled && result.filePaths.length > 0) {
    const filePath = result.filePaths[0]
    if ((await stat(filePath)).size > MAX_BACKUP_ARCHIVE_BYTES) {
      throw new Error('Backup archive exceeds 64 MiB')
    }
    const zip = new AdmZip(filePath)
    await enqueueBackupRestore(zip)
    await systemLogger.info(`Local backup imported from: ${filePath}`)
    return true
  }
  return false
}
