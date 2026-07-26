#!/usr/bin/env node
// Verifies the sing-box gomobile binding before Gradle is allowed to link it.
//
// This is the Android counterpart of the resources-lock discipline that guards
// extra/sidecar/sing-box.exe on the desktop side. gomobile output is not bit-reproducible
// across hosts, so an unexpected digest is reported as a warning with the observed value
// rather than a hard failure; the structural invariants — exactly one ABI, arm64-v8a, and
// the expected .so and Java package present — are hard gates, because a violation of any
// of them means the artifact is not what the app is built to load.

import { createHash } from 'node:crypto'
import { readFileSync, existsSync, statSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const lock = JSON.parse(readFileSync(resolve(root, 'scripts/resources-lock.android.json'), 'utf8'))
const spec = lock.resources.libbox
const aar = resolve(root, spec.output)

const problems = []
const warnings = []

if (!existsSync(aar)) {
  console.error(`missing core binding: ${spec.output}`)
  console.error('Build it with .github/workflows/android-libbox.yml, or locally with:')
  console.error(`  ${spec.buildCommand}`)
  process.exit(1)
}

const bytes = readFileSync(aar)
const sha256 = createHash('sha256').update(bytes).digest('hex')
const size = statSync(aar).size

if (sha256 !== spec.sha256) {
  warnings.push(
    `sha256 ${sha256} does not match the locked ${spec.sha256} (size ${size} vs ${spec.size}). ` +
      'Expected when the AAR was rebuilt on a different host; investigate if the source tag is unchanged and the build host is the same.'
  )
}

// Structural invariants. `unzip -Z1` is not guaranteed to exist on Windows runners, so read
// the zip central directory directly rather than shelling out.
const entries = listZipEntries(bytes)

const jni = entries.filter((name) => name.startsWith('jni/') && name.endsWith('.so'))
const abis = [...new Set(jni.map((name) => name.split('/')[1]))].sort()
const expected = [...spec.abi].sort()

if (abis.join(',') !== expected.join(',')) {
  problems.push(`ABI set is [${abis.join(', ')}], expected [${expected.join(', ')}]`)
}
if (!entries.includes(spec.soName)) {
  problems.push(`missing ${spec.soName}`)
}
if (!entries.includes('classes.jar')) {
  problems.push('missing classes.jar')
}

// The io.nekohasekai.libbox package itself is not checked here: it is verified far more
// strictly a step later, when Kotlin fails to compile if any expected class is absent.

for (const w of warnings) console.warn(`warning: ${w}`)

if (problems.length > 0) {
  console.error(`${spec.output} failed verification:`)
  for (const p of problems) console.error(`  - ${p}`)
  process.exit(1)
}

console.log(
  `libbox ${spec.version} verified: ${size} bytes, sha256 ${sha256}, abi ${abis.join(',')}`
)

/** Minimal zip central-directory reader — enough to list entry names. */
function listZipEntries(buf) {
  const EOCD = 0x06054b50
  const CEN = 0x02014b50
  let eocd = -1
  for (let i = buf.length - 22; i >= 0 && i > buf.length - 22 - 0xffff; i--) {
    if (buf.readUInt32LE(i) === EOCD) {
      eocd = i
      break
    }
  }
  if (eocd < 0) throw new Error('not a zip archive')
  const count = buf.readUInt16LE(eocd + 10)
  let offset = buf.readUInt32LE(eocd + 16)
  const names = []
  for (let i = 0; i < count; i++) {
    if (buf.readUInt32LE(offset) !== CEN) throw new Error('corrupt central directory')
    const nameLength = buf.readUInt16LE(offset + 28)
    const extraLength = buf.readUInt16LE(offset + 30)
    const commentLength = buf.readUInt16LE(offset + 32)
    names.push(buf.toString('utf8', offset + 46, offset + 46 + nameLength))
    offset += 46 + nameLength + extraLength + commentLength
  }
  return names
}
