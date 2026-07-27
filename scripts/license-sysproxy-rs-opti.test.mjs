import assert from 'node:assert/strict'
import { test } from 'node:test'

import {
  assertPeX64Dll,
  assertSafeArchiveEntries,
  isLegalFile,
  parseCargoLockPackages,
  productionPackageIds
} from './license-sysproxy-rs-opti.mjs'

test('legal-file detection is narrow and case-insensitive', () => {
  assert.equal(isLegalFile('LICENSE-APACHE'), true)
  assert.equal(isLegalFile('subdir/Notice.txt'), true)
  assert.equal(isLegalFile('src/license.rs'), false)
  assert.equal(isLegalFile('README.md'), false)
})

test('production graph includes normal and build dependencies but excludes dev-only edges', () => {
  const metadata = {
    resolve: {
      root: 'root',
      nodes: [
        {
          id: 'root',
          deps: [
            { pkg: 'normal', dep_kinds: [{ kind: null }] },
            { pkg: 'build', dep_kinds: [{ kind: 'build' }] },
            { pkg: 'dev', dep_kinds: [{ kind: 'dev' }] }
          ]
        },
        { id: 'normal', deps: [] },
        { id: 'build', deps: [{ pkg: 'transitive', dep_kinds: [{ kind: null }] }] },
        { id: 'dev', deps: [] },
        { id: 'transitive', deps: [] }
      ]
    }
  }
  assert.deepEqual(productionPackageIds(metadata), ['build', 'normal', 'transitive'])
})

test('archive path validation rejects absolute and traversal entries', () => {
  assert.doesNotThrow(() => assertSafeArchiveEntries(['root/', 'root/LICENSE'], 'safe'))
  assert.throws(() => assertSafeArchiveEntries(['../secret'], 'bad'), /traversal/)
  assert.throws(() => assertSafeArchiveEntries(['C:/secret'], 'bad'), /absolute/)
})

test('PE validation requires an AMD64 DLL', () => {
  const image = Buffer.alloc(256)
  image.write('MZ', 0, 'ascii')
  image.writeUInt32LE(128, 0x3c)
  image.write('PE\0\0', 128, 'ascii')
  image.writeUInt16LE(0x8664, 132)
  image.writeUInt16LE(0x2000, 150)
  assert.doesNotThrow(() => assertPeX64Dll(image))
  image.writeUInt16LE(0x014c, 132)
  assert.throws(() => assertPeX64Dll(image), /AMD64/)
})

test('Cargo.lock parser retains optional registry packages absent from metadata', () => {
  const packages = parseCargoLockPackages(`version = 4

[[package]]
name = "root"
version = "0.1.0"

[[package]]
name = "optional"
version = "1.2.3"
source = "registry+https://github.com/rust-lang/crates.io-index"
checksum = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
`)
  assert.deepEqual(packages, [
    { name: 'root', version: '0.1.0', source: null, checksum: null },
    {
      name: 'optional',
      version: '1.2.3',
      source: 'registry+https://github.com/rust-lang/crates.io-index',
      checksum: 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
    }
  ])
})
