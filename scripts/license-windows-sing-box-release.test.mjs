import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'

import { parseGoBuildInfo } from './license-android-libbox.mjs'
import {
  parseWindowsModuleInventory,
  requireWindowsBuildIdentity
} from './license-windows-sing-box-release.mjs'

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const evidenceRoot = resolve(repoRoot, 'licenses', 'sing-box-1.13.14')

test('requires exactly 100 unique Windows static modules', () => {
  const inventory = readFileSync(resolve(evidenceRoot, 'static-modules.tsv'), 'utf8')
  const modules = parseWindowsModuleInventory(inventory)
  assert.equal(modules.length, 100)
  assert.throws(
    () => parseWindowsModuleInventory(inventory.replace(/^dep\t.*\n/m, '')),
    /Expected 100 unique Windows static modules/
  )
})

test('accepts only the exact Windows build identity', () => {
  const raw = readFileSync(resolve(evidenceRoot, 'buildinfo-modules.txt'), 'utf8')
  const buildInfo = parseGoBuildInfo(raw)
  assert.doesNotThrow(() => requireWindowsBuildIdentity(buildInfo))
  assert.throws(
    () => requireWindowsBuildIdentity({ ...buildInfo, goVersion: 'go0.0.0' }),
    /Windows sing-box build identity differs/
  )
})
