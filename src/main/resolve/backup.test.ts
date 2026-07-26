import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { Readable } from 'stream'
import AdmZip from 'adm-zip'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  root: '',
  savePath: '',
  openPaths: [] as string[]
}))

vi.mock('electron', () => ({
  dialog: {
    showSaveDialog: async () => ({ canceled: false, filePath: mocks.savePath }),
    showOpenDialog: async () => ({ canceled: false, filePaths: mocks.openPaths })
  }
}))
vi.mock('i18next', () => ({ default: { t: (key: string) => key } }))
vi.mock('../utils/logger', () => ({
  systemLogger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() }
}))
vi.mock('../config', () => ({ getAppConfig: vi.fn(async () => ({})) }))
vi.mock('../utils/dirs', () => ({
  dataDir: () => mocks.root,
  appConfigPath: () => join(mocks.root, 'config.yaml'),
  controledMihomoConfigPath: () => join(mocks.root, 'mihomo.yaml'),
  profileConfigPath: () => join(mocks.root, 'profile.yaml'),
  overrideConfigPath: () => join(mocks.root, 'override.yaml'),
  pluginConfigPath: () => join(mocks.root, 'plugin.yaml'),
  pluginVaultDir: () => join(mocks.root, 'plugin-vault'),
  overrideDir: () => join(mocks.root, 'override'),
  profilesDir: () => join(mocks.root, 'profiles'),
  rulesDir: () => join(mocks.root, 'rules'),
  subStoreDir: () => join(mocks.root, 'substore'),
  themesDir: () => join(mocks.root, 'themes')
}))

let workspace = ''

function seedDataDir(): void {
  for (const name of ['config.yaml', 'mihomo.yaml', 'profile.yaml', 'override.yaml', 'plugin.yaml'])
    writeFileSync(join(mocks.root, name), `${name}\n`)
  for (const dir of ['themes', 'profiles', 'override', 'rules', 'substore', 'plugin-vault'])
    mkdirSync(join(mocks.root, dir))
  writeFileSync(join(mocks.root, 'profiles', 'a.yaml'), 'proxies: []\n')
  writeFileSync(join(mocks.root, 'plugin-vault', 'a.bin'), 'secret')
}

describe('backup archive safety', () => {
  beforeEach(() => {
    vi.resetModules()
    workspace = mkdtempSync(join(tmpdir(), 'aikobox-backup-'))
    mocks.root = join(workspace, 'data')
    mkdirSync(mocks.root)
    mocks.savePath = join(workspace, 'backup.zip')
    mocks.openPaths = []
    seedDataDir()
  })

  afterEach(() => rmSync(workspace, { recursive: true, force: true }))

  it('rejects renderer filenames that could escape the webdav directory', async () => {
    const { webdavDelete, webdavRestore } = await import('./backup')
    for (const name of [
      '../other/backup.zip',
      '..\\other\\backup.zip',
      '/etc/backup.zip',
      'C:\\backup.zip',
      'sub/backup.zip',
      '.hidden.zip',
      'backup.txt',
      ''
    ]) {
      await expect(webdavRestore(name)).rejects.toThrow('Invalid backup filename')
      await expect(webdavDelete(name)).rejects.toThrow('Invalid backup filename')
    }
  })

  it('accepts the filenames webdavBackup actually produces', async () => {
    const { assertSafeBackupFilename } = await import('./backup')
    for (const name of ['win32_my-pc_2026-07-26_10-00-00.zip', 'aikobox-backup-2026-07-26.zip'])
      expect(assertSafeBackupFilename(name)).toBe(name)
  })

  it('rejects archive entries outside the allowlist createBackupZip produces', async () => {
    const { assertSafeBackupEntry } = await import('./backup')
    for (const entryName of [
      '../evil.yaml',
      'profiles/../../evil.yaml',
      '/etc/passwd',
      'C:/Windows/win.ini',
      'profiles\\..\\evil.yaml',
      'evil.exe',
      'sing-box.json',
      'logs/aikobox.log',
      'work/config.yaml',
      // 设备私钥不进备份，也就不能被构造出来的归档覆盖
      'plugin-vault/a.bin'
    ]) {
      expect(() => assertSafeBackupEntry({ entryName, isDirectory: false })).toThrow(
        /backup archive entry/
      )
    }
  })

  it('accepts every entry createBackupZip emits', async () => {
    const { assertSafeBackupEntry } = await import('./backup')
    for (const entryName of [
      'config.yaml',
      'mihomo.yaml',
      'profile.yaml',
      'override.yaml',
      'plugin.yaml',
      'profiles/a.yaml',
      'themes/nested/deep.css'
    ]) {
      expect(() => assertSafeBackupEntry({ entryName, isDirectory: false })).not.toThrow()
    }
    expect(() => assertSafeBackupEntry({ entryName: 'profiles/', isDirectory: true })).not.toThrow()
  })

  it('never puts the safeStorage plugin vault into an archive', async () => {
    const { exportLocalBackup } = await import('./backup')
    expect(await exportLocalBackup()).toBe(true)

    const names = new AdmZip(mocks.savePath).getEntries().map((entry) => entry.entryName)
    // webdavBackup 由 cron 无人值守地上传，设备私钥不能跟着走
    expect(names.some((name) => name.startsWith('plugin-vault'))).toBe(false)
    expect(names).toContain('plugin.yaml')
    expect(names).toContain('config.yaml')
    expect(names).toContain('profiles/a.yaml')
  })

  it('round-trips its own archive', async () => {
    const { exportLocalBackup, importLocalBackup } = await import('./backup')
    await exportLocalBackup()
    rmSync(join(mocks.root, 'profiles', 'a.yaml'))

    mocks.openPaths = [mocks.savePath]
    expect(await importLocalBackup()).toBe(true)
    expect(readFileSync(join(mocks.root, 'profiles', 'a.yaml'), 'utf8')).toBe('proxies: []\n')
  })

  it('refuses a crafted archive and writes nothing at all', async () => {
    const zip = new AdmZip()
    zip.addFile('config.yaml', Buffer.from('proxies: []\n'))
    zip.addFile('../../evil.txt', Buffer.from('pwned'))
    const craftedPath = join(workspace, 'crafted.zip')
    zip.writeZip(craftedPath)

    const { importLocalBackup } = await import('./backup')
    mocks.openPaths = [craftedPath]
    await expect(importLocalBackup()).rejects.toThrow(/backup archive entry/)
    expect(existsSync(join(workspace, 'evil.txt'))).toBe(false)
    expect(existsSync(join(mocks.root, 'evil.txt'))).toBe(false)
    // config.yaml 排在恶意条目之前：整包校验必须在任何一次落盘之前完成，
    // 所以用户原来的内容必须原样还在，而不只是“文件仍然存在”
    expect(readFileSync(join(mocks.root, 'config.yaml'), 'utf8')).toBe('config.yaml\n')
  })

  it('stops a hostile webdav response before it can exhaust main-process memory', async () => {
    const { downloadBoundedBuffer } = await import('./backup')
    const chunk = Buffer.alloc(64 * 1024, 1)
    let emitted = 0
    const endless = Readable.from(
      (function* () {
        for (;;) {
          emitted += 1
          // 无限流：只有上限生效才会停下来，否则这个测试会一直跑到 OOM
          yield chunk
        }
      })()
    )

    await expect(downloadBoundedBuffer(endless, 256 * 1024)).rejects.toThrow(/exceeds 64 MiB/)
    expect(emitted).toBeLessThan(16)
    expect(endless.destroyed).toBe(true)
  })

  it('returns the whole body when it stays under the cap', async () => {
    const { downloadBoundedBuffer } = await import('./backup')
    const body = await downloadBoundedBuffer(
      Readable.from([Buffer.from('ab'), Buffer.from('c')]),
      8
    )
    expect(body.toString()).toBe('abc')
  })

  it('refuses an archive whose entries are inside the allowlist but unexpected', async () => {
    const zip = new AdmZip()
    zip.addFile('sing-box.json', Buffer.from('{}'))
    const craftedPath = join(workspace, 'unexpected.zip')
    zip.writeZip(craftedPath)

    const { importLocalBackup } = await import('./backup')
    mocks.openPaths = [craftedPath]
    await expect(importLocalBackup()).rejects.toThrow(/Unexpected backup archive entry/)
    expect(existsSync(join(mocks.root, 'sing-box.json'))).toBe(false)
  })
})
