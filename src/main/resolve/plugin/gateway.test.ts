/* eslint-disable import/order -- Vitest mocks must be installed before loading the module under test. */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const requestOnce = vi.fn()
vi.mock('./http-client', () => ({ requestOnce: (...a: unknown[]) => requestOnce(...a) }))
import { enroll, challenge, fetchConfig, revoke } from './gateway'
import { generateDevice, buildSignInput, verifyRequest, OP_CONFIG, OP_REVOKE } from './device'

const TARGET = {
  gateway: 'https://gw.front.com',
  endpoints: { enroll: '/enroll', challenge: '/challenge', config: '/config', revoke: '/revoke' }
}
const NET = { timeout: 5000 }
const CLASH =
  'proxies:\n  - {name: a, type: ss, server: 1.1.1.1, port: 8388, cipher: aes-128-gcm, password: x}\n'

function jsonReply(body: unknown, status = 200): void {
  requestOnce.mockResolvedValueOnce({ status, headers: {}, body: JSON.stringify(body) })
}
function rawReply(body: string, status = 200): void {
  requestOnce.mockResolvedValueOnce({ status, headers: {}, body })
}
function lastBody(): Record<string, string | number> {
  const call = requestOnce.mock.calls[requestOnce.mock.calls.length - 1]
  return JSON.parse((call[1] as { body: string }).body) as Record<string, string | number>
}

beforeEach(() => requestOnce.mockReset())

describe('gateway.enroll', () => {
  it('posts code+verifier+redirect+client+pubKey+deviceId, resolves on ok', async () => {
    jsonReply({ ok: true })
    await enroll(
      TARGET,
      {
        code: 'C',
        code_verifier: 'V',
        redirect_uri: 'http://127.0.0.1:5/callback',
        client_id: 'mihomo-party',
        devicePubKey: 'PUB',
        deviceId: 'DID'
      },
      NET
    )
    expect(requestOnce).toHaveBeenCalledWith('https://gw.front.com/enroll', expect.any(Object))
    expect(lastBody()).toMatchObject({ code: 'C', code_verifier: 'V', deviceId: 'DID' })
  })
  it('maps explicit revoked to GatewayError(revoked)', async () => {
    jsonReply({ error: 'revoked' }, 403)
    await expect(enroll(TARGET, {} as never, NET)).rejects.toMatchObject({ kind: 'revoked' })
  })
})

describe('gateway.challenge', () => {
  it('returns nonceId/nonce/exp', async () => {
    jsonReply({ nonceId: 'N1', nonce: Buffer.alloc(32, 1).toString('base64'), exp: 60 })
    const c = await challenge(TARGET, 'DID', NET)
    expect(c.nonceId).toBe('N1')
    expect(Buffer.from(c.nonce, 'base64')).toHaveLength(32)
  })
  it('rejects a nonce that is not 32 bytes as transient', async () => {
    jsonReply({ nonceId: 'N1', nonce: Buffer.alloc(16, 1).toString('base64'), exp: 60 })
    await expect(challenge(TARGET, 'DID', NET)).rejects.toMatchObject({ kind: 'transient' })
  })
  it('rejects a non-base64 nonce as transient', async () => {
    jsonReply({ nonceId: 'N1', nonce: 'not base64 !!!', exp: 60 })
    await expect(challenge(TARGET, 'DID', NET)).rejects.toMatchObject({ kind: 'transient' })
  })
  it('rejects a nonceId with control/whitespace chars as transient', async () => {
    jsonReply({ nonceId: 'bad\nid', nonce: Buffer.alloc(32, 1).toString('base64'), exp: 60 })
    await expect(challenge(TARGET, 'DID', NET)).rejects.toMatchObject({ kind: 'transient' })
  })
})

describe('gateway.fetchConfig', () => {
  it('challenge→signed config; signature verifies against device pubkey; returns YAML', async () => {
    const dev = generateDevice()
    const nonceBuf = Buffer.alloc(32, 9)
    jsonReply({ nonceId: 'N1', nonce: nonceBuf.toString('base64'), exp: 60 })
    rawReply(CLASH)
    const yaml = await fetchConfig(
      TARGET,
      { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 },
      NET
    )
    expect(yaml).toBe(CLASH)
    const body = lastBody()
    expect(body).toMatchObject({ deviceId: dev.deviceId, nonceId: 'N1' })
    const input = buildSignInput(OP_CONFIG, dev.deviceId, 'N1', nonceBuf, body.ts)
    expect(verifyRequest(dev.pubKeyB64, input, body.sig)).toBe(true)
  })
  it('rejects a non-clash config body as transient', async () => {
    const dev = generateDevice()
    jsonReply({ nonceId: 'N1', nonce: Buffer.alloc(32).toString('base64'), exp: 60 })
    rawReply('just text')
    await expect(
      fetchConfig(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    ).rejects.toMatchObject({ kind: 'transient' })
  })
  it('maps 410 to GatewayError(retired)', async () => {
    const dev = generateDevice()
    jsonReply({ nonceId: 'N1', nonce: Buffer.alloc(32).toString('base64'), exp: 60 })
    rawReply('', 410)
    await expect(
      fetchConfig(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    ).rejects.toMatchObject({ kind: 'retired' })
  })
  it('maps gateway_retired json marker to retired', async () => {
    const dev = generateDevice()
    jsonReply({ error: 'gateway_retired' }, 200)
    await expect(
      fetchConfig(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    ).rejects.toMatchObject({ kind: 'retired' })
  })
  it('maps 5xx to transient', async () => {
    const dev = generateDevice()
    jsonReply({ nonceId: 'N1', nonce: Buffer.alloc(32).toString('base64'), exp: 60 })
    rawReply('', 503)
    await expect(
      fetchConfig(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    ).rejects.toMatchObject({ kind: 'transient' })
  })
  it('maps a DNS failure (ENOTFOUND) to unreachable', async () => {
    const dev = generateDevice()
    requestOnce.mockRejectedValueOnce(
      Object.assign(new Error('getaddrinfo ENOTFOUND gw.front.com'), { code: 'ENOTFOUND' })
    )
    await expect(
      fetchConfig(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    ).rejects.toMatchObject({ kind: 'unreachable' })
  })
  it('maps a connection refused (ECONNREFUSED) to unreachable', async () => {
    const dev = generateDevice()
    requestOnce.mockRejectedValueOnce(
      Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' })
    )
    await expect(
      fetchConfig(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    ).rejects.toMatchObject({ kind: 'unreachable' })
  })
  it('maps a TLS failure code to unreachable', async () => {
    const dev = generateDevice()
    requestOnce.mockRejectedValueOnce(
      Object.assign(new Error('certificate has expired'), { code: 'CERT_HAS_EXPIRED' })
    )
    await expect(
      fetchConfig(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    ).rejects.toMatchObject({ kind: 'unreachable' })
  })
  it('maps a timeout/generic error (no network code) to transient', async () => {
    const dev = generateDevice()
    requestOnce.mockRejectedValueOnce(new Error('Request timed out'))
    await expect(
      fetchConfig(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    ).rejects.toMatchObject({ kind: 'transient' })
  })
})

describe('gateway.revoke', () => {
  it('signs op=revoke and posts; idempotent ok', async () => {
    const dev = generateDevice()
    const nonceBuf = Buffer.alloc(32, 3)
    jsonReply({ nonceId: 'N1', nonce: nonceBuf.toString('base64'), exp: 60 })
    jsonReply({ ok: true })
    await revoke(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    const body = lastBody()
    const input = buildSignInput(OP_REVOKE, dev.deviceId, 'N1', nonceBuf, body.ts)
    expect(verifyRequest(dev.pubKeyB64, input, body.sig)).toBe(true)
  })
})

describe('gateway encoding/timestamp', () => {
  it('nonce is echoed back as the same base64 string; ts is integer ms', async () => {
    const dev = generateDevice()
    const nonceB64 = Buffer.alloc(32, 5).toString('base64')
    jsonReply({ nonceId: 'N1', nonce: nonceB64, exp: 60 })
    rawReply(CLASH)
    const before = Date.now()
    await fetchConfig(TARGET, { deviceId: dev.deviceId, privKeyB64: dev.privKeyB64 }, NET)
    const body = lastBody()
    expect(body.nonce).toBe(nonceB64)
    expect(Number.isInteger(body.ts)).toBe(true)
    expect(body.ts).toBeGreaterThanOrEqual(before)
  })
})

describe('gateway urlOf host-escape defense', () => {
  it('refuses an endpoint that escapes the gateway origin (backslash) before any request', async () => {
    const evil = {
      gateway: 'https://gw.front.com',
      endpoints: { enroll: '/e', challenge: '/\\evil.example/c', config: '/cfg', revoke: '/r' }
    }
    requestOnce.mockClear()
    await expect(challenge(evil, 'DID', NET)).rejects.toMatchObject({ kind: 'transient' })
    expect(requestOnce).not.toHaveBeenCalled()
  })
})
