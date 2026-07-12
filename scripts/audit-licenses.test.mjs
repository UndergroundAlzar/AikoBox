import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
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
  assert.match(result.stderr, /\[BLOCKED\].*sevenZip.*singBox/)
})

test('release-gate mode fails closed while redistribution evidence is unresolved', () => {
  const result = runAudit()
  assert.equal(result.status, 1, `${result.stdout}\n${result.stderr}`)
  assert.match(result.stderr, /Runtime resource licensing is unresolved/)
})
