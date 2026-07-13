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

  it('truncates profile names longer than 120 characters', async () => {
    mocks.response = 1
    const target = 'https://airport.example/sub'
    const longName = 'n'.repeat(150)
    const link = `aikobox://install-config?url=${encodeURIComponent(target)}&name=${encodeURIComponent(longName)}`
    await handleDeepLink(link)
    expect(mocks.addProfileItem).toHaveBeenCalledWith(
      expect.objectContaining({
        type: 'remote',
        url: target,
        name: longName.slice(0, 120)
      })
    )
    expect(mocks.addProfileItem.mock.calls[0][0].name).toHaveLength(120)
  })

  it('no-ops for unknown deep-link hosts', async () => {
    await handleDeepLink(
      `aikobox://unknown-action?url=${encodeURIComponent('https://airport.example/sub')}`
    )
    expect(mocks.showMessageBox).not.toHaveBeenCalled()
    expect(mocks.addProfileItem).not.toHaveBeenCalled()
    expect(mocks.showError).not.toHaveBeenCalled()
  })

  it.each(['clash://', 'mihomo://'] as const)(
    'accepts %sinstall-config deep links',
    async (scheme) => {
      mocks.response = 1
      const target = 'https://airport.example/sub?token=secret'
      const link = `${scheme}install-config?url=${encodeURIComponent(target)}`
      await handleDeepLink(link)
      expect(mocks.showMessageBox).toHaveBeenCalledOnce()
      expect(mocks.addProfileItem).toHaveBeenCalledWith(
        expect.objectContaining({ type: 'remote', url: target })
      )
    }
  )

  it.each([
    'https://10.0.0.5/sub?token=secret',
    'https://169.254.1.1/sub?token=secret',
    'https://localhost/sub?token=secret',
    'https://user:pass@airport.example/sub?token=secret'
  ])('rejects private/local/credentialed target %s', async (target) => {
    await handleDeepLink(`aikobox://install-config?url=${encodeURIComponent(target)}`)
    expect(mocks.showMessageBox).not.toHaveBeenCalled()
    expect(mocks.addProfileItem).not.toHaveBeenCalled()
    expect(mocks.showError).toHaveBeenCalledOnce()
    expect(String(mocks.showError.mock.calls[0]?.[1])).not.toContain('secret')
    expect(String(mocks.showError.mock.calls[0]?.[1])).not.toContain('pass')
  })

  it('rejects install-config links that omit the url parameter', async () => {
    await handleDeepLink('aikobox://install-config?name=missing-url')
    expect(mocks.showMessageBox).not.toHaveBeenCalled()
    expect(mocks.addProfileItem).not.toHaveBeenCalled()
    expect(mocks.showError).toHaveBeenCalledOnce()
  })
})
