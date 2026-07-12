import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'
import { runIsolatedRuntimeSmoke } from './runtime-smoke.mjs'

describe('isolated fake-core runtime smoke', () => {
  it('starts a fake candidate and restores the stable core after readiness failure', async () => {
    const report = await runIsolatedRuntimeSmoke()

    expect(report.systemSideEffects).toBe(0)
    expect(report.scenarios).toEqual([
      {
        name: 'fake-core-start-and-commit',
        runningCore: 'candidate',
        events: ['select:candidate', 'restart:candidate', 'running:candidate', 'commit:candidate']
      },
      {
        name: 'fake-core-failure-and-rollback',
        runningCore: 'stable',
        events: [
          'select:candidate',
          'restart:candidate',
          'start-failed:candidate',
          'restore:stable',
          'restart:stable',
          'running:stable'
        ]
      }
    ])
  })

  it('keeps the smoke harness free of process and Windows system-control imports', () => {
    const source = [
      readFileSync(fileURLToPath(new URL('./runtime-smoke.mjs', import.meta.url)), 'utf8'),
      readFileSync(
        fileURLToPath(new URL('../src/main/core/coreUpdateTransaction.ts', import.meta.url)),
        'utf8'
      )
    ].join('\n')
    const imports = source.match(/^import .*$/gm)?.join('\n') ?? ''

    expect(imports).not.toMatch(/(?:node:)?(?:child_process|fs|http|https)|electron|undici/i)
    expect(imports).not.toMatch(/sysproxy|winreg|registry|powershell|netsh|tun/i)
    expect(source).not.toMatch(
      /\b(?:spawn|exec|execFile|fork)(?:Sync)?\s*\(|process\.kill|\.kill\s*\(/
    )
  })
})
