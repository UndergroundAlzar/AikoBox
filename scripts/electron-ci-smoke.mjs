import fs from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

export const ELECTRON_SMOKE_TOKEN = 'aikobox-github-windows-electron-smoke-v1'

export function isGithubWindowsSmokeEnvironment(env = process.env, platform = process.platform) {
  return (
    platform === 'win32' &&
    env.CI === 'true' &&
    env.GITHUB_ACTIONS === 'true' &&
    env.RUNNER_OS === 'Windows' &&
    env.RUNNER_ENVIRONMENT === 'github-hosted' &&
    env.AIKOBOX_ELECTRON_SMOKE_TOKEN === ELECTRON_SMOKE_TOKEN
  )
}

function boundedOutput(current, chunk) {
  const next = current + chunk.toString('utf8')
  return next.length > 64 * 1024 ? next.slice(-64 * 1024) : next
}

function safeRemoveUserData(runnerTemp, userDataPath) {
  const relative = path.relative(runnerTemp, userDataPath)
  if (!relative || relative.startsWith('..') || path.isAbsolute(relative)) return
  fs.rmSync(userDataPath, { force: true, maxRetries: 3, recursive: true, retryDelay: 100 })
}

export async function runElectronCiSmoke(env = process.env, platform = process.platform) {
  if (!isGithubWindowsSmokeEnvironment(env, platform)) {
    throw new Error('Refusing to start Electron outside a GitHub-hosted Windows smoke job')
  }

  const repositoryRoot = path.resolve(fileURLToPath(new URL('..', import.meta.url)))
  const mainPath = path.join(repositoryRoot, 'scripts', 'electron-smoke', 'main.cjs')
  const rendererPath = path.join(repositoryRoot, 'out', 'renderer', 'index.html')
  if (!fs.existsSync(mainPath)) throw new Error('Electron smoke main entrypoint is missing')
  if (!fs.existsSync(rendererPath)) throw new Error('Production renderer build is missing')

  const runnerTemp = path.resolve(env.RUNNER_TEMP || '')
  if (!runnerTemp || !fs.existsSync(runnerTemp)) throw new Error('RUNNER_TEMP is unavailable')
  const userDataPath = fs.mkdtempSync(path.join(runnerTemp, 'aikobox-electron-smoke-'))

  const require = createRequire(import.meta.url)
  const electronExecutable = require('electron')
  if (typeof electronExecutable !== 'string' || !fs.existsSync(electronExecutable)) {
    safeRemoveUserData(runnerTemp, userDataPath)
    throw new Error('The locked Electron runtime is not installed')
  }

  const childEnv = {
    ...env,
    AIKOBOX_ELECTRON_SMOKE_TOKEN: ELECTRON_SMOKE_TOKEN,
    AIKOBOX_SMOKE_RENDERER_PATH: rendererPath,
    AIKOBOX_SMOKE_USER_DATA: userDataPath
  }
  delete childEnv.ELECTRON_RUN_AS_NODE

  let stdout = ''
  let stderr = ''
  let timedOut = false
  try {
    const result = await new Promise((resolve, reject) => {
      const child = spawn(
        electronExecutable,
        [
          '--disable-gpu',
          '--disable-software-rasterizer',
          '--disable-breakpad',
          `--user-data-dir=${userDataPath}`,
          mainPath
        ],
        {
          cwd: repositoryRoot,
          env: childEnv,
          stdio: ['ignore', 'pipe', 'pipe'],
          windowsHide: true
        }
      )
      child.stdout.on('data', (chunk) => {
        stdout = boundedOutput(stdout, chunk)
      })
      child.stderr.on('data', (chunk) => {
        stderr = boundedOutput(stderr, chunk)
      })
      child.once('error', reject)

      const timeout = setTimeout(() => {
        timedOut = true
        child.kill()
      }, 35_000)
      child.once('close', (code, signal) => {
        clearTimeout(timeout)
        resolve({ code, signal })
      })
    })

    if (timedOut) throw new Error(`Electron smoke timed out\n${stdout}\n${stderr}`)
    if (result.code !== 0) {
      throw new Error(
        `Electron smoke exited with code ${String(result.code)} signal ${String(result.signal)}\n${stdout}\n${stderr}`
      )
    }
    if (!stdout.includes('AIKOBOX_ELECTRON_SMOKE_OK')) {
      throw new Error(`Electron smoke exited without its proof marker\n${stdout}\n${stderr}`)
    }
    process.stdout.write(stdout)
  } finally {
    safeRemoveUserData(runnerTemp, userDataPath)
  }
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : ''
const modulePath = fileURLToPath(import.meta.url)

if (invokedPath === modulePath) {
  try {
    await runElectronCiSmoke()
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
