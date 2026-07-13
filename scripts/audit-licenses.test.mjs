import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const auditScript = path.join(repositoryRoot, 'scripts', 'audit-licenses.mjs')

function runAudit(...arguments_) {
  return spawnSync(process.execPath, [auditScript, ...arguments_], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    windowsHide: true
  })
}

test('offline audit covers dependencies and explicitly tracked resource blockers', () => {
  const result = runAudit('--allow-known-blockers')
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  assert.match(result.stdout, /production dependency versions use reviewed license expressions/)
  assert.match(result.stderr, /Production packages without a root license file/)
  assert.match(result.stderr, /\[BLOCKED\].*enableLoopback.*singBox/)
  assert.doesNotMatch(result.stderr, /\[BLOCKED\].*notoColorEmoji/)
  assert.doesNotMatch(result.stdout + result.stderr, /sevenZip|7za\.exe/)
})

test('release-gate mode fails closed while redistribution evidence is unresolved', () => {
  const result = runAudit()
  assert.equal(result.status, 1, `${result.stdout}\n${result.stderr}`)
  assert.match(
    result.stderr,
    /Runtime resource licensing is unresolved for: enableLoopback, singBox, subStoreBackend, subStoreFrontend, sysproxy, trafficMonitor/
  )
})

test('Noto Color Emoji evidence is tag-pinned, packaged, and hash-reviewed', () => {
  const lock = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'scripts', 'resources-lock.json'), 'utf8')
  )
  const review = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'scripts', 'third-party-review.json'), 'utf8')
  )
  const builder = fs.readFileSync(path.join(repositoryRoot, 'electron-builder.yml'), 'utf8')
  const verifier = fs.readFileSync(
    path.join(repositoryRoot, 'scripts', 'verify-release.mjs'),
    'utf8'
  )
  const resource = lock.resources.notoColorEmoji
  const item = review.resources.notoColorEmoji

  assert.equal(resource.version, '2.051')
  assert.equal(
    resource.downloadUrl,
    'https://raw.githubusercontent.com/googlefonts/noto-emoji/v2.051/fonts/NotoColorEmoji.ttf'
  )
  assert.equal(resource.sourceTag, 'v2.051')
  assert.equal(resource.sourceCommit, '8998f5dd683424a73e2314a8c1f1e359c19e8742')
  assert.equal(resource.size, 10_673_480)
  assert.equal(resource.sha256, '72a635cb3d2f3524c51620cdde406b217204e8a6a06c6a096ff8ed4b5fd6e27b')

  assert.equal(item.status, 'verified')
  assert.equal(item.license, 'OFL-1.1')
  assert.equal(item.source.tag, resource.sourceTag)
  assert.equal(item.source.commit, resource.sourceCommit)
  assert.deepEqual(item.evidence.map((entry) => entry.type).sort(), [
    'font',
    'license',
    'release',
    'version-metadata'
  ])
  assert.equal(item.licenseFiles.length, 1)

  const licenseFile = item.licenseFiles[0]
  const contents = fs.readFileSync(path.join(repositoryRoot, ...licenseFile.path.split('/')))
  assert.equal(createHash('sha256').update(contents).digest('hex'), licenseFile.sha256)
  const text = contents.toString('utf8')
  assert.match(text, /^Copyright 2013 Google LLC$/m)
  assert.match(text, /SIL OPEN FONT LICENSE Version 1\.1 - 26 February 2007/)
  assert.match(text, /2\) Original or Modified Versions of the Font Software may be bundled/)
  assert.match(text.trimEnd(), /OTHER DEALINGS IN THE FONT SOFTWARE\.$/)

  assert.match(builder, /['"]licenses\/\*\*\/\*['"]/)
  assert.match(verifier, /verifiedLicenseFiles/)
  assert.match(verifier, /Packaged license evidence does not match/)
})
