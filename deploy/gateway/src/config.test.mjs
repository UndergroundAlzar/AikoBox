import { test } from 'node:test'
import assert from 'node:assert/strict'
import { loadConfig } from './config.mjs'

test('applies sane defaults for an empty environment', () => {
  const c = loadConfig({})
  assert.equal(c.port, 8080)
  assert.equal(c.dbPath, '/data/gateway.db')
  assert.equal(c.deviceLimitDefault, 3)
  assert.equal(c.codeTtlMs, 60000)
  assert.equal(c.codePoolMax, 10000)
  assert.equal(c.nonceTtlMs, 60000)
  assert.equal(c.noncePoolMax, 8)
  assert.equal(c.clockSkewMs, 300000)
  assert.equal(c.loginMax, 10)
  assert.equal(c.loginWindowMs, 60000)
  assert.equal(c.loginAccountMax, 10)
  assert.equal(c.loginAccountWindowMs, 60000)
  assert.deepEqual(c.trustedProxyCidrs, [])
  assert.equal(c.subMaxBytes, 10485760)
  assert.equal(c.retired, false)
})

test('parses numeric overrides as numbers', () => {
  const c = loadConfig({
    PORT: '9000',
    CLOCK_SKEW_MS: '120000',
    CODE_POOL_MAX: '2048',
    NONCE_POOL_MAX: '4',
    LOGIN_ACCOUNT_MAX: '4'
  })
  assert.strictEqual(c.port, 9000)
  assert.strictEqual(c.clockSkewMs, 120000)
  assert.strictEqual(c.codePoolMax, 2048)
  assert.strictEqual(c.noncePoolMax, 4)
  assert.strictEqual(c.loginAccountMax, 4)
})

test('parses and trims trusted proxy CIDRs', () => {
  assert.deepEqual(
    loadConfig({ TRUSTED_PROXY_CIDRS: ' 172.31.238.2/32, ::1/128 ' }).trustedProxyCidrs,
    ['172.31.238.2/32', '::1/128']
  )
})

test('RETIRED is true only for the literal "true"', () => {
  assert.equal(loadConfig({ RETIRED: 'true' }).retired, true)
  assert.equal(loadConfig({ RETIRED: 'false' }).retired, false)
  assert.equal(loadConfig({ RETIRED: '1' }).retired, false)
})

test('derives publicOrigin from DOMAIN when PUBLIC_ORIGIN is unset', () => {
  assert.equal(loadConfig({ DOMAIN: 'gw.example.com' }).publicOrigin, 'https://gw.example.com')
  assert.equal(
    loadConfig({ DOMAIN: 'gw.example.com', PUBLIC_ORIGIN: 'https://other.example' }).publicOrigin,
    'https://other.example'
  )
})

test('the returned config object is frozen', () => {
  const c = loadConfig({})
  assert.throws(() => {
    c.port = 1
  })
})
