import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  ELECTRON_PROD_SMOKE_TOKEN,
  isGithubWindowsProdSmokeEnvironment
} from './electron-production-ci-smoke.mjs'

const scriptsDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(scriptsDirectory, '..')
const bootstrapSource = fs.readFileSync(
  path.join(scriptsDirectory, 'electron-smoke', 'production-bootstrap.cjs'),
  'utf8'
)
const runnerSource = fs.readFileSync(
  path.join(scriptsDirectory, 'electron-production-ci-smoke.mjs'),
  'utf8'
)
const qualityWorkflow = fs.readFileSync(
  path.join(repositoryRoot, '.github', 'workflows', 'quality.yml'),
  'utf8'
)
const packageJson = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))

test('production Electron launch gate accepts only an authorized GitHub-hosted Windows job', () => {
  const authorized = {
    AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN: ELECTRON_PROD_SMOKE_TOKEN,
    CI: 'true',
    GITHUB_ACTIONS: 'true',
    RUNNER_ENVIRONMENT: 'github-hosted',
    RUNNER_OS: 'Windows'
  }
  assert.equal(isGithubWindowsProdSmokeEnvironment(authorized, 'win32'), true)
  assert.equal(
    isGithubWindowsProdSmokeEnvironment({ ...authorized, GITHUB_ACTIONS: 'false' }, 'win32'),
    false
  )
  assert.equal(
    isGithubWindowsProdSmokeEnvironment({ ...authorized, RUNNER_OS: 'Linux' }, 'win32'),
    false
  )
  assert.equal(isGithubWindowsProdSmokeEnvironment({ ...authorized }, 'linux'), false)
  assert.equal(
    isGithubWindowsProdSmokeEnvironment(
      { ...authorized, AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN: 'wrong' },
      'win32'
    ),
    false
  )
})

test('production bootstrap gates before tripwires and refuses non-isolated loads', () => {
  assert.ok(
    bootstrapSource.indexOf('assertProdSmokeGate()') <
      bootstrapSource.indexOf("require('node:child_process')")
  )
  for (const method of [
    'exec',
    'execFile',
    'execFileSync',
    'execSync',
    'fork',
    'spawn',
    'spawnSync'
  ]) {
    assert.match(bootstrapSource, new RegExp(`['"]${method}['"]`))
  }
  assert.match(bootstrapSource, /SYSTEM_SIDE_EFFECT_BLOCKED/)
  assert.match(bootstrapSource, /AIKOBOX_CI_ISOLATED_SMOKE/)
  assert.match(bootstrapSource, /out\/main\/index\.js/)
  assert.match(bootstrapSource, /isolation hooks exist/)
  assert.match(bootstrapSource, /fail-closed/)
  assert.doesNotMatch(bootstrapSource, /sing-box(?:\.exe)?\s+run/i)
  assert.doesNotMatch(bootstrapSource, /require\(['"].*(?:sysproxy|manager).*['"]\)/i)
})

test('production smoke runner never kills Electron by image name and owns its PID tree', () => {
  assert.match(runnerSource, /taskkill\.exe/)
  assert.match(runnerSource, /\['\/PID', String\(pid\), '\/T', '\/F'\]/)
  assert.doesNotMatch(runnerSource, /['"]\/IM['"]/i)
  assert.doesNotMatch(runnerSource, /['"]electron\.exe['"]/i)
  assert.match(runnerSource, /AIKOBOX_CI_ISOLATED_SMOKE/)
  assert.match(runnerSource, /'out',\s*'preload',\s*'index\.cjs'/)
})

test('package scripts and quality workflow wire static production smoke tests only', () => {
  assert.equal(
    packageJson.scripts['test:electron-prod-smoke'],
    'node --test scripts/electron-production-ci-smoke.test.mjs'
  )
  assert.equal(
    packageJson.scripts['smoke:electron:prod:ci'],
    'node scripts/electron-production-ci-smoke.mjs'
  )
  const packageWorkflow = fs.readFileSync(
    path.join(repositoryRoot, '.github', 'workflows', 'package.yml'),
    'utf8'
  )
  const releaseWorkflow = fs.readFileSync(
    path.join(repositoryRoot, '.github', 'workflows', 'release.yml'),
    'utf8'
  )
  for (const workflow of [qualityWorkflow, packageWorkflow, releaseWorkflow]) {
    assert.match(workflow, /test:electron-prod-smoke/)
    assert.doesNotMatch(workflow, /smoke:electron:prod:ci/)
  }
  assert.doesNotMatch(packageWorkflow, /smoke:electron:ci/)
  assert.doesNotMatch(releaseWorkflow, /smoke:electron:ci/)
})
