import { existsSync, readFileSync } from 'fs'
import { tmpdir } from 'os'
import { dirname, join } from 'path'
import { beforeEach, describe, expect, it, vi } from 'vitest'

interface XmlObservation {
  taskFilePath: string
  existedDuringCall: boolean
  content: string
}

const REAL_EXE = 'C:\\Program Files\\AikoBox\\AikoBox.exe'

function registeredTaskXml(command: string): Buffer {
  return Buffer.from(
    `\ufeff<?xml version="1.0" encoding="UTF-16"?>\n<Task><Actions Context="Author"><Exec><Command>"${command}"</Command></Exec></Actions></Task>`,
    'utf16le'
  )
}

const mocks = vi.hoisted(() => ({
  isAdmin: false,
  failSchtasks: false,
  // 注册成功后 schtasks /query /xml 读回来的 <Command>；null = 任务不存在
  registeredCommand: 'C:\\Program Files\\AikoBox\\AikoBox.exe' as string | null,
  execCommands: [] as string[],
  execFileCalls: [] as string[][],
  observations: [] as XmlObservation[]
}))

vi.mock('child_process', () => ({
  exec: (command: string, callback: (e: unknown, r: unknown) => void) => {
    mocks.execCommands.push(command)
    const match = /'\/xml', '([^']+)'|\/xml "([^"]+)"/.exec(command)
    if (match) {
      const taskFilePath = match[1] ?? match[2]
      mocks.observations.push({
        taskFilePath,
        existedDuringCall: existsSync(taskFilePath),
        content: existsSync(taskFilePath) ? readFileSync(taskFilePath, 'utf16le') : ''
      })
      if (mocks.failSchtasks) {
        callback(new Error('schtasks refused'), null)
        return
      }
    }
    callback(null, { stdout: 'aikobox', stderr: '' })
  },
  execFile: (
    file: string,
    args: string[],
    optionsOrCallback: unknown,
    maybeCallback?: (e: unknown, r: unknown) => void
  ) => {
    mocks.execFileCalls.push([file, ...args])
    const callback = (maybeCallback ?? optionsOrCallback) as (e: unknown, r: unknown) => void
    if (file === 'schtasks' && args[0] === '/query') {
      if (mocks.registeredCommand === null) {
        callback(new Error('ERROR: The system cannot find the file specified.'), null)
        return
      }
      callback(null, { stdout: registeredTaskXml(mocks.registeredCommand), stderr: '' })
      return
    }
    callback(null, { stdout: '', stderr: '' })
  }
}))
vi.mock('../utils/dirs', () => ({
  exePath: () => 'C:\\Program Files\\AikoBox\\AikoBox.exe',
  homeDir: 'C:\\Users\\tester'
}))
vi.mock('../utils/logger', () => ({
  managerLogger: { info: vi.fn(), warn: vi.fn(), error: vi.fn() }
}))
vi.mock('../core/admin', () => ({ checkAdminPrivileges: async () => mocks.isAdmin }))

describe.skipIf(process.platform !== 'win32')('windows auto-run scheduled task xml', () => {
  beforeEach(() => {
    vi.resetModules()
    mocks.isAdmin = false
    mocks.failSchtasks = false
    mocks.registeredCommand = REAL_EXE
    mocks.execCommands.length = 0
    mocks.execFileCalls.length = 0
    mocks.observations.length = 0
  })

  // 非管理员分支才是漏洞现场：schtasks 在 UAC 之后以管理员身份读回这个文件
  it('never writes the elevated task xml to the predictable temp path', async () => {
    const { enableAutoRun } = await import('./autoRun')
    await enableAutoRun()

    expect(mocks.observations).toHaveLength(1)
    const [observed] = mocks.observations
    expect(observed.taskFilePath).not.toBe(join(tmpdir(), 'aikobox.xml'))
    expect(observed.existedDuringCall).toBe(true)
    expect(dirname(observed.taskFilePath)).toMatch(/aikobox-task-[0-9a-f]{32}$/)
  })

  it('restricts the directory acl before the xml lands in it', async () => {
    mocks.isAdmin = true
    const { enableAutoRun } = await import('./autoRun')
    await enableAutoRun()

    const icacls = mocks.execFileCalls.find((call) => call[0] === 'icacls')
    expect(icacls).toBeDefined()
    expect(icacls?.[1]).toBe(dirname(mocks.observations[0].taskFilePath))
    expect(icacls).toContain('/inheritance:r')
  })

  it('writes utf-16le with a bom and the requested run level', async () => {
    mocks.isAdmin = true
    const { enableAutoRun } = await import('./autoRun')
    await enableAutoRun()

    const { content } = mocks.observations[0]
    expect(content.charCodeAt(0)).toBe(0xfeff)
    expect(content).toContain('<RunLevel>HighestAvailable</RunLevel>')
    expect(content).toContain('<Command>"C:\\Program Files\\AikoBox\\AikoBox.exe"</Command>')
  })

  it('removes the directory afterwards, including when schtasks fails', async () => {
    mocks.isAdmin = true
    const { enableAutoRun } = await import('./autoRun')
    await enableAutoRun()
    expect(existsSync(dirname(mocks.observations[0].taskFilePath))).toBe(false)

    mocks.failSchtasks = true
    mocks.observations.length = 0
    await enableAutoRun()
    expect(existsSync(dirname(mocks.observations[0].taskFilePath))).toBe(false)
  })

  it('uses a fresh unpredictable directory on every call', async () => {
    mocks.isAdmin = true
    const { enableAutoRun } = await import('./autoRun')
    await enableAutoRun()
    await enableAutoRun()

    expect(mocks.observations).toHaveLength(2)
    expect(mocks.observations[0].taskFilePath).not.toBe(mocks.observations[1].taskFilePath)
  })

  // 目录 ACL 拦不住同用户攻击者（属主就是他），所以真正的闸门是创建后的回读核对
  it('deletes a logon task whose command was swapped, and falls back to the registry', async () => {
    mocks.registeredCommand = 'C:\\Users\\me\\AppData\\Local\\Temp\\evil.exe'
    const { enableAutoRun } = await import('./autoRun')
    await enableAutoRun()

    expect(mocks.execCommands.some((c) => c.includes("'/delete'"))).toBe(true)
    const regAdd = mocks.execFileCalls.find((call) => call[0] === 'reg' && call[1] === 'add')
    expect(regAdd).toBeDefined()
    expect(regAdd).toContain(`"${REAL_EXE}"`)
  })

  it('keeps a task that still points at our own executable', async () => {
    const { enableAutoRun } = await import('./autoRun')
    await enableAutoRun()

    expect(mocks.execCommands.some((c) => c.includes("'/delete'"))).toBe(false)
    expect(mocks.execFileCalls.some((call) => call[0] === 'reg' && call[1] === 'add')).toBe(false)
  })

  it('falls back to the registry without a delete when no task was created', async () => {
    mocks.registeredCommand = null
    const { enableAutoRun } = await import('./autoRun')
    await enableAutoRun()

    expect(mocks.execCommands.some((c) => c.includes("'/delete'"))).toBe(false)
    expect(mocks.execFileCalls.some((call) => call[0] === 'reg' && call[1] === 'add')).toBe(true)
  })
})

describe('scheduled task command verification', () => {
  it('accepts only a single unmodified Command and no Arguments', async () => {
    const { scheduledTaskXmlMatchesExe } = await import('./autoRun')
    const exe = 'C:\\Program Files\\AikoBox\\AikoBox.exe'

    expect(scheduledTaskXmlMatchesExe(`<Command>"${exe}"</Command>`, exe)).toBe(true)
    expect(scheduledTaskXmlMatchesExe(`<Command>${exe}</Command>`, exe)).toBe(true)
    expect(scheduledTaskXmlMatchesExe(`<Command>  "${exe}"  </Command>`, exe)).toBe(true)

    expect(scheduledTaskXmlMatchesExe('<Command>"C:\\evil.exe"</Command>', exe)).toBe(false)
    expect(
      scheduledTaskXmlMatchesExe(
        `<Command>"${exe}"</Command><Arguments>--run C:\\evil.ps1</Arguments>`,
        exe
      )
    ).toBe(false)
    expect(
      scheduledTaskXmlMatchesExe(
        `<Command>"${exe}"</Command><Command>"C:\\evil.exe"</Command>`,
        exe
      )
    ).toBe(false)
    expect(scheduledTaskXmlMatchesExe('<Task/>', exe)).toBe(false)
  })

  it('compares the decoded command, so entity-escaped paths still match', async () => {
    const { scheduledTaskXmlMatchesExe } = await import('./autoRun')
    const exe = 'C:\\Games & Apps\\AikoBox.exe'
    expect(
      scheduledTaskXmlMatchesExe('<Command>"C:\\Games &amp; Apps\\AikoBox.exe"</Command>', exe)
    ).toBe(true)
  })
})
