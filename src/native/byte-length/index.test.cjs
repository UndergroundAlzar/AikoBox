'use strict'

const assert = require('node:assert/strict')
const test = require('node:test')
const { byteLength } = require('./index.cjs')

test('matches Node UTF-8 byte length for representative WebDAV inputs', () => {
  for (const value of ['a', 'AikoBox', '¢', '中文', '😀', 'a\0b', '\ud800', '\udc00']) {
    assert.equal(byteLength(value), Buffer.byteLength(value, 'utf8'))
  }
})

test('preserves byte-length 1.0.2 falsy-input compatibility', () => {
  for (const value of ['', null, undefined, false, 0, Number.NaN]) {
    assert.equal(byteLength(value), 0)
  }
})

test('coerces other values to strings', () => {
  assert.equal(byteLength(123), 3)
  assert.equal(byteLength(true), 4)
})
