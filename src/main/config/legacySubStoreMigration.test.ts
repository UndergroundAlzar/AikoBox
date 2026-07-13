import { describe, expect, it } from 'vitest'
import { migrateLegacySubStoreProfiles } from './legacySubStoreMigration'

describe('legacy Sub-Store profile migration', () => {
  it('converts only built-in origin-relative profiles and preserves every other field', () => {
    const config = {
      current: 'legacy',
      items: [
        {
          id: 'legacy',
          name: 'Cached legacy profile',
          type: 'remote' as const,
          url: '/download/abc?target=ClashMeta',
          substore: true,
          autoUpdate: true,
          interval: '*/5 * * * *',
          useProxy: true,
          override: ['rules'],
          updated: 123,
          home: 'https://example.invalid/home',
          extra: { upload: 1, download: 2, total: 3, expire: 4 }
        },
        {
          id: 'absolute',
          name: 'External Sub-Store URL',
          type: 'remote' as const,
          url: 'https://example.invalid/download/abc',
          substore: true,
          autoUpdate: true,
          interval: 30
        },
        {
          id: 'protocol-relative',
          name: 'Protocol relative URL',
          type: 'remote' as const,
          url: '//example.invalid/download/abc',
          substore: true,
          autoUpdate: true,
          interval: 30
        },
        {
          id: 'ordinary',
          name: 'Ordinary subscription',
          type: 'remote' as const,
          url: 'https://subscription.example/profile.yaml',
          autoUpdate: true,
          interval: 60
        }
      ]
    }

    const result = migrateLegacySubStoreProfiles(config)

    expect(result.changed).toBe(true)
    expect(result.config.current).toBe('legacy')
    expect(result.config.items[0]).toEqual({
      id: 'legacy',
      name: 'Cached legacy profile',
      type: 'local',
      url: '/download/abc?target=ClashMeta',
      autoUpdate: false,
      interval: 0,
      useProxy: true,
      override: ['rules'],
      updated: 123,
      home: 'https://example.invalid/home',
      extra: { upload: 1, download: 2, total: 3, expire: 4 }
    })
    expect(result.config.items.slice(1)).toEqual(config.items.slice(1))
  })

  it('is idempotent and returns the original object when nothing qualifies', () => {
    const original: IProfileConfig = {
      current: 'local',
      items: [{ id: 'local', name: 'Local', type: 'local', interval: 0 }]
    }

    const first = migrateLegacySubStoreProfiles(original)
    const second = migrateLegacySubStoreProfiles(first.config)

    expect(first.changed).toBe(false)
    expect(first.config).toBe(original)
    expect(second.changed).toBe(false)
    expect(second.config).toBe(original)
  })
})
