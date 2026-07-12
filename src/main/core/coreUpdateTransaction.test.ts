import { describe, expect, it, vi } from 'vitest'
import { runCoreUpdateTransaction } from './coreUpdateTransaction'

describe('core update transaction', () => {
  it('returns only after the selected core restarts successfully', async () => {
    const restart = vi.fn(async () => {})
    const commitSelection = vi.fn(async () => {})
    await expect(
      runCoreUpdateTransaction({
        select: async () => '1.2.3',
        restoreSelection: async () => {},
        restart,
        commitSelection
      })
    ).resolves.toBe('1.2.3')
    expect(restart).toHaveBeenCalledOnce()
    expect(commitSelection).toHaveBeenCalledOnce()
  })

  it('restores the old selection and restarts it when the update fails', async () => {
    const order: string[] = []
    const failure = new Error('new core failed')
    const restart = vi
      .fn()
      .mockImplementationOnce(async () => {
        order.push('new')
        throw failure
      })
      .mockImplementationOnce(async () => {
        order.push('old')
      })

    await expect(
      runCoreUpdateTransaction({
        select: async () => {
          order.push('select')
          return 'new'
        },
        restoreSelection: async () => {
          order.push('restore')
        },
        restart
      })
    ).rejects.toBe(failure)
    expect(order).toEqual(['select', 'new', 'restore', 'old'])
  })

  it('reports both failures when the restored core cannot be restarted', async () => {
    const updateFailure = new Error('new core failed')
    const recoveryFailure = new Error('old core also failed')
    const onRecoveryRestartError = vi.fn()
    const restart = vi
      .fn()
      .mockRejectedValueOnce(updateFailure)
      .mockRejectedValueOnce(recoveryFailure)

    const failure = await runCoreUpdateTransaction({
      select: async () => 'new',
      restoreSelection: async () => {},
      restart,
      onRecoveryRestartError
    }).catch((error) => error)

    expect(failure).toBeInstanceOf(AggregateError)
    expect((failure as AggregateError).errors).toEqual([updateFailure, recoveryFailure])
    expect(onRecoveryRestartError).toHaveBeenCalledWith(recoveryFailure)
  })
})
