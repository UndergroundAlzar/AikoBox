import { readFileSync } from 'fs'
import { fileURLToPath } from 'url'
import { describe, expect, it } from 'vitest'
import { SerialTaskQueue } from './serialTaskQueue'

const managerSource = readFileSync(
  fileURLToPath(new URL('./manager.ts', import.meta.url)),
  'utf8'
).replace(/\r\n/g, '\n')
const indexSource = readFileSync(
  fileURLToPath(new URL('../index.ts', import.meta.url)),
  'utf8'
).replace(/\r\n/g, '\n')

describe('core startup serialization', () => {
  it('keeps initial startup and restart work mutually exclusive', async () => {
    const queue = new SerialTaskQueue()
    const events: string[] = []
    let activeStarts = 0
    let maximumConcurrentStarts = 0
    let releaseInitialStart!: () => void
    const initialStartGate = new Promise<void>((resolve) => {
      releaseInitialStart = resolve
    })

    const runStart = async (name: string, gate?: Promise<void>): Promise<void> => {
      activeStarts++
      maximumConcurrentStarts = Math.max(maximumConcurrentStarts, activeStarts)
      events.push(`${name}:start`)
      await gate
      events.push(`${name}:end`)
      activeStarts--
    }

    const initialStart = queue.enqueue(() => runStart('initial', initialStartGate))
    const restart = queue.enqueue(() => runStart('restart'))

    await Promise.resolve()
    expect(events).toEqual(['initial:start'])

    releaseInitialStart()
    await Promise.all([initialStart, restart])
    expect(events).toEqual(['initial:start', 'initial:end', 'restart:start', 'restart:end'])
    expect(maximumConcurrentStarts).toBe(1)
  })

  it('routes every public startup path through the shared queue', () => {
    expect(indexSource).toContain('startCoreQueued')
    expect(indexSource).not.toMatch(/\bstartCore\s*\(/)
    expect(managerSource).toContain('async function startCore(')
    expect(managerSource).not.toContain('export async function startCore(')
    expect(managerSource).toContain('await startCoreQueued(true)')

    const directStartCalls = managerSource.match(/\bstartCore\s*\(/g) ?? []
    expect(directStartCalls).toHaveLength(3)
  })

  it('keeps normal system-proxy activation outside the core retry attempt', () => {
    const restartStart = managerSource.indexOf('async function performRestart()')
    const restartEnd = managerSource.indexOf('\nexport function startCoreQueued', restartStart)
    const restartSource = managerSource.slice(restartStart, restartEnd)
    const coreAttemptStart = restartSource.indexOf('startCore: async () =>')
    const proxyBoundary = restartSource.indexOf('applySystemProxy: async () =>', coreAttemptStart)
    const coreAttempt = restartSource.slice(coreAttemptStart, proxyBoundary)

    expect(restartSource).toContain('await runRestartTransaction({')
    expect(coreAttempt).toContain('await startCore(false, false, true)')
    expect(coreAttempt).not.toContain('triggerSysProxy')

    const proxyCallbackEnd = restartSource.indexOf('isTerminalStartError:', proxyBoundary)
    const proxyCallback = restartSource.slice(proxyBoundary, proxyCallbackEnd)
    expect(proxyCallback).toContain('await triggerSysProxy(true)')
  })
})
