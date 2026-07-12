import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { ELECTRON_SMOKE_TOKEN, isGithubWindowsSmokeEnvironment } from './electron-ci-smoke.mjs'

const scriptsDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(scriptsDirectory, '..')
const mainSource = fs.readFileSync(
  path.join(scriptsDirectory, 'electron-smoke', 'main.cjs'),
  'utf8'
)
const preloadSource = fs.readFileSync(
  path.join(scriptsDirectory, 'electron-smoke', 'preload.cjs'),
  'utf8'
)

test('Electron launch gate accepts only an explicitly authorized GitHub-hosted Windows job', () => {
  const authorized = {
    AIKOBOX_ELECTRON_SMOKE_TOKEN: ELECTRON_SMOKE_TOKEN,
    CI: 'true',
    GITHUB_ACTIONS: 'true',
    RUNNER_ENVIRONMENT: 'github-hosted',
    RUNNER_OS: 'Windows'
  }
  assert.equal(isGithubWindowsSmokeEnvironment(authorized, 'win32'), true)
  assert.equal(
    isGithubWindowsSmokeEnvironment({ ...authorized, GITHUB_ACTIONS: 'false' }, 'win32'),
    false
  )
  assert.equal(
    isGithubWindowsSmokeEnvironment({ ...authorized, RUNNER_OS: 'Linux' }, 'win32'),
    false
  )
  assert.equal(isGithubWindowsSmokeEnvironment({ ...authorized }, 'linux'), false)
  assert.equal(
    isGithubWindowsSmokeEnvironment(
      { ...authorized, AIKOBOX_ELECTRON_SMOKE_TOKEN: 'wrong' },
      'win32'
    ),
    false
  )
})

test('dedicated Electron entrypoint gates before importing Electron and blocks process creation', () => {
  assert.ok(mainSource.indexOf('assertSmokeGate()') < mainSource.indexOf("require('electron')"))
  for (const method of [
    'exec',
    'execFile',
    'execFileSync',
    'execSync',
    'fork',
    'spawn',
    'spawnSync'
  ]) {
    assert.match(mainSource, new RegExp(`['"]${method}['"]`))
  }
  assert.ok(mainSource.indexOf("app.setPath('userData'") < mainSource.indexOf('.whenReady()'))
  assert.match(mainSource, /SAFE_SEND_CHANNELS/)
  assert.match(mainSource, /FORBIDDEN_CHANNELS\.has\(name\)/)
  assert.match(mainSource, /NOOP_CHANNELS[\s\S]*'changeLanguage'/)
  assert.doesNotMatch(mainSource, /smokeResponses[\s\S]*\['changeLanguage'/)
  assert.doesNotMatch(mainSource, /require\(['"].*(?:sysproxy|winreg|registry|manager).*['"]\)/i)
  assert.doesNotMatch(mainSource, /sing-box(?:\.exe)?\s+run/i)
  assert.match(mainSource, /isTrustedRendererNavigation/)
  assert.doesNotMatch(mainSource, /url\.startsWith\(['"]file:/)
  assert.match(mainSource, /host-resolver-rules/)
})

test('outer timeout path terminates only the owned Electron PID tree and awaits close', () => {
  const runnerSource = fs.readFileSync(path.join(scriptsDirectory, 'electron-ci-smoke.mjs'), 'utf8')
  assert.match(runnerSource, /taskkill\.exe/)
  assert.match(runnerSource, /\['\/PID', String\(pid\), '\/T', '\/F'\]/)
  assert.match(runnerSource, /await terminateOwnedElectronTree\(child\)/)
  assert.match(runnerSource, /await closePromise/)
  assert.match(runnerSource, /if \(timeoutId\) clearTimeout\(timeoutId\)/)
  assert.doesNotMatch(runnerSource, /['"]\/IM['"]/i)
  assert.doesNotMatch(runnerSource, /['"]electron\.exe['"]/i)
})

test('smoke preload exposes only an in-memory IPC facade', () => {
  const requires = preloadSource.match(/require\([^)]+\)/g) ?? []
  assert.deepEqual(requires, ["require('electron')"])
  assert.doesNotMatch(
    preloadSource,
    /child_process|node:fs|node:http|node:https|sysproxy|registry|winreg/i
  )
  assert.match(preloadSource, /SYSTEM_SIDE_EFFECT_BLOCKED:file-capability/)
})

test('quality workflow builds first and launches smoke only with the explicit CI token', () => {
  const workflow = fs.readFileSync(
    path.join(repositoryRoot, '.github', 'workflows', 'quality.yml'),
    'utf8'
  )
  const packageJson = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  assert.equal(
    packageJson.scripts['test:electron-smoke'],
    'node --test scripts/electron-ci-smoke.test.mjs'
  )
  assert.equal(packageJson.scripts['smoke:electron:ci'], 'node scripts/electron-ci-smoke.mjs')
  assert.ok(workflow.indexOf('pnpm run build') < workflow.indexOf('pnpm run smoke:electron:ci'))
  assert.match(workflow, /AIKOBOX_ELECTRON_SMOKE_TOKEN:\s*aikobox-github-windows-electron-smoke-v1/)
  assert.match(workflow, /pnpm rebuild electron/)
})
