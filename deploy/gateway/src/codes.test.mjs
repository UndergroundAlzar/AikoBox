import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createCodeStore } from './codes.mjs'

const payload = {
  username: 'alice',
  redirect_uri: 'http://127.0.0.1:5000/callback',
  client_id: 'mihomo-party',
  code_challenge: 'abc'
}

test('issue returns a high-entropy base64url code', () => {
  const store = createCodeStore()
  const code = store.issue(payload)
  assert.match(code, /^[A-Za-z0-9_-]{40,}$/)
})

test('consume returns the payload exactly once (one-time)', () => {
  const store = createCodeStore()
  const code = store.issue(payload)
  assert.deepEqual(store.consume(code), payload)
  assert.equal(store.consume(code), undefined)
})

test('consume of an unknown code returns undefined', () => {
  const store = createCodeStore()
  assert.equal(store.consume('nope'), undefined)
})

test('an expired code is not consumable', () => {
  let clock = 1000
  const store = createCodeStore({ ttlMs: 60000, now: () => clock })
  const code = store.issue(payload)
  clock += 60001
  assert.equal(store.consume(code), undefined)
})

test('a code just inside the TTL is still consumable', () => {
  let clock = 1000
  const store = createCodeStore({ ttlMs: 60000, now: () => clock })
  const code = store.issue(payload)
  clock += 59999
  assert.deepEqual(store.consume(code), payload)
})

test('two issued codes are distinct', () => {
  const store = createCodeStore()
  assert.notEqual(store.issue(payload), store.issue(payload))
})

test('automatically sweeps expired abandoned codes on the scheduled interval', () => {
  let clock = 1000
  let scheduledSweep
  let cleared
  const timer = {
    unrefCalled: false,
    unref() {
      this.unrefCalled = true
    }
  }
  const store = createCodeStore({
    ttlMs: 100,
    maxSize: 10,
    sweepIntervalMs: 25,
    now: () => clock,
    setIntervalFn: (callback, interval) => {
      assert.equal(interval, 25)
      scheduledSweep = callback
      return timer
    },
    clearIntervalFn: (value) => {
      cleared = value
    }
  })

  store.issue(payload)
  store.issue(payload)
  assert.equal(store.size(), 2)
  clock += 101
  scheduledSweep()
  assert.equal(store.size(), 0)
  assert.equal(timer.unrefCalled, true)

  store.close()
  assert.equal(cleared, timer)
})

test('a large volume of abandoned login codes never exceeds the hard capacity', () => {
  const store = createCodeStore({ maxSize: 256 })
  let accepted = 0
  let rejected = 0

  for (let i = 0; i < 100000; i += 1) {
    if (store.issue({ ...payload, attempt: i })) accepted += 1
    else rejected += 1
  }

  assert.equal(accepted, 256)
  assert.equal(rejected, 99744)
  assert.equal(store.size(), 256)
})

test('capacity pressure sweeps expired codes before safely rejecting issuance', () => {
  let clock = 1000
  const store = createCodeStore({ ttlMs: 100, maxSize: 2, now: () => clock })
  assert.ok(store.issue(payload))
  assert.ok(store.issue(payload))
  assert.equal(store.issue(payload), undefined)
  assert.equal(store.size(), 2)

  clock += 101
  assert.ok(store.issue({ ...payload, username: 'bob' }))
  assert.equal(store.size(), 1)
})

test('rejects invalid capacity and timer settings', () => {
  assert.throws(() => createCodeStore({ maxSize: 0 }), /maxSize/)
  assert.throws(() => createCodeStore({ maxSize: 1.5 }), /maxSize/)
  assert.throws(() => createCodeStore({ ttlMs: 0 }), /ttlMs/)
  assert.throws(() => createCodeStore({ sweepIntervalMs: 0 }), /sweepIntervalMs/)
})
