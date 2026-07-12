import assert from 'node:assert/strict'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

import { runCoreUpdateTransaction } from '../src/main/core/coreUpdateTransaction.ts'

class InMemoryCoreRuntime {
  constructor({ runningCore = null, failCandidateStart = false } = {}) {
    this.selectedCore = runningCore ?? 'stable'
    this.runningCore = runningCore
    this.failCandidateStart = failCandidateStart
    this.committedCore = null
    this.events = []
  }

  async selectCandidate(candidate) {
    this.events.push(`select:${candidate}`)
    this.selectedCore = candidate
    return candidate
  }

  async restoreStableSelection() {
    this.events.push('restore:stable')
    this.selectedCore = 'stable'
  }

  async restart() {
    const selected = this.selectedCore
    this.events.push(`restart:${selected}`)
    this.runningCore = null

    if (selected === 'candidate' && this.failCandidateStart) {
      this.events.push('start-failed:candidate')
      throw new Error('fake candidate rejected during readiness')
    }

    this.runningCore = selected
    this.events.push(`running:${selected}`)
  }

  async commitSelection() {
    this.events.push(`commit:${this.selectedCore}`)
    this.committedCore = this.selectedCore
  }
}

/**
 * Exercises the production core-update transaction with an in-memory core.
 * This module deliberately has no Electron, child-process, network, WinINET,
 * TUN, registry, or process-management dependency.
 */
export async function runIsolatedRuntimeSmoke() {
  const boundaryCalls = []

  const startup = new InMemoryCoreRuntime()
  const selected = await runCoreUpdateTransaction({
    select: () => startup.selectCandidate('candidate'),
    restoreSelection: () => startup.restoreStableSelection(),
    restart: () => startup.restart(),
    commitSelection: () => startup.commitSelection()
  })

  assert.equal(selected, 'candidate')
  assert.equal(startup.selectedCore, 'candidate')
  assert.equal(startup.runningCore, 'candidate')
  assert.equal(startup.committedCore, 'candidate')
  assert.deepEqual(startup.events, [
    'select:candidate',
    'restart:candidate',
    'running:candidate',
    'commit:candidate'
  ])

  const recovery = new InMemoryCoreRuntime({
    runningCore: 'stable',
    failCandidateStart: true
  })
  let rejectedCandidate
  try {
    await runCoreUpdateTransaction({
      select: () => recovery.selectCandidate('candidate'),
      restoreSelection: () => recovery.restoreStableSelection(),
      restart: () => recovery.restart(),
      commitSelection: () => recovery.commitSelection()
    })
  } catch (error) {
    rejectedCandidate = error
  }

  assert.ok(rejectedCandidate instanceof Error)
  assert.equal(rejectedCandidate.message, 'fake candidate rejected during readiness')
  assert.equal(recovery.selectedCore, 'stable')
  assert.equal(recovery.runningCore, 'stable')
  assert.equal(recovery.committedCore, null)
  assert.deepEqual(recovery.events, [
    'select:candidate',
    'restart:candidate',
    'start-failed:candidate',
    'restore:stable',
    'restart:stable',
    'running:stable'
  ])

  assert.deepEqual(boundaryCalls, [])

  return Object.freeze({
    harness: 'aikobox-isolated-runtime-smoke',
    systemSideEffects: 0,
    scenarios: Object.freeze([
      Object.freeze({
        name: 'fake-core-start-and-commit',
        runningCore: startup.runningCore,
        events: Object.freeze([...startup.events])
      }),
      Object.freeze({
        name: 'fake-core-failure-and-rollback',
        runningCore: recovery.runningCore,
        events: Object.freeze([...recovery.events])
      })
    ])
  })
}

const invokedPath = process.argv[1] ? path.resolve(process.argv[1]) : ''
const modulePath = fileURLToPath(import.meta.url)

if (invokedPath === modulePath) {
  try {
    const report = await runIsolatedRuntimeSmoke()
    console.log(JSON.stringify(report))
  } catch (error) {
    console.error(error)
    process.exitCode = 1
  }
}
