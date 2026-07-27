import { describe, expect, it, vi } from 'vitest'
import { saveSysProxySettings } from './sysproxy-save'

describe('saveSysProxySettings', () => {
  it.each([false, true])('preserves enable=%s while applying edited settings', async (enable) => {
    const sysProxy = {
      enable,
      host: '127.0.0.1',
      bypass: ['localhost'],
      mode: 'manual' as const,
      pacScript: ''
    }
    const patchAppConfig = vi.fn(async () => undefined)
    const applySysProxy = vi.fn(async () => undefined)

    await saveSysProxySettings(sysProxy, patchAppConfig, applySysProxy)

    expect(patchAppConfig).toHaveBeenCalledOnce()
    expect(patchAppConfig).toHaveBeenCalledWith({ sysProxy })
    expect(applySysProxy).toHaveBeenCalledOnce()
    expect(applySysProxy).toHaveBeenCalledWith(enable)
  })

  it('does not rewrite the persisted switch when applying the proxy fails', async () => {
    const sysProxy = {
      enable: false,
      host: '',
      bypass: [],
      mode: 'auto' as const,
      pacScript: 'function FindProxyForURL() { return "DIRECT"; }'
    }
    const patchAppConfig = vi.fn(async () => undefined)
    const applySysProxy = vi.fn(async () => {
      throw new Error('WinINET failed')
    })

    await expect(saveSysProxySettings(sysProxy, patchAppConfig, applySysProxy)).rejects.toThrow(
      'WinINET failed'
    )
    expect(patchAppConfig).toHaveBeenCalledTimes(1)
  })
})
