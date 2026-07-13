import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import path from 'node:path'
import test from 'node:test'
import {
  assertAbsoluteChild,
  normalizeArchiveEntry,
  parseSevenZipTechnicalListing,
  selectPackagedApplication,
  validateArchiveEntries
} from './release-extraction.mjs'

const projectRoot = path.resolve(import.meta.dirname, '..')

test('temporary extraction containment rejects the base and every escape', () => {
  const base = path.resolve(tmpdir(), 'aikobox-release-test')
  assert.equal(
    assertAbsoluteChild(base, path.resolve(base, 'isolated-extraction'), 'test path'),
    path.resolve(base, 'isolated-extraction')
  )
  assert.throws(() => assertAbsoluteChild(base, base, 'test path'), /must stay inside/)
  assert.throws(
    () => assertAbsoluteChild(base, path.resolve(base, '..', 'escape'), 'test path'),
    /must stay inside/
  )
  assert.throws(() => assertAbsoluteChild('relative', path.resolve(base, 'child')), /absolute/)
})

test('archive paths reject traversal, absolute paths, streams, devices, and aliases', () => {
  for (const unsafe of [
    '../escape',
    'safe/../../escape',
    '/absolute',
    'C:\\absolute',
    'resources/app.asar:stream',
    'resources/CON',
    'resources/trailing. '
  ]) {
    assert.throws(() => normalizeArchiveEntry(unsafe), /unsafe|absolute|drive\/stream/)
  }
  assert.throws(
    () => validateArchiveEntries(['resources/app.asar', 'RESOURCES/APP.ASAR']),
    /case-insensitive collision/
  )
})

test('7-Zip technical listings select one real application tree', () => {
  const listing = String.raw`7-Zip technical listing
----------
Path = AikoBox.exe
Size = 1

Path = resources
Folder = +

Path = resources\app.asar
Size = 2
`
  const entries = parseSevenZipTechnicalListing(listing)
  assert.deepEqual(selectPackagedApplication(entries), {
    appAsar: 'resources/app.asar',
    appExecutable: 'AikoBox.exe',
    appRoot: ''
  })
})

test('nested application trees are supported but ambiguity and links fail closed', () => {
  assert.deepEqual(
    selectPackagedApplication([
      '$PLUGINSDIR/app/AikoBox.exe',
      '$PLUGINSDIR/app/resources/app.asar'
    ]),
    {
      appAsar: '$PLUGINSDIR/app/resources/app.asar',
      appExecutable: '$PLUGINSDIR/app/AikoBox.exe',
      appRoot: '$PLUGINSDIR/app'
    }
  )
  assert.throws(
    () =>
      selectPackagedApplication([
        'AikoBox.exe',
        'resources/app.asar',
        'second/AikoBox.exe',
        'second/resources/app.asar'
      ]),
    /exactly one/
  )
  assert.throws(
    () =>
      parseSevenZipTechnicalListing(
        `----------\nPath = resources/app.asar\nSymbolic Link = target\n`
      ),
    /contains a link/
  )
})

test('release verifier statically pins extraction and never launches an artifact', () => {
  const source = readFileSync(path.resolve(projectRoot, 'scripts', 'verify-release.mjs'), 'utf8')
  assert.match(source, /getPath7za/)
  assert.match(source, /ELECTRON_BUILDER_7ZIP_PATH overrides are forbidden/)
  assert.match(source, /223b873c50380fe9a39f1a22b6abf8d46db506e1c08d08312902f6f3cd1f7ac3/)
  assert.match(source, /mkdtempSync/)
  assert.match(source, /finally\s*{\s*removeExtractionDirectory/)
  assert.match(source, /for \(const artifact of artifacts\)/)
  assert.match(source, /\['x', '-y', '-bd', '-bb0'/)
  assert.match(source, /timeout:\s*120_000/)
  assert.match(source, /\['LICENSE\.electron\.txt', 'LICENSES\.chromium\.html'\]/)
  assert.match(source, /lstatSync\(noticePath\)\.isFile\(\)/)
  assert.match(source, /treeDigest:\s*digestDirectory\(unpacked\)/)
  assert.match(source, /actual\.fileCount !== expected\.fileCount/)
  assert.match(source, /actual\.totalBytes !== expected\.totalBytes/)
  assert.match(source, /actual\.sha256 !== expected\.sha256/)
  assert.match(source, /extracted application tree differs from dist\/win-unpacked/)
  assert.match(source, /Retired 7za\.exe must not be present in the packaged runtime/)
  assert.match(source, /Retired enableLoopback\.exe must not be present in the packaged runtime/)
  assert.match(source, /Retired TrafficMonitor must not be present in the packaged runtime/)
  assert.match(source, /productionPackageEvidence/)
  assert.match(source, /excluded production package entered app\.asar/)
  assert.match(source, /excluded production package entered app\.asar\.unpacked/)
  assert.match(source, /Unexpected stale Windows release output/)
  assert.match(source, /allowedReleaseLikeFiles/)
  assert.doesNotMatch(source, /spawnSync\(\s*absoluteArtifact/)
})
