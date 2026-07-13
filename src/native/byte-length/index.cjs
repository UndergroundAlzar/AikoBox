'use strict'

function byteLength(value) {
  if (!value) return 0
  return Buffer.byteLength(String(value), 'utf8')
}

module.exports = { byteLength }
