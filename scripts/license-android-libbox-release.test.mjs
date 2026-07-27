import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import {
  auditCoverage,
  isLegalFile,
  nativeInputsFromPackage,
  parseJsonStream,
  parseModuleInventory,
  parseVendorModules
} from './license-android-libbox-release.mjs'

function inventory(count = 75) {
  return [
    'module\tversion\tsum',
    ...Array.from(
      { length: count },
      (_, index) => `example.com/module${index}\tv1.0.${index}\th1:sum${index}=`
    )
  ].join('\n')
}

test('requires exactly 75 unique actual modules', () => {
  assert.equal(parseModuleInventory(inventory()).length, 75)
  assert.throws(() => parseModuleInventory(inventory(74)), /Expected 75/)
})

test('parses vendor identities and JSON object streams', () => {
  const vendor = parseVendorModules(
    '# example.com/a v1.2.3\n## explicit\nexample.com/a\n# example.com/b v2.0.0\n'
  )
  assert(vendor.has('example.com/a@v1.2.3'))
  assert(vendor.has('example.com/b@v2.0.0'))
  assert.deepEqual(parseJsonStream('{"a":"}"}\n{"b":{"c":1}}\n'), [{ a: '}' }, { b: { c: 1 } }])
})

test('recognizes legal files without treating source files as notices', () => {
  assert.equal(isLegalFile('/module/LICENSE'), true)
  assert.equal(isLegalFile('/module/NOTICE.txt'), true)
  assert.equal(isLegalFile('/module/license_test.go'), false)
})

test('detects linked native inputs and blocks incomplete coverage', () => {
  const fixture = mkdtempSync(join(tmpdir(), 'aikobox-license-test-'))
  try {
    const nativeArchive = join(fixture, 'libfixture.a')
    writeFileSync(nativeArchive, 'native')
    assert.deepEqual(
      nativeInputsFromPackage({
        Dir: fixture,
        SysoFiles: [],
        CgoLDFLAGS: ['-L${SRCDIR}', '-l:libfixture.a']
      }),
      [nativeArchive]
    )

    const actualModules = parseModuleInventory(inventory())
    const vendorModules = new Map(actualModules.map((row) => [`${row.module}@${row.version}`, row]))
    const packages = actualModules.map((row) => ({
      ImportPath: row.module,
      Dir: fixture,
      Module: { Path: row.module, Version: row.version }
    }))
    const downloads = actualModules.map((row) => ({
      Path: row.module,
      Version: row.version
    }))
    assert.deepEqual(
      auditCoverage({ actualModules, vendorModules, packages, downloads }).blockers,
      []
    )

    packages[0].SysoFiles = ['libfixture.a']
    assert.match(
      auditCoverage({ actualModules, vendorModules, packages, downloads }).blockers.at(-1),
      /linked native input/
    )
  } finally {
    rmSync(fixture, { recursive: true, force: true })
  }
})
