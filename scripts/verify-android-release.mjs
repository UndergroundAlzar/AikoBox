import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { basename, isAbsolute, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import AdmZip from 'adm-zip'

function normalizedCertificate(value) {
  const normalized = value.replace(/[^0-9a-f]/gi, '').toLowerCase()
  if (!/^[0-9a-f]{64}$/.test(normalized)) {
    throw new Error('Expected Android certificate SHA-256 must contain exactly 64 hex digits')
  }
  return normalized
}

function normalizedToolOutput(value) {
  return value.trim().replace(/^["']|["']$/g, '')
}

export function inspectAndroidArchive(apkPath) {
  const archive = new AdmZip(apkPath)
  const names = new Set()
  const nativeAbis = new Set()
  let hasLibbox = false

  for (const entry of archive.getEntries()) {
    const name = entry.entryName
    if (
      name.includes('\\') ||
      name.includes('\0') ||
      name.startsWith('/') ||
      /^[A-Za-z]:/.test(name) ||
      name.split('/').includes('..')
    ) {
      throw new Error(`APK contains an unsafe ZIP path: ${JSON.stringify(name)}`)
    }
    if (names.has(name)) throw new Error(`APK contains a duplicate ZIP entry: ${name}`)
    names.add(name)

    const nativeMatch = /^lib\/([^/]+)\/([^/]+\.so)$/.exec(name)
    if (nativeMatch) {
      nativeAbis.add(nativeMatch[1])
      if (nativeMatch[1] === 'arm64-v8a' && nativeMatch[2] === 'libbox.so') hasLibbox = true
    }
  }

  if (!hasLibbox) throw new Error('APK is missing lib/arm64-v8a/libbox.so')
  if (nativeAbis.size !== 1 || !nativeAbis.has('arm64-v8a')) {
    throw new Error(
      `APK must contain native libraries only for arm64-v8a; found: ${
        [...nativeAbis].sort().join(', ') || '(none)'
      }`
    )
  }
  return { entryCount: names.size, nativeAbis: [...nativeAbis] }
}

export function verifyAndroidChecksum(apkPath, sidecarPath) {
  const digest = createHash('sha256').update(readFileSync(apkPath)).digest('hex')
  const expectedLine = `${digest}  ${basename(apkPath)}`
  const actualLine = readFileSync(sidecarPath, 'utf8').trim()
  if (actualLine !== expectedLine) {
    throw new Error(`Android checksum sidecar does not exactly match ${basename(apkPath)}`)
  }
  return digest
}

export function parseApkSignerCertificate(output) {
  const matches = [...output.matchAll(/Signer #\d+ certificate SHA-256 digest:\s*([0-9a-f: ]+)/gi)]
  if (matches.length !== 1) {
    throw new Error(`Expected exactly one APK signing certificate, found ${matches.length}`)
  }
  return normalizedCertificate(matches[0][1])
}

export function verifyAndroidVersionCode(actualValue, expectedValue) {
  const actual = normalizedToolOutput(String(actualValue))
  const expected = String(expectedValue).trim()
  if (!/^[1-9]\d*$/.test(expected)) {
    throw new Error(`Expected APK versionCode must be a positive integer, found ${expected}`)
  }
  if (!/^[1-9]\d*$/.test(actual)) {
    throw new Error(`APK versionCode must be a positive integer, found ${actual}`)
  }
  if (actual !== expected) {
    throw new Error(`APK versionCode is ${actual}, expected ${expected}`)
  }
  return actual
}

export function buildToolInvocation(
  executable,
  args,
  { platform = process.platform, comspec = process.env.ComSpec || 'cmd.exe' } = {}
) {
  if (platform === 'win32' && /\.(?:bat|cmd)$/i.test(executable)) {
    return { executable: comspec, args: ['/d', '/s', '/c', executable, ...args] }
  }
  return { executable, args }
}

function runTool(executable, args, label) {
  const invocation = buildToolInvocation(executable, args)
  try {
    return execFileSync(invocation.executable, invocation.args, {
      encoding: 'utf8',
      maxBuffer: 16 * 1024 * 1024,
      stdio: ['ignore', 'pipe', 'pipe']
    })
  } catch (error) {
    const stderr = error?.stderr?.toString().trim()
    throw new Error(`${label} failed${stderr ? `: ${stderr}` : ''}`, { cause: error })
  }
}

export function verifyAndroidMetadata({
  apkPath,
  apkAnalyzer,
  apkSigner,
  expectedApplicationId,
  expectedCertificateSha256,
  expectedVersion,
  expectedVersionCode
}) {
  const applicationId = normalizedToolOutput(
    runTool(apkAnalyzer, ['manifest', 'application-id', apkPath], 'apkanalyzer application-id')
  )
  const versionName = normalizedToolOutput(
    runTool(apkAnalyzer, ['manifest', 'version-name', apkPath], 'apkanalyzer version-name')
  )
  const versionCodeText = normalizedToolOutput(
    runTool(apkAnalyzer, ['manifest', 'version-code', apkPath], 'apkanalyzer version-code')
  )
  if (applicationId !== expectedApplicationId) {
    throw new Error(`APK applicationId is ${applicationId}, expected ${expectedApplicationId}`)
  }
  if (versionName !== expectedVersion) {
    throw new Error(`APK versionName is ${versionName}, expected ${expectedVersion}`)
  }
  const versionCode = verifyAndroidVersionCode(versionCodeText, expectedVersionCode)

  const signerOutput = runTool(
    apkSigner,
    ['verify', '--verbose', '--print-certs', apkPath],
    'apksigner verification'
  )
  const actualCertificate = parseApkSignerCertificate(signerOutput)
  const expectedCertificate = normalizedCertificate(expectedCertificateSha256)
  if (actualCertificate !== expectedCertificate) {
    throw new Error(
      'APK signing certificate SHA-256 does not match the configured release identity'
    )
  }
  return {
    applicationId,
    certificateSha256: actualCertificate,
    versionCodeText: versionCode,
    versionName
  }
}

function parseArguments(argv) {
  const options = new Map()
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index]
    const value = argv[index + 1]
    if (!key?.startsWith('--') || value === undefined) {
      throw new Error(`Invalid argument list near ${key ?? '(end)'}`)
    }
    options.set(key.slice(2), value)
  }
  return options
}

export function verifyAndroidRelease(options) {
  const apkPath = resolve(options.get('apk'))
  const sidecarPath = resolve(options.get('sha256'))
  const archive = inspectAndroidArchive(apkPath)
  const digest = verifyAndroidChecksum(apkPath, sidecarPath)
  const metadata = verifyAndroidMetadata({
    apkPath,
    apkAnalyzer: options.get('apkanalyzer'),
    apkSigner: options.get('apksigner'),
    expectedApplicationId: options.get('application-id'),
    expectedCertificateSha256: options.get('certificate-sha256'),
    expectedVersion: options.get('version'),
    expectedVersionCode: options.get('version-code')
  })
  return { archive, digest, metadata }
}

const isMain = process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)
if (isMain) {
  const options = parseArguments(process.argv.slice(2))
  const required = [
    'apk',
    'sha256',
    'apkanalyzer',
    'apksigner',
    'application-id',
    'certificate-sha256',
    'version',
    'version-code'
  ]
  for (const name of required) {
    const value = options.get(name)
    if (!value) throw new Error(`Missing required --${name} argument`)
    if (['apk', 'sha256', 'apkanalyzer', 'apksigner'].includes(name) && !isAbsolute(value)) {
      throw new Error(`--${name} must be an absolute path`)
    }
  }
  const result = verifyAndroidRelease(options)
  console.log(
    `Verified signed Android ${result.metadata.versionName} APK: arm64-v8a only, ` +
      `${result.archive.entryCount} ZIP entries, SHA-256 ${result.digest}.`
  )
}
