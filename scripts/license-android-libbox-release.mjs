import { createHash } from 'node:crypto'
import { execFileSync } from 'node:child_process'
import {
  copyFileSync,
  cpSync,
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
import { basename, dirname, extname, join, relative, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import {
  EXPECTED_GO_VERSION,
  GOMOBILE_VERSION,
  LIBBOX_COMMIT,
  LIBBOX_VERSION,
  parseGoBuildInfo,
  sha256
} from './license-android-libbox.mjs'

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const exactModuleInventory = join(
  repoRoot,
  'licenses',
  `sing-box-${LIBBOX_VERSION}`,
  'android-arm64',
  'android-arm64-static-modules.tsv'
)
const cronetSourceLockPath = join(
  repoRoot,
  'licenses',
  `sing-box-${LIBBOX_VERSION}`,
  'android-arm64',
  'cronet-source-lock.json'
)
const nativeExtensions = new Set([
  '.a',
  '.aar',
  '.dll',
  '.dylib',
  '.exe',
  '.jar',
  '.lib',
  '.o',
  '.obj',
  '.so',
  '.syso',
  '.wasm'
])
const buildTags = [
  'with_gvisor',
  'with_quic',
  'with_wireguard',
  'with_utls',
  'with_naive_outbound',
  'with_clash_api',
  'badlinkname',
  'tfogo_checklinkname0',
  'with_tailscale',
  'ts_omit_logtail',
  'ts_omit_ssh',
  'ts_omit_drive',
  'ts_omit_taildrop',
  'ts_omit_webclient',
  'ts_omit_doctor',
  'ts_omit_capture',
  'ts_omit_kube',
  'ts_omit_aws',
  'ts_omit_synology',
  'ts_omit_bird'
]

export function run(command, args, options = {}) {
  return execFileSync(command, args, {
    cwd: options.cwd,
    encoding: options.encoding ?? 'utf8',
    env: options.env ?? process.env,
    maxBuffer: 512 * 1024 * 1024,
    windowsHide: true
  })
}

export function writeText(path, text) {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, text.replaceAll('\r\n', '\n'), 'utf8')
}

export function parseModuleInventory(text) {
  const rows = text
    .replaceAll('\r\n', '\n')
    .trim()
    .split('\n')
    .slice(1)
    .map((line) => {
      const [module, version, sum] = line.split('\t')
      if (!module || !version || !/^h1:/.test(sum ?? '')) {
        throw new Error(`Invalid static module inventory row: ${line}`)
      }
      return { module, version, sum }
    })
  const identities = new Set(rows.map((row) => `${row.module}@${row.version}`))
  if (rows.length !== 75 || identities.size !== rows.length) {
    throw new Error(`Expected 75 unique static modules, got ${rows.length}`)
  }
  return rows
}

export function parseVendorModules(text) {
  const modules = new Map()
  for (const line of text.replaceAll('\r\n', '\n').split('\n')) {
    const match = /^# (\S+) (\S+)(?: => .*)?$/.exec(line)
    if (match) modules.set(`${match[1]}@${match[2]}`, { module: match[1], version: match[2] })
  }
  return modules
}

export function parseJsonStream(text) {
  const values = []
  let depth = 0
  let start = -1
  let inString = false
  let escaped = false
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index]
    if (inString) {
      if (escaped) escaped = false
      else if (character === '\\') escaped = true
      else if (character === '"') inString = false
      continue
    }
    if (character === '"') {
      inString = true
      continue
    }
    if (character === '{') {
      if (depth === 0) start = index
      depth += 1
    } else if (character === '}') {
      depth -= 1
      if (depth === 0 && start >= 0) {
        values.push(JSON.parse(text.slice(start, index + 1)))
        start = -1
      }
    }
  }
  if (depth !== 0 || inString) throw new Error('Incomplete JSON object stream')
  return values
}

export function isLegalFile(path) {
  const name = basename(path)
  if (/\.(c|cc|cpp|go|h|hpp|java|js|kt|m|mm|py|rs|ts)$/i.test(name)) return false
  return (
    /^(authors|copying|copyright|licen[cs]e|notice|patents)(?:$|[._-])/i.test(name) ||
    /^readme\.chromium$/i.test(name)
  )
}

export function nativeInputsFromPackage(pkg) {
  const paths = new Set()
  for (const file of pkg.SysoFiles ?? []) paths.add(resolve(pkg.Dir, file))
  const sourceDirectory = pkg.Dir
  const libraryDirectories = []
  for (const flag of pkg.CgoLDFLAGS ?? []) {
    const expanded = flag
      .replaceAll('${SRCDIR}', sourceDirectory)
      .replaceAll('$SRCDIR', sourceDirectory)
    const unquoted = expanded.replace(/^['"]|['"]$/g, '')
    if (unquoted.startsWith('-L') && unquoted.length > 2) {
      libraryDirectories.push(resolve(unquoted.slice(2)))
      continue
    }
    if (unquoted.startsWith('-l:') && unquoted.length > 3) {
      for (const libraryDirectory of libraryDirectories) {
        const candidate = join(libraryDirectory, unquoted.slice(3))
        if (existsSync(candidate)) paths.add(resolve(candidate))
      }
      continue
    }
    if (nativeExtensions.has(extname(unquoted).toLowerCase()) && existsSync(unquoted)) {
      paths.add(resolve(unquoted))
    }
  }
  return [...paths].sort()
}

export function walkFiles(root) {
  const result = []
  if (!existsSync(root)) return result
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    const path = join(root, entry.name)
    if (entry.isDirectory()) result.push(...walkFiles(path))
    else if (entry.isFile()) result.push(path)
  }
  return result
}

function safeModuleName(module, version) {
  const stem = `${module}@${version}`.replaceAll(/[^A-Za-z0-9._-]/g, '_')
  return `${stem}-${createHash('sha256').update(`${module}@${version}`).digest('hex').slice(0, 12)}`
}

export function requireSourceIdentity(sourceDir) {
  const commit = run('git', ['rev-parse', 'HEAD'], { cwd: sourceDir }).trim()
  const tag = run('git', ['describe', '--tags', '--exact-match', 'HEAD'], {
    cwd: sourceDir
  }).trim()
  const tracked = run('git', ['status', '--porcelain=v1', '--untracked-files=no'], {
    cwd: sourceDir
  }).trim()
  if (commit !== LIBBOX_COMMIT) throw new Error(`Expected ${LIBBOX_COMMIT}, got ${commit}`)
  if (tag !== `v${LIBBOX_VERSION}`) throw new Error(`Expected v${LIBBOX_VERSION}, got ${tag}`)
  if (tracked) throw new Error('The sing-box checkout has tracked modifications')
}

export function extractSource(sourceDir, destination) {
  mkdirSync(destination, { recursive: true })
  const archive = run(
    'git',
    [
      '-c',
      'core.autocrlf=false',
      'archive',
      '--format=tar',
      `--prefix=sing-box-${LIBBOX_VERSION}/`,
      LIBBOX_COMMIT
    ],
    { cwd: sourceDir, encoding: 'buffer' }
  )
  const temporaryTar = join(dirname(destination), 'sing-box-source.tar')
  writeFileSync(temporaryTar, archive)
  run('tar', ['-xf', temporaryTar, '-C', destination])
  rmSync(temporaryTar, { force: true })
  return join(destination, `sing-box-${LIBBOX_VERSION}`)
}

function extractLibbox(aarPath, temporaryRoot, goExe) {
  const entries = run('tar', ['-tf', aarPath]).replaceAll('\r\n', '\n').split('\n').filter(Boolean)
  const native = entries.filter((entry) => /^jni\/[^/]+\/[^/]+\.so$/.test(entry))
  if (native.length !== 1 || native[0] !== 'jni/arm64-v8a/libbox.so') {
    throw new Error(`AAR ABI gate failed: ${native.join(', ')}`)
  }
  const libboxPath = join(temporaryRoot, 'libbox.so')
  writeFileSync(libboxPath, run('tar', ['-xOf', aarPath, native[0]], { encoding: 'buffer' }))
  const raw = run(goExe, ['version', '-m', libboxPath])
  const buildInfo = parseGoBuildInfo(raw)
  if (buildInfo.goVersion !== EXPECTED_GO_VERSION) {
    throw new Error(`Expected ${EXPECTED_GO_VERSION}, got ${buildInfo.goVersion}`)
  }
  return { libboxPath, buildInfo, raw }
}

export function downloadModule(goExe, sourceRoot, row, environment) {
  const output = run(goExe, ['mod', 'download', '-json', `${row.module}@${row.version}`], {
    cwd: sourceRoot,
    env: environment
  })
  const value = JSON.parse(output)
  if (value.Error) throw new Error(`${row.module}@${row.version}: ${value.Error}`)
  if (
    value.Path !== row.module ||
    value.Version !== row.version ||
    (row.sum !== undefined && value.Sum !== row.sum)
  ) {
    throw new Error(`${row.module}@${row.version}: downloaded identity or sum differs from libbox`)
  }
  if (!value.Dir || !existsSync(value.Dir)) {
    throw new Error(`${row.module}@${row.version}: extracted module source is missing`)
  }
  return value
}

export function findUnreferencedNativeFiles(vendorRoot, nativeInputs) {
  const retained = new Set(nativeInputs.map((item) => resolve(item.path).toLowerCase()))
  return walkFiles(vendorRoot).filter(
    (path) =>
      nativeExtensions.has(extname(path).toLowerCase()) &&
      !retained.has(resolve(path).toLowerCase())
  )
}

export function collectLicenses(downloads, licenseRoot) {
  const manifest = []
  const blockers = []
  for (const item of downloads) {
    const legalFiles = walkFiles(item.Dir).filter(isLegalFile)
    if (legalFiles.length === 0) {
      blockers.push(`${item.Path}@${item.Version}: no LICENSE/NOTICE/COPYING file in module source`)
      continue
    }
    const moduleRoot = join(licenseRoot, 'modules', safeModuleName(item.Path, item.Version))
    const files = []
    for (const source of legalFiles) {
      const relativePath = relative(item.Dir, source)
      const destination = join(moduleRoot, relativePath)
      mkdirSync(dirname(destination), { recursive: true })
      copyFileSync(source, destination)
      const contents = readFileSync(destination)
      files.push({
        path: relative(licenseRoot, destination).replaceAll('\\', '/'),
        size: contents.length,
        sha256: sha256(contents)
      })
    }
    manifest.push({
      module: item.Path,
      version: item.Version,
      sum: item.Sum,
      origin: item.Origin ?? null,
      files
    })
  }
  return { manifest, blockers }
}

function copyMainLegalFiles(sourceRoot, licenseRoot) {
  const files = [
    {
      source: join(sourceRoot, 'LICENSE'),
      destination: join(licenseRoot, 'main', 'sing-box-LICENSE.upstream.txt')
    },
    {
      source: join(repoRoot, 'LICENSE'),
      destination: join(licenseRoot, 'main', 'GPL-3.0.txt')
    },
    {
      source: join(repoRoot, 'THIRD_PARTY_NOTICES.md'),
      destination: join(licenseRoot, 'main', 'THIRD_PARTY_NOTICES.md')
    },
    {
      source: join(
        repoRoot,
        'licenses',
        `sing-box-${LIBBOX_VERSION}`,
        'android-arm64',
        'NOTICE.txt'
      ),
      destination: join(licenseRoot, 'main', 'ANDROID-LIBBOX-NOTICE.txt')
    }
  ]
  return files.map((item) => {
    mkdirSync(dirname(item.destination), { recursive: true })
    copyFileSync(item.source, item.destination)
    const contents = readFileSync(item.destination)
    return {
      path: relative(licenseRoot, item.destination).replaceAll('\\', '/'),
      size: contents.length,
      sha256: sha256(contents)
    }
  })
}

function downloadLockedArchive(item, destination) {
  run('curl', [
    '-L',
    '--fail',
    '--retry',
    '5',
    '--retry-all-errors',
    '--connect-timeout',
    '20',
    '-o',
    destination,
    item.url
  ])
  const contents = readFileSync(destination)
  if (contents.length !== item.size || sha256(contents) !== item.sha256) {
    throw new Error(`${item.id}: source archive size or SHA-256 differs from lock`)
  }
}

function extractLockedArchive(item, archivePath, destinationParent) {
  const entries = run('tar', ['-tzf', archivePath])
    .replaceAll('\r\n', '\n')
    .split('\n')
    .filter(Boolean)
  if (entries.length === 0 || entries.some((entry) => /(^\/|(^|\/)\.\.(\/|$))/.test(entry))) {
    throw new Error(`${item.id}: unsafe or empty source archive`)
  }
  run('tar', ['-xzf', archivePath, '-C', destinationParent])
  const roots = readdirSync(destinationParent, { withFileTypes: true }).filter((entry) =>
    entry.isDirectory()
  )
  if (roots.length !== 1) throw new Error(`${item.id}: expected one archive root`)
  const root = join(destinationParent, roots[0].name)
  for (const requiredPath of item.requiredPaths) {
    if (!existsSync(join(root, ...requiredPath.split('/')))) {
      throw new Error(`${item.id}: source archive is missing ${requiredPath}`)
    }
  }
  return root
}

function prepareNativeCorrespondingSource(nativeInputs, temporaryRoot, licenseRoot) {
  const lock = JSON.parse(readFileSync(cronetSourceLockPath, 'utf8'))
  const locked = lock.nativeInput
  const matchingInput = nativeInputs.find(
    (input) =>
      input.module === `${locked.module}@${locked.version}` &&
      basename(input.path) === locked.file &&
      input.size === locked.size &&
      input.sha256 === locked.sha256
  )
  if (!matchingInput || nativeInputs.length !== 1) {
    return {
      blockers: ['linked native inputs do not exactly match cronet-source-lock.json'],
      verifiedMappings: new Set(),
      sourceRoot: null,
      manifest: null
    }
  }

  const downloadsRoot = join(temporaryRoot, 'native-source-downloads')
  mkdirSync(downloadsRoot, { recursive: true })
  const extractedRoots = new Map()
  for (const item of lock.sourceArchives) {
    const archivePath = join(downloadsRoot, `${item.id}.tar.gz`)
    downloadLockedArchive(item, archivePath)
    const extractionParent = join(downloadsRoot, `${item.id}-extracted`)
    mkdirSync(extractionParent, { recursive: true })
    extractedRoots.set(item.id, extractLockedArchive(item, archivePath, extractionParent))
  }

  const cronetRoot = extractedRoots.get('cronet-go-build-source')
  const naiveproxyRoot = extractedRoots.get('naiveproxy-chromium-source')
  const gitmodules = readFileSync(join(cronetRoot, '.gitmodules'), 'utf8')
  if (!gitmodules.includes('https://github.com/SagerNet/naiveproxy.git')) {
    throw new Error('cronet-go source has an unexpected naiveproxy submodule URL')
  }
  const chromiumVersion = readFileSync(join(naiveproxyRoot, 'CHROMIUM_VERSION'), 'utf8').trim()
  if (chromiumVersion !== lock.provenance.chromiumVersion) {
    throw new Error(`Expected Chromium ${lock.provenance.chromiumVersion}, got ${chromiumVersion}`)
  }

  const nestedNaiveproxy = join(cronetRoot, 'naiveproxy')
  if (existsSync(nestedNaiveproxy)) rmSync(nestedNaiveproxy, { recursive: true, force: true })
  cpSync(naiveproxyRoot, nestedNaiveproxy, { recursive: true })

  const legalFiles = walkFiles(cronetRoot).filter(isLegalFile)
  if (legalFiles.length === 0) throw new Error('Cronet/NaiveProxy source has no legal files')
  const nativeLicenseRoot = join(licenseRoot, 'native', 'cronet-go-naiveproxy')
  const legalManifest = []
  for (const source of legalFiles) {
    const relativePath = relative(cronetRoot, source)
    const destination = join(nativeLicenseRoot, relativePath)
    mkdirSync(dirname(destination), { recursive: true })
    copyFileSync(source, destination)
    const contents = readFileSync(destination)
    legalManifest.push({
      path: relative(licenseRoot, destination).replaceAll('\\', '/'),
      size: contents.length,
      sha256: sha256(contents)
    })
  }

  const mappingKey = `${matchingInput.module}|${basename(matchingInput.path)}|${matchingInput.sha256}`
  return {
    blockers: [],
    verifiedMappings: new Set([mappingKey]),
    sourceRoot: cronetRoot,
    manifest: {
      lock,
      nativeInput: {
        ...matchingInput,
        path: basename(matchingInput.path)
      },
      legalFiles: legalManifest
    }
  }
}

function createBuildGuide({ aarHash, libboxHash, moduleCount, cronetLock }) {
  return `# AikoBox Android libbox corresponding-source build guide

This bundle targets the exact AikoBox Android arm64 libbox payload.

- sing-box: v${LIBBOX_VERSION}
- commit: ${LIBBOX_COMMIT}
- Go: ${EXPECTED_GO_VERSION}
- Android NDK: 28.0.13004108
- gomobile/gobind: ${GOMOBILE_VERSION}
- AAR SHA-256 used by the audit: ${aarHash}
- libbox.so SHA-256 used by the audit: ${libboxHash}
- actual static Go modules: ${moduleCount}

The \`vendor\` directory was produced from the fixed source with Go ${EXPECTED_GO_VERSION.replace(
    /^go/,
    ''
  )} using:

    go mod verify
    go mod vendor

To rebuild on a machine with JDK 17, Android SDK and NDK 28.0.13004108:

    set GOWORK=off
    set GOFLAGS=-mod=vendor
    go build -mod=vendor -o <GOBIN>/gomobile github.com/sagernet/gomobile/cmd/gomobile
    go build -mod=vendor -o <GOBIN>/gobind github.com/sagernet/gomobile/cmd/gobind
    go run ./cmd/internal/build_libbox -target android -platform android/arm64

The exact build tags are implemented by \`cmd/internal/build_libbox\` at the fixed commit
and are also recorded in \`EVIDENCE/go-version-m.txt\`.

The prebuilt Cronet input is mapped to source under \`NATIVE-SOURCE/cronet-go\`:

- cronet-go generated module commit: ${cronetLock.nativeInput.moduleCommit}
- cronet-go build-script commit: ${cronetLock.provenance.cronetGoCommit}
- NaiveProxy/Chromium source commit: ${cronetLock.provenance.naiveproxySubmoduleCommit}
- Chromium version: ${cronetLock.provenance.chromiumVersion}

To rebuild \`libcronet.a\`, enter \`NATIVE-SOURCE/cronet-go\` on Ubuntu with the Android
NDK r28 prerequisites used by the pinned workflow and run:

    go run ./cmd/build-naive --target=android/arm64 build
    go run ./cmd/build-naive --target=android/arm64 package --local
    go run ./cmd/build-naive --target=android/arm64 package

Replace the vendored \`libcronet.a\` only after verifying it was produced from that exact
source and build configuration. Build output need not be byte-identical, but the source,
scripts, target and linked input identity are pinned in \`EVIDENCE/cronet-source-lock.json\`.

This archive is release-ready only when \`COVERAGE.json\` says \`releaseReady: true\`.
The generator refuses to create this archive if an actual static module is absent from
vendor, lacks legal files, has a checksum mismatch, or introduces a linked native object
without corresponding source.
`
}

export function createTarGz(sourceParent, sourceName, destination) {
  mkdirSync(dirname(destination), { recursive: true })
  run('tar', ['-czf', destination, '-C', sourceParent, sourceName])
}

function writeChecksums(distDir, artifacts) {
  const lines = artifacts.map((path) => `${sha256(readFileSync(path))}  ${basename(path)}`).sort()
  const destination = join(distDir, `aikobox-libbox-${LIBBOX_VERSION}-android-arm64-SHA256SUMS.txt`)
  writeText(destination, `${lines.join('\n')}\n`)
  return destination
}

function clearReleaseArtifacts(distDir) {
  const prefix = `aikobox-libbox-${LIBBOX_VERSION}-android-arm64`
  for (const name of [
    `${prefix}-corresponding-source.tar.gz`,
    `${prefix}-licenses.tar.gz`,
    `${prefix}-SHA256SUMS.txt`,
    `${prefix}-COVERAGE.json`,
    `${prefix}-BLOCKED.txt`
  ]) {
    rmSync(join(distDir, name), { force: true })
  }
}

export function auditCoverage({
  actualModules,
  vendorModules,
  packages,
  downloads,
  verifiedNativeMappings = new Set()
}) {
  const blockers = []
  const actualIdentities = new Set(actualModules.map((row) => `${row.module}@${row.version}`))
  for (const identity of actualIdentities) {
    if (!vendorModules.has(identity)) blockers.push(`${identity}: absent from vendor/modules.txt`)
  }

  const nativeInputs = []
  for (const pkg of packages) {
    for (const path of nativeInputsFromPackage(pkg)) {
      nativeInputs.push({
        package: pkg.ImportPath,
        module: pkg.Module ? `${pkg.Module.Path}@${pkg.Module.Version}` : null,
        path,
        size: statSync(path).size,
        sha256: sha256(readFileSync(path))
      })
    }
  }
  for (const input of nativeInputs) {
    const mappingKey = `${input.module}|${basename(input.path)}|${input.sha256}`
    if (!verifiedNativeMappings.has(mappingKey)) {
      blockers.push(
        `${input.module ?? input.package}: linked native input ${basename(input.path)} ` +
          `(${input.sha256}) has no machine-readable corresponding-source mapping`
      )
    }
  }

  const downloaded = new Set(downloads.map((item) => `${item.Path}@${item.Version}`))
  for (const identity of actualIdentities) {
    if (!downloaded.has(identity)) blockers.push(`${identity}: module source was not downloaded`)
  }
  return { blockers, nativeInputs }
}

function generate(options) {
  requireSourceIdentity(options.sourceDir)
  mkdirSync(options.distDir, { recursive: true })
  clearReleaseArtifacts(options.distDir)

  const temporaryRoot = mkdtempSync(join(tmpdir(), 'aikobox-libbox-release-source-'))
  const reportPath = join(
    options.distDir,
    `aikobox-libbox-${LIBBOX_VERSION}-android-arm64-COVERAGE.json`
  )
  try {
    const sourceStageParent = join(temporaryRoot, 'source-stage')
    const sourceRoot = extractSource(options.sourceDir, sourceStageParent)
    const libbox = extractLibbox(options.aarPath, temporaryRoot, options.goExe)
    const actualModules = parseModuleInventory(
      ['module\tversion\tsum', ...libbox.buildInfo.modules.map((row) => row.join('\t'))].join('\n')
    )
    const committedModules = parseModuleInventory(readFileSync(exactModuleInventory, 'utf8'))
    if (JSON.stringify(actualModules) !== JSON.stringify(committedModules)) {
      throw new Error('Actual libbox module inventory differs from committed evidence')
    }

    const environment = {
      ...process.env,
      CGO_ENABLED: '1',
      GOARCH: 'arm64',
      GOOS: 'android',
      GOWORK: 'off'
    }
    run(options.goExe, ['mod', 'verify'], { cwd: sourceRoot, env: environment })
    run(options.goExe, ['mod', 'vendor'], { cwd: sourceRoot, env: environment })
    const vendorModules = parseVendorModules(
      readFileSync(join(sourceRoot, 'vendor', 'modules.txt'), 'utf8')
    )

    const actualDownloads = actualModules.map((row) =>
      downloadModule(options.goExe, sourceRoot, row, environment)
    )
    const listOutput = run(
      options.goExe,
      [
        'list',
        '-mod=vendor',
        '-deps',
        '-json',
        `-tags=${buildTags.join(',')}`,
        './experimental/libbox'
      ],
      { cwd: sourceRoot, env: environment }
    )
    const packages = parseJsonStream(listOutput)

    const vendorDownloads = [...vendorModules.values()].map((row) =>
      downloadModule(options.goExe, sourceRoot, row, environment)
    )

    const licenseStageParent = join(temporaryRoot, 'license-stage')
    const licenseName = `aikobox-libbox-${LIBBOX_VERSION}-android-arm64-licenses`
    const licenseRoot = join(licenseStageParent, licenseName)
    mkdirSync(licenseRoot, { recursive: true })
    const mainLegalFiles = copyMainLegalFiles(sourceRoot, licenseRoot)
    const licenseResult = collectLicenses(vendorDownloads, licenseRoot)
    const preliminaryCoverage = auditCoverage({
      actualModules,
      vendorModules,
      packages,
      downloads: actualDownloads
    })
    const nativeSource = prepareNativeCorrespondingSource(
      preliminaryCoverage.nativeInputs,
      temporaryRoot,
      licenseRoot
    )
    const coverage = auditCoverage({
      actualModules,
      vendorModules,
      packages,
      downloads: actualDownloads,
      verifiedNativeMappings: nativeSource.verifiedMappings
    })
    const blockers = [...licenseResult.blockers, ...nativeSource.blockers, ...coverage.blockers]

    const aarBytes = readFileSync(options.aarPath)
    const libboxBytes = readFileSync(libbox.libboxPath)
    const unreferencedNativeFiles = findUnreferencedNativeFiles(
      join(sourceRoot, 'vendor'),
      coverage.nativeInputs
    )
    const report = {
      schema: 1,
      component: 'sing-box/libbox',
      version: LIBBOX_VERSION,
      commit: LIBBOX_COMMIT,
      target: 'android/arm64',
      generatedAt: new Date().toISOString(),
      releaseReady: blockers.length === 0,
      actualStaticModules: actualModules.length,
      coveredActualStaticModules: actualDownloads.length,
      vendorModules: vendorModules.size,
      licensedVendorModules: licenseResult.manifest.length,
      prunedUnreferencedNativeFiles: unreferencedNativeFiles.length,
      aar: { size: aarBytes.length, sha256: sha256(aarBytes) },
      libbox: { size: libboxBytes.length, sha256: sha256(libboxBytes) },
      nativeInputs: coverage.nativeInputs.map((item) => ({
        ...item,
        path: basename(item.path)
      })),
      nativeSource: nativeSource.manifest,
      blockers
    }
    writeText(reportPath, `${JSON.stringify(report, null, 2)}\n`)

    writeText(
      join(licenseRoot, 'MODULE-LICENSE-MANIFEST.json'),
      `${JSON.stringify(
        {
          main: mainLegalFiles,
          vendoredGoModules: licenseResult.manifest,
          nativeSource: nativeSource.manifest
        },
        null,
        2
      )}\n`
    )
    copyFileSync(reportPath, join(licenseRoot, 'COVERAGE.json'))

    if (blockers.length > 0) {
      writeText(
        join(options.distDir, `aikobox-libbox-${LIBBOX_VERSION}-android-arm64-BLOCKED.txt`),
        `Release archives were not created because the audit is fail-closed.\n\n${blockers
          .map((blocker) => `- ${blocker}`)
          .join('\n')}\n`
      )
      throw new Error(
        `Android libbox corresponding-source audit blocked release:\n${blockers
          .map((blocker) => `- ${blocker}`)
          .join('\n')}`
      )
    }

    for (const path of unreferencedNativeFiles) rmSync(path, { force: true })

    const sourceName = `aikobox-libbox-${LIBBOX_VERSION}-android-arm64-corresponding-source`
    const releaseSourceRoot = join(temporaryRoot, sourceName)
    mkdirSync(releaseSourceRoot, { recursive: true })
    cpSync(sourceRoot, join(releaseSourceRoot, `sing-box-${LIBBOX_VERSION}`), {
      recursive: true
    })
    mkdirSync(join(releaseSourceRoot, 'EVIDENCE'), { recursive: true })
    copyFileSync(exactModuleInventory, join(releaseSourceRoot, 'EVIDENCE', 'actual-modules.tsv'))
    copyFileSync(
      cronetSourceLockPath,
      join(releaseSourceRoot, 'EVIDENCE', 'cronet-source-lock.json')
    )
    copyFileSync(join(repoRoot, 'LICENSE'), join(releaseSourceRoot, 'EVIDENCE', 'GPL-3.0.txt'))
    copyFileSync(
      join(repoRoot, 'licenses', `sing-box-${LIBBOX_VERSION}`, 'android-arm64', 'NOTICE.txt'),
      join(releaseSourceRoot, 'EVIDENCE', 'ANDROID-LIBBOX-NOTICE.txt')
    )
    writeText(join(releaseSourceRoot, 'EVIDENCE', 'go-version-m.txt'), libbox.raw)
    copyFileSync(reportPath, join(releaseSourceRoot, 'COVERAGE.json'))
    cpSync(nativeSource.sourceRoot, join(releaseSourceRoot, 'NATIVE-SOURCE', 'cronet-go'), {
      recursive: true
    })
    writeText(
      join(releaseSourceRoot, 'BUILDING.md'),
      createBuildGuide({
        aarHash: report.aar.sha256,
        libboxHash: report.libbox.sha256,
        moduleCount: actualModules.length,
        cronetLock: nativeSource.manifest.lock
      })
    )

    const sourceArchive = join(options.distDir, `${sourceName}.tar.gz`)
    const licenseArchive = join(options.distDir, `${licenseName}.tar.gz`)
    createTarGz(temporaryRoot, sourceName, sourceArchive)
    createTarGz(licenseStageParent, licenseName, licenseArchive)
    const checksums = writeChecksums(options.distDir, [sourceArchive, licenseArchive, reportPath])
    return { sourceArchive, licenseArchive, reportPath, checksums, report }
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true })
  }
}

function parseArguments(argv) {
  const values = new Map()
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index]
    if (key.startsWith('--')) values.set(key, argv[++index])
  }
  for (const key of ['--source-dir', '--aar', '--go', '--dist-dir']) {
    if (!values.get(key)) throw new Error(`Missing required argument ${key}`)
  }
  return {
    sourceDir: resolve(values.get('--source-dir')),
    aarPath: resolve(values.get('--aar')),
    goExe: resolve(values.get('--go')),
    distDir: resolve(values.get('--dist-dir'))
  }
}

function main() {
  const result = generate(parseArguments(process.argv.slice(2)))
  console.log(JSON.stringify(result, null, 2))
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  main()
}
