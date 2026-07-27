import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { Readable } from 'stream'
import AdmZip from 'adm-zip'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { parse } from '../utils/yaml'

const mocks = vi.hoisted(() => ({
  root: '',
  selectedBackup: '',
  appCache: '',
  restartCore: vi.fn(),
  getAppConfig: vi.fn(),
  getControledMihomoConfig: vi.fn(),
  getProfileConfig: vi.fn(),
  getOverrideConfig: vi.fn()
}))

vi.mock('electron', () => ({
  dialog: {
    showOpenDialog: vi.fn(async () => ({
      canceled: false,
      filePaths: [mocks.selectedBackup]
    })),
    showSaveDialog: vi.fn()
  }
}))

vi.mock('../utils/dirs', () => ({
  dataDir: () => mocks.root,
  appConfigPath: () => join(mocks.root, 'config.yaml'),
  controledMihomoConfigPath: () => join(mocks.root, 'mihomo.yaml'),
  profileConfigPath: () => join(mocks.root, 'profiles.yaml'),
  overrideConfigPath: () => join(mocks.root, 'override.yaml'),
  themesDir: () => join(mocks.root, 'themes'),
  profilesDir: () => join(mocks.root, 'profiles'),
  overrideDir: () => join(mocks.root, 'override'),
  rulesDir: () => join(mocks.root, 'rules'),
  subStoreDir: () => join(mocks.root, 'substore')
}))

vi.mock('../config', () => ({
  getAppConfig: mocks.getAppConfig,
  getControledMihomoConfig: mocks.getControledMihomoConfig,
  getProfileConfig: mocks.getProfileConfig,
  getOverrideConfig: mocks.getOverrideConfig
}))

vi.mock('../core/manager', () => ({ restartCore: mocks.restartCore }))
vi.mock('../utils/logger', () => ({
  systemLogger: {
    info: vi.fn(),
    error: vi.fn()
  }
}))

function writeBackup(contents: Record<string, string>): string {
  const zip = new AdmZip()
  for (const [name, content] of Object.entries(contents)) {
    zip.addFile(name, Buffer.from(content))
  }
  const file = join(mocks.root, 'backup.zip')
  zip.writeZip(file)
  return file
}

describe('local backup restore transaction', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.root = mkdtempSync(join(tmpdir(), 'aikobox-backup-'))
    mocks.selectedBackup = ''
    mocks.appCache = 'old'
    writeFileSync(
      join(mocks.root, 'config.yaml'),
      'marker: old\nwebdavPassword: current-secret\ngithubToken: current-token\n'
    )
    writeFileSync(join(mocks.root, 'mihomo.yaml'), 'mode: old\n')
    writeFileSync(join(mocks.root, 'profiles.yaml'), 'current: old\nitems: []\n')
    writeFileSync(join(mocks.root, 'override.yaml'), 'items: []\n')
    mkdirSync(join(mocks.root, 'profiles'))
    writeFileSync(join(mocks.root, 'profiles', 'old.yaml'), 'old')
    mkdirSync(join(mocks.root, 'substore'))
    writeFileSync(
      join(mocks.root, 'substore', 'cache.yaml'),
      'url: https://secret.example/?token=old'
    )

    mocks.getAppConfig.mockImplementation(async (force?: boolean) => {
      if (force) {
        mocks.appCache = readFileSync(join(mocks.root, 'config.yaml'), 'utf8').match(
          /marker:\s*(\w+)/
        )?.[1] as string
      }
      return { marker: mocks.appCache }
    })
    mocks.getControledMihomoConfig.mockResolvedValue({})
    mocks.getProfileConfig.mockResolvedValue({ items: [] })
    mocks.getOverrideConfig.mockResolvedValue({ items: [] })
    mocks.restartCore.mockResolvedValue(undefined)
  })

  afterEach(() => {
    rmSync(mocks.root, { recursive: true, force: true })
  })

  it('refreshes every config cache before restarting the core', async () => {
    mocks.selectedBackup = writeBackup({
      'config.yaml': 'marker: restored\n',
      'mihomo.yaml': 'mode: restored\n',
      'profiles.yaml': 'current: restored\nitems: []\n',
      'override.yaml': 'items: []\n',
      'profiles/restored.yaml': 'restored'
    })

    const { importLocalBackup } = await import('./backup')
    await expect(importLocalBackup()).resolves.toBe(true)

    expect(mocks.getAppConfig).toHaveBeenCalledWith(true)
    expect(mocks.getControledMihomoConfig).toHaveBeenCalledWith(true)
    expect(mocks.getProfileConfig).toHaveBeenCalledWith(true)
    expect(mocks.getOverrideConfig).toHaveBeenCalledWith(true)
    expect(mocks.restartCore).toHaveBeenCalledOnce()
    expect(mocks.appCache).toBe('restored')
    expect(readFileSync(join(mocks.root, 'config.yaml'), 'utf8')).toContain('restored')
    expect(readFileSync(join(mocks.root, 'profiles', 'restored.yaml'), 'utf8')).toBe('restored')
    expect(() => readFileSync(join(mocks.root, 'profiles', 'old.yaml'))).toThrow()
  })

  it('rolls disk and caches back when the restored core cannot start', async () => {
    mocks.selectedBackup = writeBackup({
      'config.yaml': 'marker: restored\n',
      'profiles/restored.yaml': 'restored'
    })
    mocks.restartCore
      .mockRejectedValueOnce(new Error('restored core rejected config'))
      .mockResolvedValueOnce(undefined)

    const { importLocalBackup } = await import('./backup')
    await expect(importLocalBackup()).rejects.toThrow('restored core rejected config')

    expect(readFileSync(join(mocks.root, 'config.yaml'), 'utf8')).toContain('old')
    expect(readFileSync(join(mocks.root, 'profiles', 'old.yaml'), 'utf8')).toBe('old')
    expect(() => readFileSync(join(mocks.root, 'profiles', 'restored.yaml'))).toThrow()
    expect(mocks.appCache).toBe('old')
    expect(mocks.getAppConfig).toHaveBeenCalledTimes(2)
    expect(mocks.restartCore).toHaveBeenCalledTimes(2)
  })

  it('rolls back before starting a core when restored cache validation fails', async () => {
    mocks.selectedBackup = writeBackup({
      'config.yaml': 'marker: restored\n',
      'profiles.yaml': 'current: restored\nitems: []\n'
    })
    mocks.getProfileConfig
      .mockRejectedValueOnce(new Error('restored profile config is invalid'))
      .mockResolvedValueOnce({ items: [] })

    const { importLocalBackup } = await import('./backup')
    await expect(importLocalBackup()).rejects.toThrow('restored profile config is invalid')

    expect(readFileSync(join(mocks.root, 'config.yaml'), 'utf8')).toContain('old')
    expect(mocks.appCache).toBe('old')
    expect(mocks.getAppConfig).toHaveBeenCalledTimes(2)
    expect(mocks.restartCore).toHaveBeenCalledOnce()
  })

  it('rejects unsupported archive entries before changing live data', async () => {
    mocks.selectedBackup = writeBackup({
      'config.yaml': 'marker: restored\n',
      'unexpected.txt': 'not managed by backup restore'
    })

    const { importLocalBackup } = await import('./backup')
    await expect(importLocalBackup()).rejects.toThrow('Unsupported backup entry')

    expect(readFileSync(join(mocks.root, 'config.yaml'), 'utf8')).toContain('old')
    expect(mocks.getAppConfig).not.toHaveBeenCalled()
    expect(mocks.restartCore).not.toHaveBeenCalled()
  })

  it('rejects descendants below entries that must be regular files', async () => {
    mocks.selectedBackup = writeBackup({
      'config.yaml/child': 'not a config file'
    })

    const { importLocalBackup } = await import('./backup')
    await expect(importLocalBackup()).rejects.toThrow('Unsafe backup entry')
    expect(mocks.getAppConfig).not.toHaveBeenCalled()
    expect(mocks.restartCore).not.toHaveBeenCalled()
  })

  it('omits all sensitive profile storage from remote backup archives', async () => {
    writeFileSync(
      join(mocks.root, 'profiles.yaml'),
      [
        'current: secret-profile',
        'items:',
        '  - id: secret-profile',
        '    url: https://subscription.example/path?token=query-secret',
        '    authToken: bearer-secret',
        '    ageSecretKey: AGE-SECRET-KEY-1TEST'
      ].join('\n')
    )
    writeFileSync(
      join(mocks.root, 'profiles', 'secret-profile.yaml'),
      'proxies:\n  - name: private\n    password: node-password\n'
    )

    const { createBackupZip } = await import('./backup')
    const zip = createBackupZip({ omitAppConfigSecrets: true })
    const config = parse(zip.getEntry('config.yaml')?.getData().toString('utf8') || '') as Record<
      string,
      unknown
    >
    const metadata = JSON.parse(
      zip.getEntry('backup-metadata.json')?.getData().toString('utf8') || '{}'
    ) as { omittedAppConfigKeys?: string[]; omittedBackupEntries?: string[] }

    expect(config.webdavPassword).toBeUndefined()
    expect(config.githubToken).toBeUndefined()
    expect(zip.getEntry('profiles.yaml')).toBeNull()
    expect(zip.getEntries().some((entry) => entry.entryName.startsWith('profiles/'))).toBe(false)
    expect(zip.getEntries().some((entry) => entry.entryName.startsWith('substore/'))).toBe(false)
    expect(metadata.omittedAppConfigKeys).toEqual(
      expect.arrayContaining(['webdavPassword', 'githubToken', 'gistAgeSecretKey'])
    )
    expect(metadata.omittedBackupEntries).toEqual(['profiles.yaml', 'profiles', 'substore'])
  })

  it('preserves current local secrets when restoring a redacted remote backup', async () => {
    mocks.selectedBackup = writeBackup({
      'backup-metadata.json': JSON.stringify({
        version: 1,
        omittedAppConfigKeys: ['webdavPassword', 'githubToken'],
        omittedBackupEntries: ['profiles.yaml', 'profiles', 'substore']
      }),
      'config.yaml': 'marker: restored\n',
      'profiles.yaml':
        'current: remote\nitems:\n  - id: remote\n    authToken: leaked-remote-token\n',
      'profiles/remote.yaml': 'proxies:\n  - password: leaked-remote-password\n',
      'substore/cache.yaml': 'url: https://remote.example/?token=leaked\n'
    })

    const { importLocalBackup } = await import('./backup')
    await expect(importLocalBackup()).resolves.toBe(true)

    const restored = parse(readFileSync(join(mocks.root, 'config.yaml'), 'utf8')) as Record<
      string,
      unknown
    >
    expect(restored.marker).toBe('restored')
    expect(restored.webdavPassword).toBe('current-secret')
    expect(restored.githubToken).toBe('current-token')
    expect(readFileSync(join(mocks.root, 'profiles.yaml'), 'utf8')).toContain('current: old')
    expect(readFileSync(join(mocks.root, 'profiles', 'old.yaml'), 'utf8')).toBe('old')
    expect(() => readFileSync(join(mocks.root, 'profiles', 'remote.yaml'))).toThrow()
    expect(readFileSync(join(mocks.root, 'substore', 'cache.yaml'), 'utf8')).toContain('token=old')
  })

  it('holds concurrent profile writes until a failed restore has fully rolled back', async () => {
    mocks.selectedBackup = writeBackup({
      'config.yaml': 'marker: restored\n',
      'profiles.yaml': 'current: restored\nitems: []\n',
      'profiles/restored.yaml': 'restored'
    })

    let rejectRestoredCore!: (error: Error) => void
    const restoredCore = new Promise<void>((_, reject) => {
      rejectRestoredCore = reject
    })
    mocks.restartCore.mockReturnValueOnce(restoredCore).mockResolvedValueOnce(undefined)

    const { importLocalBackup } = await import('./backup')
    const { runProfileStorageTransaction } = await import('../config/profileStorageTransaction')
    const restore = importLocalBackup()

    await vi.waitFor(() => expect(mocks.restartCore).toHaveBeenCalledTimes(1))

    let concurrentWriteStarted = false
    const concurrentWrite = runProfileStorageTransaction(async () => {
      concurrentWriteStarted = true
      writeFileSync(join(mocks.root, 'profiles.yaml'), 'current: concurrent\nitems: []\n')
      writeFileSync(join(mocks.root, 'profiles', 'concurrent.yaml'), 'concurrent')
    })

    await Promise.resolve()
    expect(concurrentWriteStarted).toBe(false)

    rejectRestoredCore(new Error('restored core rejected config'))
    await expect(restore).rejects.toThrow('restored core rejected config')
    await concurrentWrite

    expect(readFileSync(join(mocks.root, 'profiles.yaml'), 'utf8')).toContain('current: concurrent')
    expect(readFileSync(join(mocks.root, 'profiles', 'concurrent.yaml'), 'utf8')).toBe('concurrent')
    expect(() => readFileSync(join(mocks.root, 'profiles', 'restored.yaml'))).toThrow()
  })

  it('rejects WebDAV path traversal filenames', async () => {
    const { assertWebdavBackupFilename } = await import('./backup')
    expect(assertWebdavBackupFilename('aikobox-backup-2026-07-27.zip')).toBe(
      'aikobox-backup-2026-07-27.zip'
    )
    expect(() => assertWebdavBackupFilename('../outside.zip')).toThrow(
      'Invalid WebDAV backup filename'
    )
    expect(() => assertWebdavBackupFilename('folder/backup.zip')).toThrow(
      'Invalid WebDAV backup filename'
    )
    expect(() => assertWebdavBackupFilename('backup%2foutside.zip')).toThrow(
      'Invalid WebDAV backup filename'
    )
  })
})

describe('bounded WebDAV backup download', () => {
  it('stops reading as soon as the configured limit is exceeded', async () => {
    const { downloadBoundedBuffer } = await import('./backup')
    const stream = Readable.from([Buffer.alloc(4), Buffer.alloc(5)])
    await expect(downloadBoundedBuffer(stream, 8)).rejects.toThrow('Backup archive exceeds 64 MiB')
  })

  it('returns the complete buffer when it remains within the limit', async () => {
    const { downloadBoundedBuffer } = await import('./backup')
    const stream = Readable.from([Buffer.from('safe'), Buffer.from('-backup')])
    await expect(downloadBoundedBuffer(stream, 32)).resolves.toEqual(Buffer.from('safe-backup'))
  })
})
