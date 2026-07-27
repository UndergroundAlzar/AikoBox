import assert from 'node:assert/strict'
import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import { readReleaseVersionContract } from './release-version-contract.mjs'

function fixture(packageVersion, androidVersion) {
  const directory = mkdtempSync(join(tmpdir(), 'aikobox-release-contract-'))
  const packagePath = join(directory, 'package.json')
  const pubspecPath = join(directory, 'pubspec.yaml')
  writeFileSync(packagePath, JSON.stringify({ version: packageVersion }))
  writeFileSync(pubspecPath, `name: fixture\nversion: ${androidVersion}\n`)
  return { packagePath, pubspecPath }
}

test('accepts matching package and Android versions with versionCode above one', () => {
  const paths = fixture('0.1.0-beta.2', '0.1.0-beta.2+2')
  assert.deepEqual(readReleaseVersionContract({ ...paths, releaseTag: 'v0.1.0-beta.2' }), {
    version: '0.1.0-beta.2',
    versionCode: 2,
    expectedTag: 'v0.1.0-beta.2',
    notesPath: 'docs/releases/v0.1.0-beta.2.md'
  })
})

test('rejects a package and Android versionName mismatch', () => {
  const paths = fixture('0.1.0-beta.2', '0.1.0-beta.1+2')
  assert.throws(() => readReleaseVersionContract(paths), /Version mismatch/)
})

test('rejects versionCode one, zero, negative, fractional, or missing', () => {
  for (const androidVersion of [
    '0.1.0-beta.2+1',
    '0.1.0-beta.2+0',
    '0.1.0-beta.2+-2',
    '0.1.0-beta.2+2.5',
    '0.1.0-beta.2'
  ]) {
    const paths = fixture('0.1.0-beta.2', androidVersion)
    assert.throws(() => readReleaseVersionContract(paths), /versionCode|versionName\+versionCode/)
  }
})

test('rejects a tag that does not exactly match the root version', () => {
  const paths = fixture('0.1.0-beta.2', '0.1.0-beta.2+2')
  assert.throws(
    () => readReleaseVersionContract({ ...paths, releaseTag: 'v0.1.0-beta.1' }),
    /must exactly equal/
  )
})
