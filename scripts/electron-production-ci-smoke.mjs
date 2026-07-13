import fs from 'node:fs'
import path from 'node:path'
import { spawn } from 'node:child_process'
import { createRequire } from 'node:module'
import { fileURLToPath } from 'node:url'

export const ELECTRON_PROD_SMOKE_TOKEN = 'aikobox-github-windows-electron-prod-smoke-v1'

export function isGithubWindowsProdSmokeEnvironment(
  env = process.env,
  platform = process.platform
) {
  return (
    platform === 'win32' &&
    env.CI === 'true' &&
    env.GITHUB_ACTIONS === 'true' &&
    env.RUNNER_OS === 'Windows' &&
    env.RUNNER_ENVIRONMENT === 'github-hosted' &&
    env.AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN === ELECTRON_PROD_SMOKE_TOKEN
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

function observeChild(child, timeoutMs) {
  return new Promise((resolve) => {
    let settled = false
    let timeoutId
    const cleanup = () => {
      if (timeoutId) clearTimeout(timeoutId)
      child.removeListener('error', onError)
      child.removeListener('close', onClose)
    }
    const finish = (outcome) => {
      if (settled) return
      settled = true
      cleanup()
      resolve(outcome)
    }
    const onError = (error) => finish({ error, kind: 'error' })
    const onClose = (code, signal) => finish({ code, kind: 'close', signal })
    child.once('error', onError)
    child.once('close', onClose)
    timeoutId = setTimeout(() => finish({ kind: 'timeout' }), timeoutMs)
  })
}

function waitForChildClose(child, timeoutMs) {
  if (child.exitCode !== null || child.signalCode !== null) return Promise.resolve()
  return new Promise((resolve, reject) => {
    let timeoutId
    const cleanup = () => {
      if (timeoutId) clearTimeout(timeoutId)
      child.removeListener('close', onClose)
      child.removeListener('error', onError)
    }
    const onClose = () => {
      cleanup()
      resolve()
    }
    const onError = (error) => {
      cleanup()
      reject(error)
    }
    child.once('close', onClose)
    child.once('error', onError)
    timeoutId = setTimeout(() => {
      cleanup()
      reject(new Error('Electron process tree did not close after termination'))
    }, timeoutMs)
  })
}

async function terminateOwnedElectronTree(child) {
  const pid = child.pid
  if (!Number.isSafeInteger(pid) || pid <= 0) return
  if (child.exitCode !== null || child.signalCode !== null) return

  const closePromise = waitForChildClose(child, 10_000).then(
    () => ({ kind: 'close' }),
    (error) => ({ error, kind: 'error' })
  )
  let taskkillFailure
  let killer
  try {
    killer = spawn('taskkill.exe', ['/PID', String(pid), '/T', '/F'], {
      stdio: ['ignore', 'pipe', 'pipe'],
      windowsHide: true
    })
    const outcome = await observeChild(killer, 10_000)
    if (outcome.kind === 'timeout') {
      killer.kill()
      taskkillFailure = new Error('Timed out while terminating the owned Electron process tree')
    } else if (outcome.kind === 'error') {
      taskkillFailure = outcome.error
    } else if (outcome.code !== 0) {
      taskkillFailure = new Error(`taskkill failed with code ${String(outcome.code)}`)
    }
  } catch (error) {
    taskkillFailure = error
  }

  const closeOutcome = await closePromise
  if (closeOutcome.kind === 'error') {
    if (taskkillFailure) {
      throw new AggregateError(
        [taskkillFailure, closeOutcome.error],
        'Failed to terminate the owned Electron process tree'
      )
    }
    throw closeOutcome.error
  }
}

/**
 * Production main/preload Electron smoke.
 *
 * Fail-closed until production main gains isolated CI mode. Static tests enforce
 * the gate and tripwire bootstrap; live process smoke stays off until isolation
 * is implemented.
 */
export async function runElectronProductionCiSmoke(env = process.env, platform = process.platform) {
  if (!isGithubWindowsProdSmokeEnvironment(env, platform)) {
    throw new Error(
      'Refusing to start production Electron smoke outside a GitHub-hosted Windows smoke job'
    )
  }

  if (env.AIKOBOX_CI_ISOLATED_SMOKE !== '1') {
    throw new Error(
      'Production Electron smoke requires AIKOBOX_CI_ISOLATED_SMOKE=1 once main-process isolation is implemented'
    )
  }

  const repositoryRoot = path.resolve(fileURLToPath(new URL('..', import.meta.url)))
  const bootstrapPath = path.join(
    repositoryRoot,
    'scripts',
    'electron-smoke',
    'production-bootstrap.cjs'
  )
  const mainPath = path.join(repositoryRoot, 'out', 'main', 'index.js')
  const preloadPath = path.join(repositoryRoot, 'out', 'preload', 'index.cjs')
  const rendererPath = path.join(repositoryRoot, 'out', 'renderer', 'index.html')
  for (const [label, filePath] of [
    ['production bootstrap', bootstrapPath],
    ['production main', mainPath],
    ['production preload', preloadPath],
    ['production renderer', rendererPath]
  ]) {
    if (!fs.existsSync(filePath)) throw new Error(`${label} is missing: ${filePath}`)
  }

  const runnerTemp = path.resolve(env.RUNNER_TEMP || '')
  if (!runnerTemp || !fs.existsSync(runnerTemp)) throw new Error('RUNNER_TEMP is unavailable')
  const userDataPath = fs.mkdtempSync(path.join(runnerTemp, 'aikobox-electron-prod-smoke-'))

  const require = createRequire(import.meta.url)
  const electronExecutable = require('electron')
  if (typeof electronExecutable !== 'string' || !fs.existsSync(electronExecutable)) {
    safeRemoveUserData(runnerTemp, userDataPath)
    throw new Error('The locked Electron runtime is not installed')
  }

  const childEnv = {
    ...env,
    AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN: ELECTRON_PROD_SMOKE_TOKEN,
    AIKOBOX_CI_ISOLATED_SMOKE: '1',
    AIKOBOX_SMOKE_USER_DATA: userDataPath
  }
  delete childEnv.ELECTRON_RUN_AS_NODE

  let stdout = ''
  let stderr = ''
  let child
  try {
    child = spawn(
      electronExecutable,
      [
        '--disable-gpu',
        '--disable-software-rasterizer',
        '--disable-breakpad',
        `--user-data-dir=${userDataPath}`,
        bootstrapPath,
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

    const outcome = await observeChild(child, 45_000)
    if (outcome.kind === 'timeout') {
      await terminateOwnedElectronTree(child)
      throw new Error(`Production Electron smoke timed out\n${stdout}\n${stderr}`)
    }
    if (outcome.kind === 'error') {
      await terminateOwnedElectronTree(child)
      throw outcome.error
    }
    if (outcome.code !== 0) {
      throw new Error(
        `Production Electron smoke exited with code ${String(outcome.code)}\n${stdout}\n${stderr}`
      )
    }
    if (!stdout.includes('AIKOBOX_ELECTRON_PROD_SMOKE_OK')) {
      throw new Error(`Production Electron smoke missing success marker\n${stdout}\n${stderr}`)
    }
    process.stdout.write(stdout)
  } finally {
    if (child && child.exitCode === null && child.signalCode === null) {
      await terminateOwnedElectronTree(child).catch(() => {})
    }
    safeRemoveUserData(runnerTemp, userDataPath)
  }
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : ''
const modulePath = fileURLToPath(import.meta.url)

if (invokedPath === modulePath) {
  try {
    await runElectronProductionCiSmoke()
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error))
    process.exitCode = 1
  }
}
