import { test } from 'node:test'
import assert from 'node:assert/strict'
import { createRateLimiter } from './ratelimit.mjs'

test('allows up to max hits then blocks within the window', () => {
  const limiter = createRateLimiter({ max: 3, windowMs: 1000, now: () => 0 })
  assert.equal(limiter.hit('ip'), true)
  assert.equal(limiter.hit('ip'), true)
  assert.equal(limiter.hit('ip'), true)
  assert.equal(limiter.hit('ip'), false)
})

test('resets after the window elapses', () => {
  let now = 0
  const limiter = createRateLimiter({ max: 1, windowMs: 1000, now: () => now })
  assert.equal(limiter.hit('ip'), true)
  assert.equal(limiter.hit('ip'), false)
  now = 1001
  assert.equal(limiter.hit('ip'), true)
})

test('tracks keys independently', () => {
  const limiter = createRateLimiter({ max: 1, windowMs: 1000, now: () => 0 })
  assert.equal(limiter.hit('a'), true)
  assert.equal(limiter.hit('b'), true)
  assert.equal(limiter.hit('a'), false)
})

test('rate limiter rejects new rotating keys at the memory bound', () => {
  let now = 0
  const limiter = createRateLimiter({ max: 2, windowMs: 1000, maxKeys: 2, now: () => now })

  assert.equal(limiter.hit('a'), true)
  assert.equal(limiter.hit('b'), true)
  assert.equal(limiter.hit('c'), false)
  assert.equal(limiter.size(), 2)

  now = 1000
  assert.equal(limiter.hit('c'), true)
  assert.equal(limiter.size(), 1)
})

test('rate limiter keeps enforcing the per-key attempt cap', () => {
  const limiter = createRateLimiter({ max: 1, windowMs: 1000, now: () => 0 })
  assert.equal(limiter.hit('account'), true)
  assert.equal(limiter.hit('account'), false)
})
