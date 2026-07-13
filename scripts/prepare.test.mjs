import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const scriptsDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(scriptsDirectory, '..')
const lockPath = path.join(scriptsDirectory, 'resources-lock.json')
const preparePath = path.join(scriptsDirectory, 'prepare.mjs')
const sha256Pattern = /^[a-f0-9]{64}$/
const mutablePathPattern = /(^|\/)latest(\/|$)|(^|\/)(main|master)(\/|$)/i
const resourceLock = JSON.parse(fs.readFileSync(lockPath, 'utf8'))
const hasInstalledResourceSet = Object.values(resourceLock.resources).every((resource) =>
  fs.existsSync(path.resolve(repositoryRoot, resource.output))
)

test('resource lock contains only pinned HTTPS downloads and SHA-256 identities', () => {
  const lock = resourceLock

  assert.equal(lock.schemaVersion, 1)
  assert.equal(lock.target, 'win32-x64')
  assert.equal(Object.keys(lock.resources).length, 3)
  assert.equal(lock.resources.sevenZip, undefined)
  assert.equal(lock.resources.enableLoopback, undefined)
  assert.equal(lock.resources.trafficMonitor, undefined)

  for (const [name, resource] of Object.entries(lock.resources)) {
    assert.equal(typeof resource.version, 'string', `${name} must have a version`)
    assert.ok(resource.version.length > 0, `${name} must have a version`)

    if (resource.downloadUrl) {
      const url = new URL(resource.downloadUrl)
      assert.equal(url.protocol, 'https:', `${name} must use HTTPS`)
      if (mutablePathPattern.test(url.pathname)) {
        assert.equal(
          resource.allowMutableLocator,
          true,
          `${name} mutable locator must be explicitly reviewed`
        )
        assert.match(resource.sourceCommit, /^[a-f0-9]{40}$/)
      }
    }

    if (resource.type === 'zip-directory') {
      assert.match(resource.archiveSha256, sha256Pattern)
      assert.match(resource.directorySha256, sha256Pattern)
    } else {
      assert.match(resource.sha256, sha256Pattern)
    }
  }
})

test(
  'verify-only mode validates every installed resource without network access',
  {
    skip: process.platform !== 'win32' || process.arch !== 'x64' || !hasInstalledResourceSet
  },
  () => {
    const result = spawnSync(process.execPath, [preparePath, '--verify-only'], {
      cwd: repositoryRoot,
      encoding: 'utf8',
      env: { ...process.env, AIKOBOX_PREPARE_OFFLINE: '1' },
      timeout: 60_000
    })

    assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stdout, /All 3 locked resources passed integrity verification/)
    assert.doesNotMatch(result.stdout + result.stderr, /downloaded and verified/i)
  }
)

test(
  'verify-only mode fails closed without downloading when resources are absent',
  {
    skip: process.platform !== 'win32' || process.arch !== 'x64' || hasInstalledResourceSet
  },
  () => {
    const result = spawnSync(process.execPath, [preparePath, '--verify-only'], {
      cwd: repositoryRoot,
      encoding: 'utf8',
      env: { ...process.env, AIKOBOX_PREPARE_OFFLINE: '1' },
      timeout: 60_000
    })

    assert.notEqual(result.status, 0, `${result.stdout}\n${result.stderr}`)
    assert.match(result.stdout + result.stderr, /installed resource is missing/i)
    assert.doesNotMatch(result.stdout + result.stderr, /downloaded and verified/i)
  }
)

test('prepare implementation contains no dynamic release discovery', () => {
  const source = fs.readFileSync(preparePath, 'utf8')

  assert.doesNotMatch(source, /releases\s*\/\s*latest/i)
  assert.doesNotMatch(source, /releases\/latest/i)
  assert.doesNotMatch(source, /api\.github\.com\/repos/i)
})

test('retired optional helpers and Sub-Store assets are excluded from release packages', () => {
  const builder = fs.readFileSync(path.join(repositoryRoot, 'electron-builder.yml'), 'utf8')
  const verifier = fs.readFileSync(path.join(scriptsDirectory, 'verify-release.mjs'), 'utf8')
  const prepare = fs.readFileSync(preparePath, 'utf8')

  assert.equal(fs.existsSync(path.join(repositoryRoot, 'extra', 'files', '7za.exe')), false)
  assert.equal(
    fs.existsSync(path.join(repositoryRoot, 'extra', 'files', 'enableLoopback.exe')),
    false
  )
  assert.equal(fs.existsSync(path.join(repositoryRoot, 'extra', 'files', 'TrafficMonitor')), false)
  assert.equal(
    fs.existsSync(path.join(repositoryRoot, 'extra', 'files', 'sub-store.bundle.js')),
    false
  )
  assert.equal(
    fs.existsSync(path.join(repositoryRoot, 'extra', 'files', 'sub-store.bundle.cjs')),
    false
  )
  assert.equal(
    fs.existsSync(path.join(repositoryRoot, 'extra', 'files', 'sub-store-frontend')),
    false
  )
  assert.match(builder, /!files\/7za\.exe/)
  assert.match(builder, /!files\/enableLoopback\.exe/)
  assert.match(builder, /!files\/TrafficMonitor\/\*\*\/\*/)
  assert.match(builder, /!files\/sub-store\.bundle\.js/)
  assert.match(builder, /!files\/sub-store\.bundle\.cjs/)
  assert.match(builder, /!files\/sub-store-frontend\/\*\*\/\*/)
  assert.match(verifier, /Retired 7za\.exe must not be present in the packaged runtime/)
  assert.match(verifier, /Retired enableLoopback\.exe must not be present in the packaged runtime/)
  assert.match(verifier, /Retired TrafficMonitor must not be present in the packaged runtime/)
  assert.match(prepare, /rmSync\(retiredPath, \{ force: true, recursive: true \}\)/)
})

test('Windows packaging always rebuilds production output before electron-builder', () => {
  const packageJson = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'package.json'), 'utf8'))
  assert.equal(
    packageJson.scripts['package:win'],
    'pnpm run clean:release-output && pnpm run build && pnpm run verify:retired-output && electron-builder --publish never --win --x64'
  )
  assert.equal(packageJson.scripts['build:win'], 'pnpm run package:win && pnpm run checksum')
  assert.equal(
    packageJson.scripts['verify:retired-output'],
    'node scripts/verify-retired-output.mjs'
  )
  assert.equal(packageJson.scripts['clean:release-output'], 'node scripts/clean-release-output.mjs')
})
