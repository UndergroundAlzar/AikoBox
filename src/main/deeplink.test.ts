/* eslint-disable import/order -- Vitest mocks must be installed before loading the module under test. */
import { beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  response: 0,
  showMessageBox: vi.fn(async () => ({ response: mocks.response })),
  addProfileItem: vi.fn(async () => {}),
  showError: vi.fn(),
  notify: vi.fn()
}))

vi.mock('electron', () => ({
  dialog: { showMessageBox: mocks.showMessageBox },
  Notification: class {
    show = mocks.notify
  }
}))

vi.mock('./config', () => ({ addProfileItem: mocks.addProfileItem }))
vi.mock('./window', () => ({ mainWindow: null }))
vi.mock('./utils/init', () => ({ safeShowErrorBox: mocks.showError }))
import { handleDeepLink } from './deeplink'

describe('deep-link subscription confirmation', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    mocks.response = 0
  })

  it('does not download until the user confirms a public HTTPS provider', async () => {
    const target = 'https://airport.example/sub?token=secret'
    const link = `aikobox://install-config?url=${encodeURIComponent(target)}`
    await handleDeepLink(link)
    expect(mocks.showMessageBox).toHaveBeenCalledOnce()
    expect(mocks.addProfileItem).not.toHaveBeenCalled()

    mocks.response = 1
    await handleDeepLink(link)
    expect(mocks.addProfileItem).toHaveBeenCalledWith(
      expect.objectContaining({ type: 'remote', url: target })
    )
  })

  it('rejects local/plaintext targets and never leaks the deep-link token to the error dialog', async () => {
    await handleDeepLink(
      `aikobox://install-config?url=${encodeURIComponent('http://127.0.0.1/sub?token=secret')}`
    )
    expect(mocks.showMessageBox).not.toHaveBeenCalled()
    expect(mocks.addProfileItem).not.toHaveBeenCalled()
    expect(String(mocks.showError.mock.calls[0]?.[1])).not.toContain('secret')
  })
})
