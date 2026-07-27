import { test } from 'node:test'
import assert from 'node:assert/strict'
import { Readable } from 'node:stream'
import { readBody, parseForm, parseJson, clientIp, sendJson } from './http.mjs'

test('parseForm decodes url-encoded fields', () => {
  const o = parseForm('username=a%40b&password=p+q&state=xyz')
  assert.deepEqual(o, { username: 'a@b', password: 'p q', state: 'xyz' })
})

test('parseJson returns the object or undefined on bad input', () => {
  assert.deepEqual(parseJson('{"a":1}'), { a: 1 })
  assert.equal(parseJson('{nope'), undefined)
  assert.equal(parseJson('"scalar"'), undefined) // non-object
})

test('readBody returns the body under the cap', async () => {
  const req = Readable.from([Buffer.from('hello '), Buffer.from('world')])
  assert.equal(await readBody(req, 1024), 'hello world')
})

test('readBody rejects a body over the cap', async () => {
  const req = Readable.from([Buffer.from('x'.repeat(100))])
  await assert.rejects(readBody(req, 10), /too large/)
})

test('clientIp ignores X-Forwarded-For from an untrusted socket', () => {
  assert.equal(
    clientIp({
      headers: { 'x-forwarded-for': '9.9.9.9' },
      socket: { remoteAddress: '203.0.113.5' }
    }),
    '203.0.113.5'
  )
})

test('clientIp accepts Caddy-overwritten X-Forwarded-For only from a trusted CIDR', () => {
  assert.equal(
    clientIp(
      { headers: { 'x-forwarded-for': '9.9.9.9' }, socket: { remoteAddress: '172.31.238.2' } },
      ['172.31.238.2/32']
    ),
    '9.9.9.9'
  )
  assert.equal(
    clientIp(
      {
        headers: { 'x-forwarded-for': '8.8.8.8' },
        socket: { remoteAddress: '::ffff:172.31.238.2' }
      },
      ['172.31.238.0/24']
    ),
    '8.8.8.8'
  )
  assert.equal(
    clientIp(
      { headers: { 'x-forwarded-for': '2001:db8::9' }, socket: { remoteAddress: 'fd00::2' } },
      ['fd00::/64']
    ),
    '2001:db8::9'
  )
})

test('clientIp falls back safely for a malformed forwarded value or missing socket', () => {
  assert.equal(
    clientIp(
      { headers: { 'x-forwarded-for': 'not-an-ip' }, socket: { remoteAddress: '172.31.238.2' } },
      ['172.31.238.2/32']
    ),
    '172.31.238.2'
  )
  assert.equal(clientIp({ headers: {}, socket: { remoteAddress: '1.2.3.4' } }), '1.2.3.4')
  assert.equal(clientIp({ headers: { 'x-forwarded-for': '9.9.9.9' }, socket: {} }), 'unknown')
})

test('sendJson writes status, json content-type, and the serialized body', () => {
  const res = mockRes()
  sendJson(res, 403, { error: 'x' })
  assert.equal(res.status, 403)
  assert.match(res.headers['content-type'], /application\/json/)
  assert.deepEqual(JSON.parse(res.body), { error: 'x' })
})

function mockRes() {
  const r = { status: 0, headers: {}, body: '' }
  r.writeHead = (s, h) => {
    r.status = s
    r.headers = h || {}
    return r
  }
  r.end = (b) => {
    r.body = b ?? ''
  }
  return r
}
