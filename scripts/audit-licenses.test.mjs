import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  extractReviewedLicenseSection,
  getResourceNoticeSection,
  isRecognizedRootLicenseFileName,
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

function encodeUtf16Be(value) {
  const encoded = Buffer.alloc(value.length * 2)
  for (let index = 0; index < value.length; index += 1) {
    encoded.writeUInt16BE(value.charCodeAt(index), index * 2)
  }
  return encoded
}

function createSfntNameFixture(copyright, versionRecord) {
  const strings = [encodeUtf16Be(copyright), encodeUtf16Be(versionRecord)]
  const nameTable = Buffer.alloc(6 + 2 * 12 + strings[0].length + strings[1].length)
  nameTable.writeUInt16BE(0, 0)
  nameTable.writeUInt16BE(2, 2)
  nameTable.writeUInt16BE(30, 4)
  let stringOffset = 0
  for (const [index, nameId] of [0, 5].entries()) {
    const recordOffset = 6 + index * 12
    nameTable.writeUInt16BE(3, recordOffset)
    nameTable.writeUInt16BE(1, recordOffset + 2)
    nameTable.writeUInt16BE(0x0409, recordOffset + 4)
    nameTable.writeUInt16BE(nameId, recordOffset + 6)
    nameTable.writeUInt16BE(strings[index].length, recordOffset + 8)
    nameTable.writeUInt16BE(stringOffset, recordOffset + 10)
    strings[index].copy(nameTable, 30 + stringOffset)
    stringOffset += strings[index].length
  }

  const sfnt = Buffer.alloc(28)
  sfnt.writeUInt32BE(0x00010000, 0)
  sfnt.writeUInt16BE(1, 4)
  sfnt.write('name', 12, 'ascii')
  sfnt.writeUInt32BE(28, 20)
  sfnt.writeUInt32BE(nameTable.length, 24)
  return Buffer.concat([sfnt, nameTable])
}

test('offline audit covers dependencies and explicitly tracked resource blockers', () => {
  const result = runAudit('--allow-known-blockers')
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  assert.match(result.stdout, /production dependency versions use reviewed license expressions/)
  assert.match(result.stdout, /5 exact production package evidence records passed/)
  assert.match(result.stderr, /Production packages without reviewed license evidence/)
  assert.match(
    result.stderr,
    /@nodable\/entities@2\.2\.0, byte-length@1\.0\.2, sysproxy-rs@0\.4\.0, xml-naming@0\.1\.0/
  )
  assert.match(result.stderr, /\[BLOCKED\].*singBox.*subStoreBackend.*subStoreFrontend.*sysproxy/)
  assert.doesNotMatch(result.stderr, /\[BLOCKED\].*notoColorEmoji/)
  assert.doesNotMatch(
    result.stdout + result.stderr,
    /sevenZip|7za\.exe|enableLoopback|trafficMonitor|TrafficMonitor/
  )
})

test('release-gate mode fails closed while redistribution evidence is unresolved', () => {
  const result = runAudit()
  assert.equal(result.status, 1, `${result.stdout}\n${result.stderr}`)
  assert.match(
    result.stderr,
    /Runtime resource licensing is unresolved for: singBox, subStoreBackend, subStoreFrontend, sysproxy/
  )
})

test('five exact npm package evidence cases close mechanically and enter the package gate', () => {
  const review = JSON.parse(
    fs.readFileSync(path.join(repositoryRoot, 'scripts', 'third-party-review.json'), 'utf8')
  )
  const evidence = review.productionPackageEvidence
  assert.deepEqual(Object.keys(evidence).sort(), [
    '@electron-internal/extract-zip@1.0.3',
    'agent-base@6.0.2',
    'base-64@1.0.0',
    'data-uri-to-buffer@4.0.1',
    'https-proxy-agent@5.0.1'
  ])
  assert.deepEqual(review.productionPackagesWithoutLicenseFiles, [
    '@nodable/entities@2.2.0',
    'byte-length@1.0.2',
    'sysproxy-rs@0.4.0',
    'xml-naming@0.1.0'
  ])

  assert.equal(isRecognizedRootLicenseFileName('LICENSE-MIT.txt'), true)
  assert.equal(isRecognizedRootLicenseFileName('LICENCE.md'), true)
  assert.equal(isRecognizedRootLicenseFileName('LICENSE-unknown.txt'), false)
  assert.equal(isRecognizedRootLicenseFileName('README.md'), false)

  const expected = {
    'agent-base@6.0.2': {
      disposition: 'packaged-readme-section',
      sourceSha256: 'f1425c3b72330fe4fb2aa5a2fb152e939bdf534692a32b5f0b38f74147b98556',
      packagedSha256: 'b3681ff73335c04770aa0367aa4ca72e77e5ca55007fc0bcb9d564d00cce20f4'
    },
    'base-64@1.0.0': {
      disposition: 'packaged-license-file',
      sourceSha256: '483acb265f182907d1caf6cff9c16c96f31325ed23792832cc5d8b12d5f88c8a',
      packagedSha256: '483acb265f182907d1caf6cff9c16c96f31325ed23792832cc5d8b12d5f88c8a'
    },
    'data-uri-to-buffer@4.0.1': {
      disposition: 'packaged-readme-section',
      sourceSha256: 'a7cc4332acfa1f9b6530e01aac77fefe74f2efa32579215fddaa473013f9a25c',
      packagedSha256: '3072ef4a004c4f92b37eae61cdc3e27225c0a7d2f5e144700e40b9c5a5a7a9b9'
    },
    'https-proxy-agent@5.0.1': {
      disposition: 'packaged-readme-section',
      sourceSha256: '32f0856d2c43df7d05cca960fdee84e1e38ab545bd7b2186433dfa41aa90a712',
      packagedSha256: 'b3681ff73335c04770aa0367aa4ca72e77e5ca55007fc0bcb9d564d00cce20f4'
    }
  }
  for (const [identity, pinned] of Object.entries(expected)) {
    const item = evidence[identity]
    assert.equal(item.license, 'MIT')
    assert.equal(item.disposition, pinned.disposition)
    assert.equal(item.sourceSha256, pinned.sourceSha256)
    assert.equal(item.licenseFile.sha256, pinned.packagedSha256)
    const contents = fs.readFileSync(path.join(repositoryRoot, ...item.licenseFile.path.split('/')))
    assert.equal(contents.length, item.licenseFile.size)
    assert.equal(createHash('sha256').update(contents).digest('hex'), item.licenseFile.sha256)
    assert.match(contents.toString('utf8'), /Permission is hereby granted/)
  }

  assert.deepEqual(evidence['@electron-internal/extract-zip@1.0.3'], {
    license: 'BSD-2-Clause',
    disposition: 'excluded-from-application',
    sourceFile: 'package.json',
    sourceSize: 2095,
    sourceSha256: '45d97af150605251f517c98e14bf456dc780cfa9956794547cd3e57172927662',
    forbiddenAsarPath: '/node_modules/@electron-internal/extract-zip'
  })

  const builder = fs.readFileSync(path.join(repositoryRoot, 'electron-builder.yml'), 'utf8')
  const verifier = fs.readFileSync(
    path.join(repositoryRoot, 'scripts', 'verify-release.mjs'),
    'utf8'
  )
  assert.match(builder, /['"]licenses\/\*\*\/\*['"]/)
  assert.match(verifier, /productionPackageEvidence/)
  assert.match(verifier, /excluded production package entered app\.asar/)
})

test('README license extraction is exact and rejects ambiguous markers', () => {
  const source = Buffer.from('intro\n(The MIT License)\nbody\nEND\nreferences\n')
  assert.equal(
    extractReviewedLicenseSection(source, '(The MIT License)\n', 'END\n', 'fixture').toString(),
    '(The MIT License)\nbody\nEND\n'
  )
  assert.throws(
    () =>
      extractReviewedLicenseSection(
        Buffer.from('(The MIT License)\none\n(The MIT License)\ntwo\nEND\n'),
        '(The MIT License)\n',
        'END\n',
        'fixture'
      ),
    /ambiguous/
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

  const fontPath = path.join(
    repositoryRoot,
    'src',
    'renderer',
    'src',
    'assets',
    'NotoColorEmoji.ttf'
  )
  if (fs.existsSync(fontPath)) {
    const embedded = readSfntNameMetadata(fontPath)
    assert.deepEqual(
      {
        version: embedded.version,
        buildDate: embedded.buildDate,
        buildRevision: embedded.buildRevision,
        copyright: embedded.copyright
      },
      item.fontMetadata
    )
  }
})

test('SFNT parser reads pinned metadata from a synthetic name table', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'aikobox-sfnt-'))
  const fixturePath = path.join(directory, 'NotoColorEmoji.ttf')
  const versionRecord =
    'Version 2.051;GOOG;noto-emoji:20250818:e92753bfa55fd449e427d4d325f9c8c40408c74e'
  try {
    fs.writeFileSync(
      fixturePath,
      createSfntNameFixture('Copyright 2022 Google Inc.', versionRecord)
    )
    assert.deepEqual(readSfntNameMetadata(fixturePath), {
      version: '2.051',
      buildDate: '20250818',
      buildRevision: 'e92753bfa55fd449e427d4d325f9c8c40408c74e',
      copyright: 'Copyright 2022 Google Inc.',
      versionRecord
    })
  } finally {
    fs.rmSync(directory, { recursive: true, force: true })
  }
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
    assert.equal(
      resolveEvidenceFile('safe/missing.ttf', 'optional output', root, true),
      path.join(root, 'safe', 'missing.ttf')
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
