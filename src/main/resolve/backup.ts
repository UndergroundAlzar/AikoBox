import https from 'https'
import os from 'os'
import path from 'path'
import type { Readable } from 'stream'
import { existsSync } from 'fs'
import { stat } from 'fs/promises'
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
  pluginConfigPath,
  profileConfigPath,
  profilesDir,
  rulesDir,
  subStoreDir,
  themesDir
} from '../utils/dirs'
import { getAppConfig } from '../config'

let backupCronJob: Cron | null = null

// createBackupZip 产出的完整清单。恢复时按这份清单逐条比对，别的一律拒绝。
const BACKUP_FILE_ENTRIES = [
  'config.yaml',
  'mihomo.yaml',
  'profile.yaml',
  'override.yaml',
  'plugin.yaml'
]
// plugin-vault 不在清单里：那些 .bin 是 safeStorage(DPAPI) 包着的设备私钥。
// createBackupZip 会被 cron 无人值守地上传到用户自建的 WebDAV（还允许关证书校验），
// 密钥材料不能就这么定时离开本机；何况 DPAPI 密文换台机器/换个账户也解不开，
// 恢复回来照样走 needs-reauth，收益近似为零。同时也别让构造出来的归档覆盖它。
const BACKUP_DIR_ENTRIES = ['themes', 'profiles', 'override', 'rules', 'substore']
const MAX_BACKUP_ARCHIVE_BYTES = 64 * 1024 * 1024
const MAX_BACKUP_EXPANDED_BYTES = 256 * 1024 * 1024

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

// 渲染进程给的文件名会被拼进远端 WebDAV 路径，先挡掉分隔符和遍历
export function assertSafeBackupFilename(filename: unknown): string {
  if (
    typeof filename !== 'string' ||
    filename === '' ||
    filename.length > 255 ||
    filename !== path.posix.basename(filename) ||
    filename !== path.win32.basename(filename) ||
    filename.startsWith('.') ||
    // eslint-disable-next-line no-control-regex
    /[\u0000-\u001f\\/:*?"<>|]/.test(filename) ||
    !filename.toLowerCase().endsWith('.zip')
  ) {
    throw new Error('Invalid backup filename')
  }
  return filename
}

export function assertSafeBackupEntry(
  entry: Pick<AdmZip.IZipEntry, 'entryName' | 'isDirectory'>
): void {
  const raw = entry.entryName
  const name = entry.isDirectory && raw.endsWith('/') ? raw.slice(0, -1) : raw
  const segments = name.split('/')
  if (
    name === '' ||
    raw.includes('\\') ||
    raw.startsWith('/') ||
    /^[A-Za-z]:/.test(raw) ||
    // eslint-disable-next-line no-control-regex
    /[\u0000-\u001f]/.test(raw) ||
    segments.some((segment) => segment === '' || segment === '.' || segment === '..')
  ) {
    throw new Error(`Unsafe backup archive entry: ${raw}`)
  }

  const allowed =
    entry.isDirectory || segments.length > 1
      ? BACKUP_DIR_ENTRIES.includes(segments[0])
      : BACKUP_FILE_ENTRIES.includes(segments[0])
  if (!allowed) {
    throw new Error(`Unexpected backup archive entry: ${raw}`)
  }
}

// 先整包校验再落盘：备份包可能来自被 MITM 的 WebDAV（webdavIgnoreCert 会关掉证书校验），
// 一旦写下去就等于让对方替换掉用户的整套代理配置。
function extractBackupZip(zip: AdmZip): void {
  let total = 0
  for (const entry of zip.getEntries()) {
    assertSafeBackupEntry(entry)
    if (entry.isDirectory) continue
    total += entry.header.size
    if (total > MAX_BACKUP_EXPANDED_BYTES) throw new Error('Expanded backup exceeds 256 MiB')
  }
  zip.extractAllTo(dataDir(), true)
}

function createBackupZip(): AdmZip {
  const zip = new AdmZip()

  const files = [
    appConfigPath(),
    controledMihomoConfigPath(),
    profileConfigPath(),
    overrideConfigPath(),
    pluginConfigPath()
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
      zip.addLocalFile(file)
    }
  }

  for (const { path, name } of folders) {
    if (existsSync(path)) {
      zip.addLocalFolder(path, name)
    }
  }

  return zip
}

export async function webdavBackup(): Promise<boolean> {
  const { client, webdavDir, webdavMaxBackups } = await getWebDAVClient()
  const zip = createBackupZip()
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

/**
 * getFileContents 会先把整个响应体读进主进程内存，等到能检查 length 时已经晚了：
 * 一个恶意或被 MITM 的 WebDAV 服务器可以用几 GB 的响应把主进程（同时也是 WinINET
 * 守护者）撑爆。所以这里改成流式读取，一超过上限就立刻掐断连接。
 */
export async function downloadBoundedBuffer(stream: Readable, limit: number): Promise<Buffer> {
  const chunks: Buffer[] = []
  let total = 0
  for await (const chunk of stream) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk as string)
    total += buffer.length
    if (total > limit) {
      stream.destroy(new Error('Backup archive exceeds 64 MiB'))
      throw new Error('Backup archive exceeds 64 MiB')
    }
    chunks.push(buffer)
  }
  return Buffer.concat(chunks)
}

export async function webdavRestore(filename: string): Promise<void> {
  const safeName = assertSafeBackupFilename(filename)
  const { client, webdavDir } = await getWebDAVClient()
  const zipData = await downloadBoundedBuffer(
    client.createReadStream(`${webdavDir}/${safeName}`),
    MAX_BACKUP_ARCHIVE_BYTES
  )
  extractBackupZip(new AdmZip(zipData))
}

export async function listWebdavBackups(): Promise<string[]> {
  const { client, webdavDir } = await getWebDAVClient()
  const files = await client.getDirectoryContents(webdavDir, { glob: '*.zip' })
  return files.map((file) => file.basename)
}

export async function webdavDelete(filename: string): Promise<void> {
  const safeName = assertSafeBackupFilename(filename)
  const { client, webdavDir } = await getWebDAVClient()
  await client.deleteFile(`${webdavDir}/${safeName}`)
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
    extractBackupZip(new AdmZip(filePath))
    await systemLogger.info(`Local backup imported from: ${filePath}`)
    return true
  }
  return false
}
