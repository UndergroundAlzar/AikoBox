import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  getResourceNoticeSection,
  readSfntNameMetadata,
  resolveEvidenceFile
} from './audit-licenses.mjs'

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
  assert.equal(resource.releaseTag, 'v2.051')
  assert.equal(resource.releaseTagCommit, '8998f5dd683424a73e2314a8c1f1e359c19e8742')
  assert.equal(resource.size, 10_673_480)
  assert.equal(resource.sha256, '72a635cb3d2f3524c51620cdde406b217204e8a6a06c6a096ff8ed4b5fd6e27b')

  assert.equal(item.status, 'verified')
  assert.equal(item.license, 'OFL-1.1')
  assert.equal(item.licenseCopyright, 'Copyright 2013 Google LLC')
  assert.equal(item.release.tag, resource.releaseTag)
  assert.equal(item.release.tagCommit, resource.releaseTagCommit)
  assert.deepEqual(item.fontMetadata, resource.fontMetadata)
  assert.deepEqual(item.fontMetadata, {
    version: '2.051',
    buildDate: '20250818',
    buildRevision: 'e92753bfa55fd449e427d4d325f9c8c40408c74e',
    copyright: 'Copyright 2022 Google Inc.'
  })
  assert.deepEqual(item.evidence.map((entry) => entry.type).sort(), [
    'font',
    'license',
    'release',
    'version-metadata'
  ])
  assert.equal(item.licenseFiles.length, 1)

  const licenseFile = item.licenseFiles[0]
  assert.equal(
    licenseFile.sourceUrl,
    'https://raw.githubusercontent.com/googlefonts/noto-emoji/v2.051/LICENSE'
  )
  assert.equal(
    licenseFile.upstreamSha256,
    '500bb1ccf43df7bbb522112f9133a52b16e1c35e809632f5d8609b179152de5b'
  )
  assert.equal(
    licenseFile.transformation,
    'Normalized one redundant blank line and one trailing ASCII space; the legal text is unchanged.'
  )
  const contents = fs.readFileSync(path.join(repositoryRoot, ...licenseFile.path.split('/')))
  assert.equal(createHash('sha256').update(contents).digest('hex'), licenseFile.sha256)
  const text = contents.toString('utf8')
  assert.match(text, /^Copyright 2013 Google LLC$/m)
  assert.match(text, /SIL OPEN FONT LICENSE Version 1\.1 - 26 February 2007/)
  assert.match(text, /2\) Original or Modified Versions of the Font Software may be bundled/)
  assert.match(text.trimEnd(), /OTHER DEALINGS IN THE FONT SOFTWARE\.$/)

  assert.match(builder, /['"]licenses\/\*\*\/\*['"]/)
  assert.match(verifier, /verifiedLicenseFiles/)
  assert.match(verifier, /packaged license evidence does not match/i)

  const embedded = readSfntNameMetadata(
    path.join(repositoryRoot, 'src', 'renderer', 'src', 'assets', 'NotoColorEmoji.ttf')
  )
  assert.deepEqual(
    {
      version: embedded.version,
      buildDate: embedded.buildDate,
      buildRevision: embedded.buildRevision,
      copyright: embedded.copyright
    },
    item.fontMetadata
  )
  assert.equal(
    embedded.versionRecord,
    'Version 2.051;GOOG;noto-emoji:20250818:e92753bfa55fd449e427d4d325f9c8c40408c74e'
  )
})

test('notice evidence is scoped to its resource marker section', () => {
  const notice = [
    '<!-- resource:alpha -->',
    'alpha-only',
    '<!-- resource:beta -->',
    'beta-only',
    '## Unrelated notices',
    'outside-resource-sections'
  ].join('\n')

  const alpha = getResourceNoticeSection(notice, 'alpha')
  assert.match(alpha, /alpha-only/)
  assert.doesNotMatch(alpha, /beta-only/)
  const beta = getResourceNoticeSection(notice, 'beta')
  assert.match(beta, /beta-only/)
  assert.doesNotMatch(beta, /outside-resource-sections/)
  assert.throws(
    () => getResourceNoticeSection(`${notice}\n<!-- resource:alpha -->`, 'alpha'),
    /duplicated/
  )
})

test('evidence paths reject traversal and linked ancestors', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aikobox-license-root-'))
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), 'aikobox-license-outside-'))
  try {
    fs.mkdirSync(path.join(root, 'safe'))
    fs.writeFileSync(path.join(root, 'safe', 'license.txt'), 'license')
    assert.equal(
      resolveEvidenceFile('safe/license.txt', 'test evidence', root),
      path.join(root, 'safe', 'license.txt')
    )
    assert.throws(
      () => resolveEvidenceFile('../outside/license.txt', 'test evidence', root),
      /canonical|escape/
    )

    fs.writeFileSync(path.join(outside, 'license.txt'), 'outside')
    fs.symlinkSync(
      outside,
      path.join(root, 'linked'),
      process.platform === 'win32' ? 'junction' : 'dir'
    )
    assert.throws(
      () => resolveEvidenceFile('linked/license.txt', 'test evidence', root),
      /symbolic link|junction/
    )
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
    fs.rmSync(outside, { recursive: true, force: true })
  }
})
