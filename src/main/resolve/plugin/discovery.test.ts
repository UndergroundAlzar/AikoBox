/* eslint-disable import/order -- Vitest mocks must be installed before loading the module under test. */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const requestOnce = vi.fn()
vi.mock('./http-client', () => ({ requestOnce: (...a: unknown[]) => requestOnce(...a) }))
import { discoverGateway } from './discovery'

const OK = {
  spec: 'cpx-plugin/2',
  gateway: 'https://gw.front.com',
  endpoints: { enroll: '/enroll', challenge: '/challenge', config: '/config', revoke: '/revoke' }
}
function reply(body: unknown, status = 200): void {
  requestOnce.mockResolvedValueOnce({ status, headers: {}, body: JSON.stringify(body) })
}
const NET = { timeout: 5000 }

beforeEach(() => requestOnce.mockReset())

describe('discoverGateway', () => {
  it('fetches the exact loginUrl host well-known and returns parsed gateway', async () => {
    reply(OK)
    const wk = await discoverGateway('https://panel.xx.com/oauth/authorize', NET)
    expect(requestOnce).toHaveBeenCalledWith(
      'https://panel.xx.com/.well-known/cpx-gateway',
      expect.objectContaining({ method: 'GET' })
    )
    expect(wk.gateway).toBe('https://gw.front.com')
    expect(wk.endpoints.config).toBe('/config')
  })
  it('rejects non-https gateway', async () => {
    reply({ ...OK, gateway: 'http://gw.front.com' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects gateway with a path', async () => {
    reply({ ...OK, gateway: 'https://gw.front.com/base' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects gateway with query/fragment', async () => {
    reply({ ...OK, gateway: 'https://gw.front.com/?x=1' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects a private-IP gateway literal', async () => {
    reply({ ...OK, gateway: 'https://127.0.0.1' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects a localhost gateway', async () => {
    reply({ ...OK, gateway: 'https://localhost' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects a *.localhost gateway', async () => {
    reply({ ...OK, gateway: 'https://gw.localhost' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects a gateway with userinfo', async () => {
    reply({ ...OK, gateway: 'https://u:p@gw.front.com' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects an absolute endpoint url', async () => {
    reply({ ...OK, endpoints: { ...OK.endpoints, config: 'https://evil.com/c' } })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects an endpoint not starting with /', async () => {
    reply({ ...OK, endpoints: { ...OK.endpoints, config: 'config' } })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects wrong spec', async () => {
    reply({ ...OK, spec: 'cpx-plugin/1' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects malformed JSON body', async () => {
    requestOnce.mockResolvedValueOnce({ status: 200, headers: {}, body: 'nope' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
  it('rejects non-2xx status', async () => {
    requestOnce.mockResolvedValueOnce({ status: 404, headers: {}, body: '{}' })
    await expect(discoverGateway('https://panel.xx.com/a', NET)).rejects.toThrow()
  })
})
