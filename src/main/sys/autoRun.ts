import { tmpdir } from 'os'
import { mkdir, readFile, rm, writeFile } from 'fs/promises'
import { exec, execFile } from 'child_process'
import { randomBytes } from 'crypto'
import { existsSync } from 'fs'
import { promisify } from 'util'
import path from 'path'
import { exePath, homeDir } from '../utils/dirs'
import { managerLogger } from '../utils/logger'
import { checkAdminPrivileges } from '../core/admin'

const appName = 'aikobox'

function quoteForPowerShell(value: string): string {
  return value.replace(/'/g, "''")
}

/**
 * %TEMP%\aikobox.xml 是可预测且同用户可写的：UAC 提示之后 schtasks 才以管理员身份读回它，
 * 中间这段窗口里任何同用户进程都能换掉 <Command>，换来一个 HighestAvailable 的登录任务。
 * 每次换随机目录、收紧 ACL、用完必删，只是把窗口做窄——挡不住同用户攻击者：
 * 目录的属主就是他，OWNER RIGHTS 直接给他完全控制，就算不给，属主也天然保留
 * WRITE_DAC 可以自己改回来。非提权的本应用自己必须能写这个文件，ACL 在原理上
 * 就区分不了“本应用”和“同用户恶意进程”。
 * 真正把这条路封死的是创建之后再把任务读回来核对 <Command>，见
 * verifyScheduledTaskCommand()。
 */
async function withTaskXmlFile<T>(
  xml: string,
  fn: (taskFilePath: string) => Promise<T>
): Promise<T> {
  const dir = path.join(tmpdir(), `${appName}-task-${randomBytes(16).toString('hex')}`)
  await mkdir(dir, { mode: 0o700 })
  try {
    try {
      await promisify(execFile)('icacls', [
        dir,
        '/grant:r',
        '*S-1-3-4:(OI)(CI)F', // OWNER RIGHTS
        '/grant:r',
        '*S-1-5-18:(OI)(CI)F', // SYSTEM
        '/grant:r',
        '*S-1-5-32-544:(OI)(CI)F', // Administrators
        '/inheritance:r'
      ])
    } catch (error) {
      await managerLogger.warn('Failed to restrict task XML directory ACL:', error)
    }
    const taskFilePath = path.join(dir, 'task.xml')
    await writeFile(taskFilePath, Buffer.from(`\ufeff${xml}`, 'utf-16le'), { mode: 0o600 })
    return await fn(taskFilePath)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
}

function decodeXmlEntities(value: string): string {
  return value
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&')
}

/**
 * 只接受“恰好一个 <Command>，内容就是本应用的可执行文件，且没有任何 <Arguments>”。
 * 任何被换掉的 <Command>、被追加的参数、被塞进来的第二个 <Exec>，都算不通过。
 */
export function scheduledTaskXmlMatchesExe(xml: string, expectedExe: string): boolean {
  const commands = [...xml.matchAll(/<Command>([\s\S]*?)<\/Command>/g)].map((m) =>
    decodeXmlEntities(m[1]).trim()
  )
  if (commands.length !== 1) return false
  if (/<Arguments>/.test(xml)) return false
  const command = commands[0].replace(/^"([\s\S]*)"$/, '$1').trim()
  return command.toLowerCase() === expectedExe.trim().toLowerCase()
}

function decodeSchtasksOutput(stdout: Buffer | string): string {
  if (typeof stdout === 'string') return stdout
  // schtasks /xml 在重定向时写 UTF-16LE（带 BOM）
  if (stdout.length >= 2 && stdout[0] === 0xff && stdout[1] === 0xfe) {
    return stdout.subarray(2).toString('utf16le')
  }
  return stdout.toString('utf8')
}

/**
 * 创建之后再读回来核对。这是整条路径上唯一一个同用户攻击者动不了的环节：
 * 任务本身存在 %SystemRoot%\System32\Tasks 下，改它需要管理员权限。
 */
async function verifyScheduledTaskCommand(): Promise<'ours' | 'foreign' | 'missing'> {
  try {
    const { stdout } = await promisify(execFile)(
      'schtasks',
      ['/query', '/tn', appName, '/xml', 'ONE'],
      { windowsHide: true, encoding: 'buffer', maxBuffer: 4 * 1024 * 1024 }
    )
    return scheduledTaskXmlMatchesExe(decodeSchtasksOutput(stdout), exePath()) ? 'ours' : 'foreign'
  } catch {
    return 'missing'
  }
}

async function removeScheduledTask(isAdmin: boolean): Promise<void> {
  const execPromise = promisify(exec)
  try {
    if (isAdmin) {
      await execPromise(`%SystemRoot%\\System32\\schtasks.exe /delete /tn "${appName}" /f`)
    } else {
      await execPromise(
        `powershell -NoProfile -Command "Start-Process schtasks -Verb RunAs -ArgumentList '/delete', '/tn', '${appName}', '/f' -WindowStyle Hidden -Wait"`
      )
    }
  } catch {
    // 任务可能不存在，忽略错误
  }
}

function getTaskXml(asAdmin: boolean): string {
  const runLevel = asAdmin ? 'HighestAvailable' : 'LeastPrivilege'
  return `<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>PT3S</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>${runLevel}</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>Parallel</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>false</AllowHardTerminate>
    <StartWhenAvailable>false</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>3</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>"${exePath()}"</Command>
    </Exec>
  </Actions>
</Task>
`
}

export async function checkAutoRun(): Promise<boolean> {
  if (process.platform === 'win32') {
    const execPromise = promisify(exec)
    const execFilePromise = promisify(execFile)
    // 先检查任务计划程序
    try {
      const { stdout } = await execPromise(
        `chcp 437 && %SystemRoot%\\System32\\schtasks.exe /query /tn "${appName}"`
      )
      if (stdout.includes(appName)) {
        return true
      }
    } catch {
      // 任务计划程序中不存在，继续检查注册表
    }

    // 检查注册表备用方案
    try {
      const regPath = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
      const { stdout } = await execFilePromise('reg', ['query', regPath, '/v', appName])
      return stdout.includes(appName)
    } catch {
      return false
    }
  }

  if (process.platform === 'darwin') {
    const execPromise = promisify(exec)
    const { stdout } = await execPromise(
      `osascript -e 'tell application "System Events" to get the name of every login item'`
    )
    return stdout.includes(exePath().split('.app')[0].replace('/Applications/', ''))
  }

  if (process.platform === 'linux') {
    return existsSync(path.join(homeDir, '.config', 'autostart', `${appName}.desktop`))
  }
  return false
}

export async function enableAutoRun(): Promise<void> {
  if (process.platform === 'win32') {
    const execPromise = promisify(exec)
    const execFilePromise = promisify(execFile)
    const regPath = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
    const isAdmin = await checkAdminPrivileges()

    let taskCreated = false

    try {
      await execFilePromise('reg', ['delete', regPath, '/v', appName, '/f'])
    } catch {
      // ignore
    }

    await withTaskXmlFile(getTaskXml(isAdmin), async (taskFilePath) => {
      if (isAdmin) {
        try {
          await execPromise(
            `%SystemRoot%\\System32\\schtasks.exe /create /tn "${appName}" /xml "${taskFilePath}" /f`
          )
          taskCreated = true
        } catch (error) {
          await managerLogger.warn('Failed to create scheduled task as admin:', error)
        }
      } else {
        try {
          await execPromise(
            `powershell -NoProfile -Command "Start-Process schtasks -Verb RunAs -ArgumentList '/create', '/tn', '${appName}', '/xml', '${quoteForPowerShell(taskFilePath)}', '/f' -WindowStyle Hidden -Wait"`
          )
          // 验证任务是否创建成功
          await new Promise((resolve) => setTimeout(resolve, 1000))
        } catch {
          await managerLogger.info('Scheduled task creation failed, trying registry fallback')
        }
      }
    })

    // 无论走的是哪条分支，schtasks 读到的那个 XML 都躺在同用户可写的目录里。
    // 唯一可靠的检查是把注册好的任务读回来，确认它仍然指向本应用自己的可执行文件。
    const verified = await verifyScheduledTaskCommand()
    if (verified === 'foreign') {
      await managerLogger.error(
        'The registered logon task does not point at AikoBox; deleting it and falling back to the registry'
      )
      await removeScheduledTask(isAdmin)
    } else if (verified === 'missing') {
      await managerLogger.warn('Scheduled task creation may have failed or been rejected')
    }
    taskCreated = verified === 'ours'

    // 任务计划程序失败时使用注册表备用方案（适用于 Windows IoT LTSC 等受限环境）
    if (!taskCreated) {
      await managerLogger.info('Using registry fallback for auto-run')
      try {
        const regValue = `"${exePath()}"`
        await execFilePromise('reg', [
          'add',
          regPath,
          '/v',
          appName,
          '/t',
          'REG_SZ',
          '/d',
          regValue,
          '/f'
        ])
        await managerLogger.info('Registry auto-run entry created successfully')
      } catch (regError) {
        await managerLogger.error('Failed to create registry auto-run entry:', regError)
      }
    }
  }
  if (process.platform === 'darwin') {
    const execPromise = promisify(exec)
    await execPromise(
      `osascript -e 'tell application "System Events" to make login item at end with properties {path:"${exePath().split('.app')[0]}.app", hidden:false}'`
    )
  }
  if (process.platform === 'linux') {
    let desktop = `
[Desktop Entry]
Name=AikoBox
Exec=${exePath()} %U
Terminal=false
Type=Application
Icon=aikobox
StartupWMClass=aikobox
Comment=AikoBox
Categories=Utility;
`

    if (existsSync(`/usr/share/applications/${appName}.desktop`)) {
      desktop = await readFile(`/usr/share/applications/${appName}.desktop`, 'utf8')
    }
    const autostartDir = path.join(homeDir, '.config', 'autostart')
    if (!existsSync(autostartDir)) {
      await mkdir(autostartDir, { recursive: true })
    }
    const desktopFilePath = path.join(autostartDir, `${appName}.desktop`)
    await writeFile(desktopFilePath, desktop)
  }
}

export async function disableAutoRun(): Promise<void> {
  if (process.platform === 'win32') {
    const execFilePromise = promisify(execFile)
    const isAdmin = await checkAdminPrivileges()

    // 删除任务计划程序中的任务
    await removeScheduledTask(isAdmin)

    // 同时删除注册表备用方案
    try {
      const regPath = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Run'
      await execFilePromise('reg', ['delete', regPath, '/v', appName, '/f'])
    } catch {
      // 注册表项可能不存在，忽略错误
    }
  }
  if (process.platform === 'darwin') {
    const execPromise = promisify(exec)
    await execPromise(
      `osascript -e 'tell application "System Events" to delete login item "${exePath().split('.app')[0].replace('/Applications/', '')}"'`
    )
  }
  if (process.platform === 'linux') {
    const desktopFilePath = path.join(homeDir, '.config', 'autostart', `${appName}.desktop`)
    await rm(desktopFilePath)
  }
}
