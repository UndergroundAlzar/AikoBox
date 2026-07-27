import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'
import AdmZip from 'adm-zip'
import {
  buildToolInvocation,
  inspectAndroidArchive,
  parseApkSignerCertificate,
  verifyAndroidChecksum,
  verifyAndroidVersionCode
} from './verify-android-release.mjs'

test('runs Windows batch Android tools through cmd without a shell string', () => {
  assert.deepEqual(
    buildToolInvocation(
      'C:\\Android SDK\\apkanalyzer.bat',
      ['manifest', 'version-code', 'app.apk'],
      {
        platform: 'win32',
        comspec: 'C:\\Windows\\System32\\cmd.exe'
      }
    ),
    {
      executable: 'C:\\Windows\\System32\\cmd.exe',
      args: [
        '/d',
        '/s',
        '/c',
        'C:\\Android SDK\\apkanalyzer.bat',
        'manifest',
        'version-code',
        'app.apk'
      ]
    }
  )
})

function fixture(entries) {
  const directory = mkdtempSync(join(tmpdir(), 'aikobox-apk-test-'))
  const apkPath = join(directory, 'aikobox-android-1.2.3-arm64-v8a.apk')
  const zip = new AdmZip()
  for (const [name, contents = 'fixture'] of entries) zip.addFile(name, Buffer.from(contents))
  zip.writeZip(apkPath)
  return { apkPath, directory }
}

test('accepts an APK whose native libraries are arm64-v8a only', () => {
  const item = fixture([
    ['AndroidManifest.xml'],
    ['lib/arm64-v8a/libapp.so'],
    ['lib/arm64-v8a/libflutter.so'],
    ['lib/arm64-v8a/libbox.so']
  ])
  try {
    assert.deepEqual(inspectAndroidArchive(item.apkPath).nativeAbis, ['arm64-v8a'])
  } finally {
    rmSync(item.directory, { recursive: true })
  }
})

test('rejects APKs with another ABI or without libbox', () => {
  const mixed = fixture([['lib/arm64-v8a/libbox.so'], ['lib/x86_64/libbox.so']])
  const missing = fixture([['lib/arm64-v8a/libapp.so']])
  try {
    assert.throws(() => inspectAndroidArchive(mixed.apkPath), /only for arm64-v8a/)
    assert.throws(() => inspectAndroidArchive(missing.apkPath), /missing .*libbox\.so/)
  } finally {
    rmSync(mixed.directory, { recursive: true })
    rmSync(missing.directory, { recursive: true })
  }
})

test('requires an exact SHA-256 sidecar', () => {
  const item = fixture([['lib/arm64-v8a/libbox.so']])
  const sidecar = `${item.apkPath}.sha256`
  try {
    assert.throws(() => {
      writeFileSync(sidecar, `${'0'.repeat(64)}  aikobox-android-1.2.3-arm64-v8a.apk\n`)
      verifyAndroidChecksum(item.apkPath, sidecar)
    }, /does not exactly match/)
    const digest = createHash('sha256').update(readFileSync(item.apkPath)).digest('hex')
    writeFileSync(sidecar, `${digest}  aikobox-android-1.2.3-arm64-v8a.apk\n`)
    assert.equal(verifyAndroidChecksum(item.apkPath, sidecar), digest)
  } finally {
    rmSync(item.directory, { recursive: true })
  }
})

test('extracts and normalizes exactly one signer certificate SHA-256', () => {
  const digest = 'AA:'.repeat(31) + 'AA'
  assert.equal(
    parseApkSignerCertificate(`Signer #1 certificate SHA-256 digest: ${digest}\n`),
    'aa'.repeat(32)
  )
  assert.throws(
    () =>
      parseApkSignerCertificate(
        `Signer #1 certificate SHA-256 digest: ${digest}\nSigner #2 certificate SHA-256 digest: ${digest}`
      ),
    /exactly one/
  )
})

test('requires the APK versionCode to exactly match the release contract', () => {
  assert.equal(verifyAndroidVersionCode('2\n', '2'), '2')
  assert.throws(() => verifyAndroidVersionCode('3', '2'), /versionCode is 3, expected 2/)
  assert.throws(() => verifyAndroidVersionCode('0', '2'), /must be a positive integer/)
  assert.throws(() => verifyAndroidVersionCode('2', 'not-an-integer'), /Expected APK versionCode/)
})
