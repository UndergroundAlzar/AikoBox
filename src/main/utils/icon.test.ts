/* eslint-disable import/order -- Vitest mocks must be installed before loading the module under test. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  exec: vi.fn(),
  execFile: vi.fn(),
  execSync: vi.fn(),
  spawn: vi.fn(),
  spawnSync: vi.fn(),
  existsSync: vi.fn((_p: string) => true),
  readdirSync: vi.fn((_p: string) => ['other.desktop'] as string[]),
  readFileSync: vi.fn((_p: string) => 'Name=abc\n'),
  lstatSync: vi.fn((_p: string) => ({ isFile: () => true })),
  symlinkSync: vi.fn((_target: string, _link: string, _type?: string) => {}),
  linkSync: vi.fn((_target: string, _link: string) => {}),
  unlinkSync: vi.fn((_p: string) => {}),
  getIcon: vi.fn((_p: string, cb: (b64d: string) => void) =>
    cb(Buffer.from('icon-bytes').toString('base64'))
  )
}))

vi.mock('child_process', () => ({
  exec: mocks.exec,
  execFile: mocks.execFile,
  execSync: mocks.execSync,
  spawn: mocks.spawn,
  spawnSync: mocks.spawnSync
}))
vi.mock('file-icon-info', () => ({ getIcon: mocks.getIcon }))
vi.mock('electron', () => ({ app: { getPath: () => 'C:\\AikoBox\\AikoBox.exe' } }))
vi.mock('fs', () => {
  const api = {
    existsSync: mocks.existsSync,
    readdirSync: mocks.readdirSync,
    readFileSync: mocks.readFileSync,
    lstatSync: mocks.lstatSync,
    symlinkSync: mocks.symlinkSync,
    linkSync: mocks.linkSync,
    unlinkSync: mocks.unlinkSync
  }
  return { ...api, default: api }
})

import { escapeRegExp, getIconDataURL } from './icon'
import { darwinDefaultIcon, windowsDefaultIcon } from './defaultIcon'

// A legal Windows filename: CJK selects the alias path, `&` is a cmd.exe
// command separator.
const injectedPath = 'C:\\Users\\me\\下载&calc.exe'

function setPlatform(platform: NodeJS.Platform): void {
  Object.defineProperty(process, 'platform', { value: platform, configurable: true })
}

const realPlatform = process.platform

describe('getIconDataURL on Windows', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.existsSync.mockReturnValue(true)
    mocks.lstatSync.mockImplementation(() => ({ isFile: () => true }))
    mocks.symlinkSync.mockImplementation(() => {})
    mocks.getIcon.mockImplementation((_p, cb) => cb(Buffer.from('icon-bytes').toString('base64')))
    setPlatform('win32')
  })

  afterEach(() => {
    setPlatform(realPlatform)
  })

  it('never hands a core-reported path to a shell', async () => {
    const dataURL = await getIconDataURL(injectedPath)

    expect(dataURL).toBe(`data:image/png;base64,${Buffer.from('icon-bytes').toString('base64')}`)
    expect(mocks.exec).not.toHaveBeenCalled()
    expect(mocks.execFile).not.toHaveBeenCalled()
    expect(mocks.execSync).not.toHaveBeenCalled()
    expect(mocks.spawn).not.toHaveBeenCalled()
    expect(mocks.spawnSync).not.toHaveBeenCalled()
  })

  it('aliases a CJK path through fs and resolves the icon from the alias', async () => {
    await getIconDataURL(injectedPath)

    expect(mocks.symlinkSync).toHaveBeenCalledOnce()
    const [target, link, type] = mocks.symlinkSync.mock.calls[0]
    expect(target).toBe(injectedPath)
    expect(type).toBe('file')
    expect(link).toMatch(/[\\/][0-9a-f]{16}\.exe$/)
    expect(mocks.getIcon.mock.calls[0][0]).toBe(link)
    expect(mocks.unlinkSync).toHaveBeenCalledWith(link)
  })

  it('falls back to a hard link when symlink creation is not permitted', async () => {
    mocks.symlinkSync.mockImplementation(() => {
      throw new Error('EPERM')
    })

    await getIconDataURL(injectedPath)

    expect(mocks.linkSync).toHaveBeenCalledOnce()
    expect(mocks.getIcon.mock.calls[0][0]).toBe(mocks.linkSync.mock.calls[0][1])
  })

  it('uses the original path when no alias can be created', async () => {
    mocks.symlinkSync.mockImplementation(() => {
      throw new Error('EPERM')
    })
    mocks.linkSync.mockImplementation(() => {
      throw new Error('EXDEV')
    })
    mocks.existsSync.mockImplementation((p: string) => p === injectedPath)

    await getIconDataURL(injectedPath)

    expect(mocks.getIcon.mock.calls[0][0]).toBe(injectedPath)
  })

  it('refuses to link anything that is not an absolute plain file', async () => {
    // getIconDataURL is registered raw on the IPC table, so this string can come
    // straight from the renderer. It must not steer symlinkSync/linkSync.
    mocks.lstatSync.mockImplementation(() => ({ isFile: () => false }))
    await getIconDataURL(injectedPath)
    expect(mocks.symlinkSync).not.toHaveBeenCalled()
    expect(mocks.linkSync).not.toHaveBeenCalled()

    mocks.lstatSync.mockImplementation(() => ({ isFile: () => true }))
    await getIconDataURL('下载&calc.exe')
    expect(mocks.symlinkSync).not.toHaveBeenCalled()
    expect(mocks.linkSync).not.toHaveBeenCalled()
  })

  it('skips the alias entirely for ASCII paths', async () => {
    await getIconDataURL('C:\\Windows\\explorer.exe')

    expect(mocks.symlinkSync).not.toHaveBeenCalled()
    expect(mocks.linkSync).not.toHaveBeenCalled()
    expect(mocks.getIcon.mock.calls[0][0]).toBe('C:\\Windows\\explorer.exe')
  })

  it('returns the default icon for non-executable or missing paths', async () => {
    expect(await getIconDataURL('C:\\Users\\me\\notes.txt')).toBe(windowsDefaultIcon)
    mocks.existsSync.mockReturnValue(false)
    expect(await getIconDataURL('C:\\Users\\me\\gone.exe')).toBe(windowsDefaultIcon)
  })
})

describe('desktop entry matching on Linux', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.existsSync.mockReturnValue(true)
    mocks.readdirSync.mockReturnValue(['other.desktop'])
    mocks.readFileSync.mockReturnValue('Name=abc\n')
    setPlatform('linux')
  })

  afterEach(() => {
    setPlatform(realPlatform)
  })

  it('does not let a path metacharacter widen the Name match', async () => {
    // Unescaped, `a.c` matches `Name=abc` and the wrong desktop entry wins.
    expect(await getIconDataURL('a.c')).toBe(darwinDefaultIcon)
  })
})

describe('escapeRegExp', () => {
  it('makes a path match only itself', () => {
    expect(new RegExp(`^${escapeRegExp('C:\\a+b(.*)')}$`).test('C:\\a+b(.*)')).toBe(true)
    expect(new RegExp(`^${escapeRegExp('a.c')}$`).test('abc')).toBe(false)
    expect(() => new RegExp(escapeRegExp('C:\\bad(['))).not.toThrow()
  })
})
