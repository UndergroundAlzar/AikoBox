import { describe, expect, it, vi } from 'vitest'
import { runProfileBatchUpdate } from './profile-batch-update'

function profile(
  id: string,
  type: IProfileItem['type'] = 'remote',
  pluginId?: string
): IProfileItem {
  return { id, type, name: id, pluginId }
}

describe('profile batch update', () => {
  it('updates eligible profiles sequentially with the active profile last', async () => {
    const order: string[] = []
    let inFlight = 0
    let maxInFlight = 0
    const update = vi.fn(async (item: IProfileItem) => {
      inFlight += 1
      maxInFlight = Math.max(maxInFlight, inFlight)
      order.push(item.id)
      await Promise.resolve()
      inFlight -= 1
    })

    const result = await runProfileBatchUpdate(
      [
        profile('active'),
        profile('local', 'local'),
        profile('plugin', 'plugin', 'p1'),
        profile('other')
      ],
      'active',
      update
    )

    expect(order).toEqual(['plugin', 'other', 'active'])
    expect(maxInFlight).toBe(1)
    expect(result).toEqual({ total: 3, succeeded: 3, failed: 0, failures: [] })
  })

  it('continues after failures and returns a useful summary', async () => {
    const result = await runProfileBatchUpdate(
      [profile('broken'), profile('good'), profile('incomplete-plugin', 'plugin')],
      undefined,
      async (item) => {
        if (item.id === 'broken') throw new Error('subscription rejected')
      }
    )

    expect(result).toEqual({
      total: 2,
      succeeded: 1,
      failed: 1,
      failures: [{ id: 'broken', name: 'broken', kind: 'unknown' }]
    })
  })

  it('keeps only a safe error category instead of a raw message', async () => {
    const result = await runProfileBatchUpdate(
      [profile('plugin', 'plugin', 'p1'), profile('remote')],
      undefined,
      async (item) => {
        if (item.id === 'plugin') {
          throw new Error('PLUGIN_UPDATE_REAUTH_REQUIRED: https://secret.example/?token=leak')
        }
        throw new Error('fetch failed for https://token@example.invalid/private')
      }
    )

    expect(result.failures).toEqual([
      { id: 'plugin', name: 'plugin', kind: 'authentication' },
      { id: 'remote', name: 'remote', kind: 'network' }
    ])
    expect(JSON.stringify(result)).not.toContain('secret.example')
    expect(JSON.stringify(result)).not.toContain('token@example')
  })
})
