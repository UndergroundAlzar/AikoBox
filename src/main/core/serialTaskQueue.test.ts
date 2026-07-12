import { describe, expect, it } from 'vitest'
import { SerialTaskQueue } from './serialTaskQueue'

describe('SerialTaskQueue', () => {
  it('runs concurrent requests in FIFO order', async () => {
    const queue = new SerialTaskQueue()
    const events: string[] = []
    let releaseFirst!: () => void
    const gate = new Promise<void>((resolve) => {
      releaseFirst = resolve
    })

    const first = queue.enqueue(async () => {
      events.push('first:start')
      await gate
      events.push('first:end')
    })
    const second = queue.enqueue(async () => {
      events.push('second')
    })

    await Promise.resolve()
    expect(queue.hasPending()).toBe(true)
    expect(events).toEqual(['first:start'])
    releaseFirst()
    await Promise.all([first, second])
    expect(events).toEqual(['first:start', 'first:end', 'second'])
    expect(queue.hasPending()).toBe(false)
  })

  it('continues after a rejected task', async () => {
    const queue = new SerialTaskQueue()
    await expect(
      queue.enqueue(async () => {
        throw new Error('failed')
      })
    ).rejects.toThrow('failed')
    await expect(queue.enqueue(async () => 'ok')).resolves.toBe('ok')
  })
})
