import assert from 'node:assert/strict'
import test from 'node:test'

import { parseGoBuildInfo, sha256 } from './license-android-libbox.mjs'

test('parses libbox go build information', () => {
  const parsed = parseGoBuildInfo(`libbox.so: go1.24.7
\tpath\tgithub.com/sagernet/sing-box/build/arm64/libbox
\tmod\tgithub.com/sagernet/sing-box\t(devel)\t
\tdep\texample.com/module\tv1.2.3\th1:abc=
\tbuild\t-buildmode=c-shared
\tbuild\tGOARCH=arm64
\tbuild\tGOOS=android
`)
  assert.equal(parsed.goVersion, 'go1.24.7')
  assert.equal(parsed.mainModule, 'github.com/sagernet/sing-box\t(devel)')
  assert.deepEqual(parsed.modules, [['example.com/module', 'v1.2.3', 'h1:abc=']])
  assert.deepEqual(parsed.settings, ['-buildmode=c-shared', 'GOARCH=arm64', 'GOOS=android'])
})

test('rejects incomplete build information', () => {
  assert.throws(() => parseGoBuildInfo('libbox.so: go1.24.7\n'), /Incomplete/)
})

test('computes stable SHA-256 values', () => {
  assert.equal(
    sha256(Buffer.from('AikoBox')),
    '45d973960d32ff8deaf945ad184fde5266a2c5686c9548340823d45fecd647c8'
  )
})
