import { describe, expect, it, vi } from 'vitest'
import { recoverFromStoredCandidates } from './storedRecoveryPool'

describe('stored exact-endpoint recovery pool', () => {
  it('rotates from a failed LKG to active and publishes only after start proof', async () => {
    const events: string[] = []
    const recovered = await recoverFromStoredCandidates(['last-good', 'active'], {
      prepare: async (candidate) => {
        events.push(`prepare:${candidate}`)
        return candidate
      },
      startOnce: async (candidate) => {
        events.push(`start:${candidate}`)
        if (candidate === 'last-good') throw new Error('permanent runtime failure')
        return candidate
      },
      publish: async (candidate) => events.push(`publish:${candidate}`),
      resume: async (candidate) => events.push(`resume:${candidate}`)
    })

    expect(recovered).toBe('active')
    expect(events).toEqual([
      'prepare:last-good',
      'start:last-good',
      'prepare:active',
      'start:active',
      'publish:active',
      'resume:active'
    ])
  })

  it('keeps a proven endpoint usable when only persistence fails', async () => {
    const resume = vi.fn(async () => {})
    const onPublishError = vi.fn()
    await recoverFromStoredCandidates(['active'], {
      prepare: async (candidate) => candidate,
      startOnce: async (candidate) => candidate,
      publish: async () => {
        throw new Error('disk full')
      },
      resume,
      onPublishError
    })
    expect(onPublishError).toHaveBeenCalledOnce()
    expect(resume).toHaveBeenCalledWith('active')
  })
})
