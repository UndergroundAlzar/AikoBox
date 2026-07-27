import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import {
  copyFileSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

export const LIBBOX_VERSION = '1.13.14'
export const LIBBOX_COMMIT = '25a600db24f7680ad9806ce5427bd0ab8afe1114'
export const GOMOBILE_VERSION = 'v0.1.12'
export const EXPECTED_GO_VERSION = 'go1.24.7'
export const EXPECTED_AAR_SHA256 =
  'cde14b0b16689901c46d786ee02ade397c65d1ee7df59931c9a2703ef3725a77'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, '..')
const evidenceRoot = join(repoRoot, 'licenses', `sing-box-${LIBBOX_VERSION}`, 'android-arm64')
const assetRoot = join(
  repoRoot,
  'apps',
  'android',
  'android',
  'app',
  'src',
  'main',
  'assets',
  'third_party',
  'sing-box'
)

export function sha256(data) {
  return createHash('sha256').update(data).digest('hex')
}

export function parseGoBuildInfo(text) {
  const lines = text.replaceAll('\r\n', '\n').split('\n')
  const goVersion = lines[0]?.trim().split(/\s+/).at(-1) ?? ''
  const modules = []
  const settings = []
  let mainModule = ''

  for (const rawLine of lines.slice(1)) {
    const line = rawLine.replace(/^\s+/, '')
    const fields = line.split('\t')
    if (fields[0] === 'mod') mainModule = fields.slice(1, 3).join('\t')
    if (fields[0] === 'dep') modules.push(fields.slice(1, 4))
    if (fields[0] === 'build') settings.push(fields.slice(1).join('\t'))
  }

  if (!goVersion || !mainModule || modules.length === 0) {
    throw new Error('Incomplete go version -m output for libbox.so')
  }
  return { goVersion, mainModule, modules, settings }
}

function exec(command, args, options = {}) {
  return execFileSync(command, args, {
    cwd: options.cwd,
    encoding: options.encoding ?? 'utf8',
    maxBuffer: 128 * 1024 * 1024,
    windowsHide: true
  })
}

function requireExactSource(sourceDir) {
  const commit = exec('git', ['rev-parse', 'HEAD'], { cwd: sourceDir }).trim()
  const tag = exec('git', ['describe', '--tags', '--exact-match', 'HEAD'], {
    cwd: sourceDir
  }).trim()
  const trackedChanges = exec('git', ['status', '--porcelain=v1', '--untracked-files=no'], {
    cwd: sourceDir
  }).trim()

  if (commit !== LIBBOX_COMMIT) throw new Error(`Expected sing-box ${LIBBOX_COMMIT}, got ${commit}`)
  if (tag !== `v${LIBBOX_VERSION}`) throw new Error(`Expected tag v${LIBBOX_VERSION}, got ${tag}`)
  if (trackedChanges) throw new Error('The sing-box source checkout has tracked modifications')
}

function extractLibbox(aarPath, temporaryRoot) {
  const entries = exec('tar', ['-tf', aarPath]).replaceAll('\r\n', '\n').split('\n').filter(Boolean)
  const nativeEntries = entries.filter((entry) => /^jni\/[^/]+\/[^/]+\.so$/.test(entry))
  if (nativeEntries.length !== 1 || nativeEntries[0] !== 'jni/arm64-v8a/libbox.so') {
    throw new Error(`Expected only jni/arm64-v8a/libbox.so, got: ${nativeEntries.join(', ')}`)
  }

  const libboxPath = join(temporaryRoot, 'libbox.so')
  const bytes = exec('tar', ['-xOf', aarPath, nativeEntries[0]], { encoding: 'buffer' })
  writeFileSync(libboxPath, bytes)
  return { entries, libboxPath, bytes }
}

function writeText(path, text) {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, text.replaceAll('\r\n', '\n'), 'utf8')
}

function buildNotice({ aar, libbox, buildInfo, sourceArchive }) {
  return `AikoBox Android libbox third-party notice

Component: sing-box/libbox ${LIBBOX_VERSION}
Upstream: https://github.com/SagerNet/sing-box
Source tag: v${LIBBOX_VERSION}
Source commit: ${LIBBOX_COMMIT}
Fixed source: https://github.com/SagerNet/sing-box/tree/${LIBBOX_COMMIT}
Copyright: Copyright (C) 2022 by nekohasekai <contact-sagernet@sekai.icu>
License: GNU GPL version 3 or later, plus the upstream LICENSE's name/association restriction.

Android payload:
- ABI: arm64-v8a only
- AAR SHA-256: ${aar.sha256}
- libbox.so SHA-256: ${libbox.sha256}
- libbox.so size: ${libbox.size} bytes
- Go toolchain recorded by the binary: ${buildInfo.goVersion}
- Main module recorded by the binary: ${buildInfo.mainModule}
- Static Go module entries recorded by the binary: ${buildInfo.modules.length}

Build recipe used for this payload:
- Go ${EXPECTED_GO_VERSION.replace(/^go/, '')}
- Android NDK 28.0.13004108
- github.com/sagernet/gomobile/cmd/gomobile@${GOMOBILE_VERSION}
- github.com/sagernet/gomobile/cmd/gobind@${GOMOBILE_VERSION}
- From the exact source checkout:
  go run ./cmd/internal/build_libbox -target android -platform android/arm64

Included legal/source material:
- LICENSE.upstream.txt: exact upstream LICENSE at the fixed commit.
- GPL-3.0.txt: complete GNU GPL version 3 text distributed by AikoBox.
- sing-box-v${LIBBOX_VERSION}-source-snapshot.tar.gz: deterministic git archive of the fixed
  sing-box tree; SHA-256 ${sourceArchive.sha256}; ${sourceArchive.size} bytes.

Important unresolved redistribution evidence:
The source snapshot contains the fixed sing-box repository tree, but it is NOT represented
as complete corresponding source for the shipped libbox.so. The binary statically links Go
modules listed in android-arm64-static-modules.tsv, and the repository does not yet contain
the complete source, license, copyright, and NOTICE material for that entire linked graph.
The source snapshot and this notice therefore improve traceability but do not clear the
Android binary for release under AikoBox's current release policy.
`
}

function generate({ sourceDir, aarPath, goExe, outputRoot }) {
  requireExactSource(sourceDir)
  if (!existsSync(aarPath)) throw new Error(`Missing AAR: ${aarPath}`)

  const temporaryRoot = mkdtempSync(join(tmpdir(), 'aikobox-libbox-license-'))
  try {
    const aarBytes = readFileSync(aarPath)
    const aar = { sha256: sha256(aarBytes), size: aarBytes.length }
    if (aar.sha256 !== EXPECTED_AAR_SHA256) {
      throw new Error(`Unexpected libbox.aar SHA-256: ${aar.sha256}`)
    }

    const extracted = extractLibbox(aarPath, temporaryRoot)
    const libbox = { sha256: sha256(extracted.bytes), size: extracted.bytes.length }
    const rawBuildInfo = exec(goExe, ['version', '-m', extracted.libboxPath])
    const buildInfo = parseGoBuildInfo(rawBuildInfo)
    const canonicalBuildInfo = rawBuildInfo.replace(
      rawBuildInfo.split(/\r?\n/, 1)[0],
      `libbox.so: ${buildInfo.goVersion}`
    )
    if (buildInfo.goVersion !== EXPECTED_GO_VERSION) {
      throw new Error(`Expected ${EXPECTED_GO_VERSION}, got ${buildInfo.goVersion}`)
    }
    if (!buildInfo.mainModule.startsWith('github.com/sagernet/sing-box\t')) {
      throw new Error(`Unexpected main module: ${buildInfo.mainModule}`)
    }
    for (const required of ['GOOS=android', 'GOARCH=arm64', '-buildmode=c-shared']) {
      if (!buildInfo.settings.some((setting) => setting.includes(required))) {
        throw new Error(`libbox.so build info is missing ${required}`)
      }
    }

    const generatedEvidenceRoot = join(
      outputRoot,
      'licenses',
      `sing-box-${LIBBOX_VERSION}`,
      'android-arm64'
    )
    const generatedAssetRoot = join(
      outputRoot,
      'apps',
      'android',
      'android',
      'app',
      'src',
      'main',
      'assets',
      'third_party',
      'sing-box'
    )
    mkdirSync(generatedEvidenceRoot, { recursive: true })
    mkdirSync(generatedAssetRoot, { recursive: true })

    const archiveName = `sing-box-v${LIBBOX_VERSION}-source-snapshot.tar.gz`
    const archivePath = join(generatedEvidenceRoot, archiveName)
    exec(
      'git',
      [
        '-c',
        'core.autocrlf=false',
        'archive',
        '--format=tar.gz',
        `--prefix=sing-box-${LIBBOX_VERSION}/`,
        `--output=${archivePath}`,
        LIBBOX_COMMIT
      ],
      { cwd: sourceDir }
    )
    const archiveBytes = readFileSync(archivePath)
    const sourceArchive = { sha256: sha256(archiveBytes), size: archiveBytes.length }

    const upstreamLicense = exec('git', ['show', `${LIBBOX_COMMIT}:LICENSE`], {
      cwd: sourceDir,
      encoding: 'buffer'
    })
    writeFileSync(join(generatedEvidenceRoot, 'LICENSE.upstream.txt'), upstreamLicense)
    writeFileSync(join(generatedAssetRoot, 'LICENSE.upstream.txt'), upstreamLicense)
    copyFileSync(join(repoRoot, 'LICENSE'), join(generatedAssetRoot, 'GPL-3.0.txt'))

    const moduleTsv = [
      'module\tversion\tsum',
      ...buildInfo.modules.map((fields) => fields.join('\t'))
    ].join('\n')
    writeText(join(generatedEvidenceRoot, 'android-arm64-static-modules.tsv'), `${moduleTsv}\n`)
    writeText(join(generatedEvidenceRoot, 'go-version-m.txt'), canonicalBuildInfo)

    const notice = buildNotice({ aar, libbox, buildInfo, sourceArchive })
    writeText(join(generatedEvidenceRoot, 'NOTICE.txt'), notice)
    writeText(join(generatedAssetRoot, 'NOTICE.txt'), notice)

    return {
      aar,
      libbox,
      sourceArchive,
      moduleCount: buildInfo.modules.length,
      outputRoot
    }
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true })
  }
}

function walk(root) {
  if (!existsSync(root)) return []
  const result = []
  for (const name of readdirSync(root)) {
    const path = join(root, name)
    if (statSync(path).isDirectory()) result.push(...walk(path))
    else result.push(path)
  }
  return result.sort()
}

function verifyGenerated(generatedRoot) {
  const pairs = [
    [join(generatedRoot, 'licenses', `sing-box-${LIBBOX_VERSION}`, 'android-arm64'), evidenceRoot],
    [
      join(
        generatedRoot,
        'apps',
        'android',
        'android',
        'app',
        'src',
        'main',
        'assets',
        'third_party',
        'sing-box'
      ),
      assetRoot
    ]
  ]
  for (const [actualRoot, expectedRoot] of pairs) {
    for (const actual of walk(actualRoot)) {
      const expected = join(expectedRoot, relative(actualRoot, actual))
      if (!existsSync(expected)) throw new Error(`Missing committed evidence: ${expected}`)
      const actualHash = sha256(readFileSync(actual))
      const expectedHash = sha256(readFileSync(expected))
      if (actualHash !== expectedHash) {
        throw new Error(`Stale committed evidence: ${relative(repoRoot, expected)}`)
      }
    }
  }
}

function parseArguments(argv) {
  const values = new Map()
  let mode = 'generate'
  for (let index = 0; index < argv.length; index += 1) {
    const argument = argv[index]
    if (argument === '--verify') mode = 'verify'
    else if (argument.startsWith('--')) values.set(argument, argv[++index])
  }
  const required = ['--source-dir', '--aar', '--go']
  for (const key of required) {
    if (!values.get(key)) throw new Error(`Missing required argument ${key}`)
  }
  return {
    mode,
    sourceDir: resolve(values.get('--source-dir')),
    aarPath: resolve(values.get('--aar')),
    goExe: resolve(values.get('--go'))
  }
}

function main() {
  const options = parseArguments(process.argv.slice(2))
  if (options.mode === 'generate') {
    const result = generate({ ...options, outputRoot: repoRoot })
    console.log(JSON.stringify(result, null, 2))
    return
  }

  const verificationRoot = mkdtempSync(join(tmpdir(), 'aikobox-libbox-verify-'))
  try {
    const result = generate({ ...options, outputRoot: verificationRoot })
    verifyGenerated(verificationRoot)
    console.log(
      `Android libbox license evidence verified: ${result.moduleCount} modules, ` +
        `AAR ${result.aar.sha256}, libbox.so ${result.libbox.sha256}, ` +
        `source ${result.sourceArchive.sha256}`
    )
  } finally {
    rmSync(verificationRoot, { recursive: true, force: true })
  }
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  main()
}
