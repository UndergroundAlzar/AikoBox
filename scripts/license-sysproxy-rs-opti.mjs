import { execFileSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import {
  copyFileSync,
  cpSync,
  existsSync,
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join, relative, resolve } from 'node:path'
import { createRequire } from 'node:module'
import { fileURLToPath, pathToFileURL } from 'node:url'

export const UPSTREAM_COMMIT = 'ce9463d95ed5839a43c6a0d7cccf3b3fb892de3a'
export const UPSTREAM_TAG = 'v0.1.0'
export const CRATE_VERSION = '0.5.1'
export const RUST_VERSION = '1.97.1'
export const TARGET = 'x86_64-pc-windows-msvc'
export const SOURCE_DATE_EPOCH = '1780791864'
export const RUSTFLAGS =
  '-C link-arg=/Brepro -C debuginfo=0 -C codegen-units=1 ' +
  '--remap-path-prefix=<SOURCE>=/usr/src/sysproxy-rs-opti ' +
  '--remap-path-prefix=<VENDOR>=/usr/src/cargo-vendor'
export const BINARY_NAME = 'sysproxy.win32-x64-msvc.node'
export const EXPECTED_EXPORTS = [
  'getAutoProxy',
  'getSystemProxy',
  'setAutoProxy',
  'setSystemProxy',
  'triggerAutoProxy',
  'triggerManualProxy'
]

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const evidenceRoot = join(repoRoot, 'licenses', 'sysproxy-rs-opti')
const evidenceLockPath = join(evidenceRoot, 'evidence-lock.json')
const inventoryPath = join(evidenceRoot, 'rust-production-dependencies.tsv')
const vendorInventoryPath = join(evidenceRoot, 'rust-lock-vendor.tsv')
const cargoLockPath = join(evidenceRoot, 'Cargo.lock')
const binaryEvidencePath = join(evidenceRoot, 'bin', BINARY_NAME)
const packagedBinaryPath = join(repoRoot, 'extra', 'sidecar', BINARY_NAME)
const sourceArchivePath = join(
  evidenceRoot,
  `sysproxy-rs-opti-${UPSTREAM_TAG}-windows-x64-corresponding-source.tar.gz`
)
const licenseArchivePath = join(
  evidenceRoot,
  `sysproxy-rs-opti-${UPSTREAM_TAG}-windows-x64-license-notices.tar.gz`
)
const buildInfoPath = join(evidenceRoot, 'BUILD-INFO.txt')
const noticePath = join(evidenceRoot, 'NOTICE.txt')
const resourcesLockPath = join(repoRoot, 'scripts', 'resources-lock.json')
const legalNamePattern =
  /^(authors|copying|copyright|licen[cs]e|notice|patents|unlicense)(?:$|[._-])/i
const sha256Pattern = /^[a-f0-9]{64}$/
const reviewedLegalOverrides = {
  'lazy-regex-proc_macros@3.6.0': {
    file: 'lazy-regex-3.6.0.LICENSE',
    vcsCommit: '692c46e624ad1e37d9587a99ca4ca12dae1bad26',
    sourceUrl:
      'https://raw.githubusercontent.com/Canop/lazy-regex/692c46e624ad1e37d9587a99ca4ca12dae1bad26/LICENSE',
    sha256: '89461664ce2aee7d80ea8fba7118fe7abd490d76ba435cf1d81d3128e060711f'
  },
  'napi-build@2.1.0': {
    file: 'napi-build-2.1.0.LICENSE',
    vcsCommit: '688ee04247fa17fab9a644c4cf0509b0e63853db',
    sourceUrl:
      'https://raw.githubusercontent.com/napi-rs/napi-rs/688ee04247fa17fab9a644c4cf0509b0e63853db/LICENSE',
    sha256: '3f1ce66533302df3a32edbfdfc0b78f0dd34659e4c1f5817162e5ea3c2297215'
  },
  'napi-derive-backend@1.0.75': {
    file: 'napi-backend-macro-1.0.75-2.16.13.LICENSE',
    vcsCommit: 'a312b7eb4e12d3e0a3e9770429ee05c333947a39',
    sourceUrl:
      'https://raw.githubusercontent.com/napi-rs/napi-rs/a312b7eb4e12d3e0a3e9770429ee05c333947a39/LICENSE',
    sha256: '3f1ce66533302df3a32edbfdfc0b78f0dd34659e4c1f5817162e5ea3c2297215'
  },
  'napi-derive@2.16.13': {
    file: 'napi-backend-macro-1.0.75-2.16.13.LICENSE',
    vcsCommit: 'a312b7eb4e12d3e0a3e9770429ee05c333947a39',
    sourceUrl:
      'https://raw.githubusercontent.com/napi-rs/napi-rs/a312b7eb4e12d3e0a3e9770429ee05c333947a39/LICENSE',
    sha256: '3f1ce66533302df3a32edbfdfc0b78f0dd34659e4c1f5817162e5ea3c2297215'
  },
  'napi-sys@2.4.0': {
    file: 'napi-sys-2.4.0.LICENSE',
    vcsCommit: 'f1b8ab5e645e674df33c796ef75aa278cd1b4a31',
    sourceUrl:
      'https://raw.githubusercontent.com/napi-rs/napi-rs/f1b8ab5e645e674df33c796ef75aa278cd1b4a31/LICENSE',
    sha256: '3f1ce66533302df3a32edbfdfc0b78f0dd34659e4c1f5817162e5ea3c2297215'
  },
  'napi@2.16.17': {
    file: 'napi-2.16.17.LICENSE',
    vcsCommit: 'f2178312d0e3e07beecc19836b91716a229107d3',
    sourceUrl:
      'https://raw.githubusercontent.com/napi-rs/napi-rs/f2178312d0e3e07beecc19836b91716a229107d3/LICENSE',
    sha256: '3f1ce66533302df3a32edbfdfc0b78f0dd34659e4c1f5817162e5ea3c2297215'
  }
}

function invariant(condition, message) {
  if (!condition) throw new Error(message)
}

export function sha256(contents) {
  return createHash('sha256').update(contents).digest('hex')
}

function fileRecord(path) {
  const contents = readFileSync(path)
  return { size: contents.length, sha256: sha256(contents) }
}

function run(command, args, options = {}) {
  return execFileSync(command, args, {
    cwd: options.cwd,
    encoding: Object.hasOwn(options, 'encoding') ? options.encoding : 'utf8',
    env: options.env ?? process.env,
    maxBuffer: 512 * 1024 * 1024,
    windowsHide: true,
    stdio: options.stdio
  })
}

function writeText(path, contents) {
  mkdirSync(dirname(path), { recursive: true })
  writeFileSync(path, contents.replaceAll('\r\n', '\n'), 'utf8')
}

function walkFiles(root) {
  const files = []
  const visit = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true }).sort((a, b) =>
      a.name.localeCompare(b.name, 'en')
    )) {
      const path = join(directory, entry.name)
      invariant(!entry.isSymbolicLink(), `Symlink is not permitted in evidence input: ${path}`)
      if (entry.isDirectory()) visit(path)
      else if (entry.isFile()) files.push(path)
      else throw new Error(`Unsupported filesystem entry in evidence input: ${path}`)
    }
  }
  visit(root)
  return files
}

export function isLegalFile(path) {
  const name = basename(path)
  if (/\.(c|cc|cpp|h|hpp|js|m|mm|py|rs|ts)$/i.test(name)) return false
  return legalNamePattern.test(name)
}

export function productionPackageIds(metadata) {
  invariant(metadata?.resolve?.root, 'Cargo metadata has no root package')
  const nodes = new Map(metadata.resolve.nodes.map((node) => [node.id, node]))
  const visited = new Set([metadata.resolve.root])
  const queue = [metadata.resolve.root]
  while (queue.length > 0) {
    const id = queue.shift()
    const node = nodes.get(id)
    invariant(node, `Cargo metadata is missing resolve node ${id}`)
    for (const dependency of node.deps) {
      const usedOutsideDevelopment = dependency.dep_kinds.some((kind) => kind.kind !== 'dev')
      if (!usedOutsideDevelopment || visited.has(dependency.pkg)) continue
      visited.add(dependency.pkg)
      queue.push(dependency.pkg)
    }
  }
  visited.delete(metadata.resolve.root)
  return [...visited].sort()
}

function parseArguments(argv) {
  const [command, ...rest] = argv
  const options = {}
  for (let index = 0; index < rest.length; index += 2) {
    const name = rest[index]
    const value = rest[index + 1]
    invariant(name?.startsWith('--') && value, `Invalid argument near ${name ?? '<end>'}`)
    options[name.slice(2)] = resolve(value)
  }
  return { command: command ?? 'verify', options }
}

function assertSource(sourceRoot) {
  invariant(existsSync(join(sourceRoot, '.git')), `Source is not a Git checkout: ${sourceRoot}`)
  const head = run('git', ['rev-parse', 'HEAD'], { cwd: sourceRoot }).trim()
  invariant(head === UPSTREAM_COMMIT, `Expected source commit ${UPSTREAM_COMMIT}, got ${head}`)
  const tagCommit = run('git', ['rev-list', '-n', '1', UPSTREAM_TAG], { cwd: sourceRoot }).trim()
  invariant(
    tagCommit === UPSTREAM_COMMIT,
    `Expected ${UPSTREAM_TAG} to resolve to ${UPSTREAM_COMMIT}, got ${tagCommit}`
  )
  const dirty = run('git', ['status', '--porcelain', '--untracked-files=no'], {
    cwd: sourceRoot
  }).trim()
  invariant(dirty === '', `Tracked upstream source files are modified:\n${dirty}`)
}

function loadMetadata(sourceRoot, cargoPath, cargoHome, filterPlatform = true) {
  const env = {
    ...process.env,
    CARGO_HOME: cargoHome,
    RUSTUP_HOME: resolve(cargoHome, '..', 'rustup'),
    RUSTUP_TOOLCHAIN: `${RUST_VERSION}-${TARGET}`
  }
  const args = ['metadata', '--locked', '--offline', '--format-version', '1']
  if (filterPlatform) args.push('--filter-platform', TARGET)
  return JSON.parse(run(cargoPath, args, { cwd: sourceRoot, env }))
}

function dependencyRecords(metadata, vendorRoot, legalOverrideRoot) {
  const packages = new Map(metadata.packages.map((item) => [item.id, item]))
  const records = productionPackageIds(metadata).map((id) => {
    const item = packages.get(id)
    invariant(item, `Cargo metadata has no package ${id}`)
    invariant(
      item.source?.startsWith('registry+https://github.com/rust-lang/crates.io-index'),
      `${item.name}@${item.version}: non-registry dependency requires separate source review`
    )
    invariant(
      typeof item.license === 'string' && item.license.trim().length > 0,
      `${item.name}@${item.version}: SPDX license expression is missing`
    )
    invariant(
      !/unknown|noassertion/i.test(item.license),
      `${item.name}@${item.version}: SPDX license expression is unresolved`
    )
    const directoryName = `${item.name}-${item.version}`
    const directory = join(vendorRoot, directoryName)
    invariant(existsSync(directory), `${item.name}@${item.version}: vendored source is missing`)
    const checksumPath = join(directory, '.cargo-checksum.json')
    invariant(existsSync(checksumPath), `${item.name}@${item.version}: Cargo checksum is missing`)
    const cargoChecksum = JSON.parse(readFileSync(checksumPath, 'utf8')).package
    invariant(
      typeof cargoChecksum === 'string' && sha256Pattern.test(cargoChecksum),
      `${item.name}@${item.version}: registry package checksum is invalid`
    )
    let legalFiles = walkFiles(directory)
      .filter(isLegalFile)
      .map((path) => relative(directory, path).replaceAll('\\', '/'))
      .sort()
    let legalInputs = legalFiles.map((path) => ({
      sourcePath: join(directory, ...path.split('/')),
      archivePath: path,
      sourceUrl: null,
      sourceSha256: sha256(readFileSync(join(directory, ...path.split('/')))),
      vcsCommit: null
    }))
    const identity = `${item.name}@${item.version}`
    if (legalFiles.length === 0) {
      const override = reviewedLegalOverrides[identity]
      invariant(override, `${identity}: no reviewed legal-file override exists`)
      invariant(legalOverrideRoot, `${identity}: --legalOverrides is required`)
      const vcsInfoPath = join(directory, '.cargo_vcs_info.json')
      invariant(existsSync(vcsInfoPath), `${identity}: Cargo VCS identity is missing`)
      const vcsCommit = JSON.parse(readFileSync(vcsInfoPath, 'utf8'))?.git?.sha1
      invariant(vcsCommit === override.vcsCommit, `${identity}: Cargo VCS commit differs`)
      const overridePath = join(legalOverrideRoot, override.file)
      invariant(existsSync(overridePath), `${identity}: reviewed upstream license is missing`)
      invariant(
        sha256(readFileSync(overridePath)) === override.sha256,
        `${identity}: reviewed upstream license SHA-256 differs`
      )
      legalFiles = ['LICENSE.reviewed-upstream']
      legalInputs = [
        {
          sourcePath: overridePath,
          archivePath: legalFiles[0],
          sourceUrl: override.sourceUrl,
          sourceSha256: override.sha256,
          vcsCommit: override.vcsCommit
        }
      ]
    }
    return {
      id,
      name: item.name,
      version: item.version,
      license: item.license,
      repository: item.repository,
      source: item.source,
      cargoChecksum,
      directoryName,
      directory,
      legalFiles,
      legalInputs
    }
  })
  return records
}

export function parseCargoLockPackages(contents) {
  return contents
    .replaceAll('\r\n', '\n')
    .split('[[package]]')
    .slice(1)
    .map((block) => {
      const value = (field) => {
        const match = new RegExp(`^${field} = ("(?:[^"\\\\]|\\\\.)*")$`, 'm').exec(block)
        return match ? JSON.parse(match[1]) : null
      }
      return {
        name: value('name'),
        version: value('version'),
        source: value('source'),
        checksum: value('checksum')
      }
    })
}

function lockedVendorRecords(cargoLockContents, vendorRoot) {
  const records = parseCargoLockPackages(cargoLockContents)
    .filter((item) => item.source !== null)
    .map((item) => {
      invariant(
        item.source?.startsWith('registry+https://github.com/rust-lang/crates.io-index'),
        `${item.name}@${item.version}: non-registry locked dependency requires separate review`
      )
      const directoryName = `${item.name}-${item.version}`
      const directory = join(vendorRoot, directoryName)
      invariant(
        existsSync(directory),
        `${item.name}@${item.version}: locked vendor source is missing`
      )
      const checksumPath = join(directory, '.cargo-checksum.json')
      invariant(existsSync(checksumPath), `${item.name}@${item.version}: Cargo checksum is missing`)
      const cargoChecksum = JSON.parse(readFileSync(checksumPath, 'utf8')).package
      invariant(
        typeof cargoChecksum === 'string' && sha256Pattern.test(cargoChecksum),
        `${item.name}@${item.version}: registry package checksum is invalid`
      )
      invariant(
        cargoChecksum === item.checksum,
        `${item.name}@${item.version}: vendor checksum differs from Cargo.lock`
      )
      return { name: item.name, version: item.version, directoryName, directory, cargoChecksum }
    })
    .sort((a, b) => a.directoryName.localeCompare(b.directoryName, 'en'))
  const identities = new Set(records.map((item) => item.directoryName))
  invariant(identities.size === records.length, 'Locked vendor inventory contains duplicates')
  const actualDirectories = readdirSync(vendorRoot, { withFileTypes: true })
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name)
    .sort()
  invariant(
    JSON.stringify([...identities].sort()) === JSON.stringify(actualDirectories),
    `Vendor staging directory differs from Cargo metadata; missing=${actualDirectories
      .filter((item) => !identities.has(item))
      .join(',')}; unexpected=${[...identities]
      .filter((item) => !actualDirectories.includes(item))
      .join(',')}`
  )
  return records
}

function createArchive(parent, rootName, destination) {
  mkdirSync(dirname(destination), { recursive: true })
  const uncompressed = `${destination}.uncompressed.tar`
  rmSync(uncompressed, { force: true })
  try {
    run(
      'tar',
      [
        '--format',
        'ustar',
        '--mtime',
        `@${SOURCE_DATE_EPOCH}`,
        '-cf',
        uncompressed,
        '-C',
        parent,
        rootName
      ],
      { stdio: 'inherit' }
    )
    const compressed = run('gzip', ['-n', '-9', '-c', uncompressed], { encoding: null })
    writeFileSync(destination, compressed)
  } finally {
    rmSync(uncompressed, { force: true })
  }
}

function archiveEntries(path) {
  return run('tar', ['-tzf', path])
    .replaceAll('\r\n', '\n')
    .split('\n')
    .filter(Boolean)
    .map((entry) => entry.replaceAll('\\', '/'))
}

export function assertSafeArchiveEntries(entries, label) {
  invariant(entries.length > 0, `${label}: archive is empty`)
  for (const entry of entries) {
    invariant(!entry.includes('\0'), `${label}: archive entry contains NUL`)
    invariant(!entry.startsWith('/') && !/^[A-Za-z]:/.test(entry), `${label}: absolute entry`)
    invariant(!/(^|\/)\.\.(\/|$)/.test(entry), `${label}: traversal entry`)
  }
}

function copyUpstreamSource(sourceRoot, destination, temporaryRoot) {
  const archive = join(temporaryRoot, 'upstream-source.tar')
  run('git', ['archive', '--format=tar', '--output', archive, UPSTREAM_COMMIT], {
    cwd: sourceRoot
  })
  mkdirSync(destination, { recursive: true })
  run('tar', ['-xf', archive, '-C', destination])
}

function inventoryText(records) {
  const header =
    'crate\tversion\tspdx_license\tregistry_source\tcrate_sha256\tvendor_directory\tlegal_files\tlegal_provenance'
  const rows = records.map((record) =>
    [
      record.name,
      record.version,
      record.license,
      record.source,
      record.cargoChecksum,
      record.directoryName,
      record.legalFiles.join(';'),
      record.legalInputs
        .map((item) => item.sourceUrl ?? `crate:${record.directoryName}/${item.archivePath}`)
        .join(';')
    ].join('\t')
  )
  return `${[header, ...rows].join('\n')}\n`
}

function vendorInventoryText(records) {
  return `${[
    'crate\tversion\tcrate_sha256\tvendor_directory',
    ...records.map((record) =>
      [record.name, record.version, record.cargoChecksum, record.directoryName].join('\t')
    )
  ].join('\n')}\n`
}

function buildInfoText(records, vendorRecords, binary) {
  return `AikoBox sysproxy-rs-opti Windows x64 reproducible build

Upstream: https://github.com/mihomo-party-org/sysproxy-rs-opti
Tag: ${UPSTREAM_TAG}
Commit: ${UPSTREAM_COMMIT}
Crate version: ${CRATE_VERSION}
Target: ${TARGET}
Rust: rustc ${RUST_VERSION}
Cargo: cargo ${RUST_VERSION}
SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH}
RUSTFLAGS: ${RUSTFLAGS}
Command: cargo +${RUST_VERSION} build --release --locked --offline --target ${TARGET}
Linker reproducibility flag: /Brepro
Path reproducibility: replace <SOURCE> and <VENDOR> in RUSTFLAGS with the absolute
paths to the extracted upstream and vendor directories before invoking Cargo.
Default features: iptools,napi-binding
Production Rust dependencies: ${records.length}
Complete Cargo.lock vendor packages: ${vendorRecords.length}
Binary: ${BINARY_NAME}
Binary size: ${binary.size}
Binary SHA-256: ${binary.sha256}

The binary was built twice in independent CARGO_TARGET_DIR directories and the two
outputs were byte-identical. The corresponding-source archive contains the exact
upstream source, generated Cargo.lock, every locked crate source, registry checksums
and an offline Cargo source replacement config. The license archive contains every
legal file found in each statically linked production crate. The verifier fails closed
on missing dependencies, legal files, checksums, archive entries or binary identity.
`
}

function noticeText(records, binary) {
  const licenses = [...new Set(records.map((record) => record.license))].sort().join(', ')
  return `sysproxy-rs-opti third-party notice

Project: https://github.com/mihomo-party-org/sysproxy-rs-opti
Release: ${UPSTREAM_TAG}
Commit: ${UPSTREAM_COMMIT}
Upstream license: MIT
Upstream copyright: Copyright (c) 2022 zzzgydi
Packaged binary: ${BINARY_NAME}
Binary SHA-256: ${binary.sha256}
Target: ${TARGET}
Rust toolchain: ${RUST_VERSION}
Production dependency count: ${records.length}
Dependency SPDX expressions: ${licenses}

See MIT.txt for the upstream license, rust-production-dependencies.tsv for the exact
crate graph and checksums, the license-notices archive for all dependency legal text,
and the corresponding-source archive for complete source sufficient for an offline
rebuild with the recorded proprietary Microsoft build tools and Windows SDK.
`
}

function generate({ source, vendor, binary, cargo, cargoHome, legalOverrides }) {
  for (const [name, value] of Object.entries({
    source,
    vendor,
    binary,
    cargo,
    cargoHome,
    legalOverrides
  })) {
    invariant(value, `generate requires --${name}`)
  }
  assertSource(source)
  invariant(existsSync(join(source, 'Cargo.lock')), 'Generated upstream Cargo.lock is missing')
  const metadata = loadMetadata(source, cargo, cargoHome)
  const rootPackage = metadata.packages.find((item) => item.id === metadata.resolve.root)
  invariant(rootPackage?.name === 'sysproxy', 'Cargo root package is not sysproxy')
  invariant(rootPackage.version === CRATE_VERSION, `Expected crate version ${CRATE_VERSION}`)
  const records = dependencyRecords(metadata, vendor, legalOverrides)
  const vendorRecords = lockedVendorRecords(
    readFileSync(join(source, 'Cargo.lock'), 'utf8'),
    vendor
  )
  invariant(records.length >= 25, `Unexpectedly small production graph: ${records.length}`)
  invariant(vendorRecords.length >= records.length, 'Complete vendor graph is unexpectedly small')

  const binaryRecord = fileRecord(binary)
  assertPeX64Dll(readFileSync(binary))
  mkdirSync(evidenceRoot, { recursive: true })
  copyFileSync(join(source, 'Cargo.lock'), cargoLockPath)
  mkdirSync(dirname(binaryEvidencePath), { recursive: true })
  copyFileSync(binary, binaryEvidencePath)
  mkdirSync(dirname(packagedBinaryPath), { recursive: true })
  copyFileSync(binaryEvidencePath, packagedBinaryPath)
  writeText(inventoryPath, inventoryText(records))
  writeText(vendorInventoryPath, vendorInventoryText(vendorRecords))
  writeText(buildInfoPath, buildInfoText(records, vendorRecords, binaryRecord))
  writeText(noticePath, noticeText(records, binaryRecord))
  const committedOverrides = []
  for (const record of records) {
    for (const input of record.legalInputs.filter((item) => item.sourceUrl)) {
      const destination = join(
        evidenceRoot,
        'reviewed-license-overrides',
        record.directoryName,
        input.archivePath
      )
      mkdirSync(dirname(destination), { recursive: true })
      copyFileSync(input.sourcePath, destination)
      input.sourcePath = destination
      committedOverrides.push({
        crate: `${record.name}@${record.version}`,
        path: relative(repoRoot, destination).replaceAll('\\', '/'),
        sourceUrl: input.sourceUrl,
        vcsCommit: input.vcsCommit,
        size: statSync(destination).size,
        sha256: input.sourceSha256
      })
    }
  }

  const temporaryRoot = mkdtempSync(join(tmpdir(), 'aikobox-sysproxy-evidence-'))
  try {
    const sourceName = `sysproxy-rs-opti-${UPSTREAM_TAG}-windows-x64-corresponding-source`
    const sourceStage = join(temporaryRoot, sourceName)
    const upstreamStage = join(sourceStage, 'upstream')
    copyUpstreamSource(source, upstreamStage, temporaryRoot)
    copyFileSync(cargoLockPath, join(upstreamStage, 'Cargo.lock'))
    mkdirSync(join(sourceStage, '.cargo'), { recursive: true })
    writeText(
      join(sourceStage, '.cargo', 'config.toml'),
      '[source.crates-io]\nreplace-with = "vendored-sources"\n\n' +
        '[source.vendored-sources]\ndirectory = "vendor"\n'
    )
    copyFileSync(buildInfoPath, join(sourceStage, 'BUILD-INFO.txt'))
    copyFileSync(inventoryPath, join(sourceStage, 'rust-production-dependencies.tsv'))
    copyFileSync(vendorInventoryPath, join(sourceStage, 'rust-lock-vendor.tsv'))
    for (const override of committedOverrides) {
      const destination = join(
        sourceStage,
        'reviewed-license-overrides',
        override.crate.replace('@', '-'),
        'LICENSE.reviewed-upstream'
      )
      mkdirSync(dirname(destination), { recursive: true })
      copyFileSync(resolve(repoRoot, ...override.path.split('/')), destination)
    }
    const vendorStage = join(sourceStage, 'vendor')
    mkdirSync(vendorStage, { recursive: true })
    for (const record of vendorRecords) {
      cpSync(record.directory, join(vendorStage, record.directoryName), { recursive: true })
    }
    createArchive(temporaryRoot, sourceName, sourceArchivePath)

    const licenseName = `sysproxy-rs-opti-${UPSTREAM_TAG}-windows-x64-license-notices`
    const licenseStage = join(temporaryRoot, licenseName)
    mkdirSync(join(licenseStage, 'upstream'), { recursive: true })
    copyFileSync(join(source, 'LICENSE'), join(licenseStage, 'upstream', 'LICENSE'))
    copyFileSync(noticePath, join(licenseStage, 'NOTICE.txt'))
    copyFileSync(inventoryPath, join(licenseStage, 'rust-production-dependencies.tsv'))
    for (const record of records) {
      for (const input of record.legalInputs) {
        const destination = join(licenseStage, 'crates', record.directoryName, input.archivePath)
        mkdirSync(dirname(destination), { recursive: true })
        copyFileSync(input.sourcePath, destination)
      }
    }
    createArchive(temporaryRoot, licenseName, licenseArchivePath)
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true })
  }

  const lock = {
    schemaVersion: 1,
    upstream: {
      project: 'https://github.com/mihomo-party-org/sysproxy-rs-opti',
      tag: UPSTREAM_TAG,
      commit: UPSTREAM_COMMIT,
      crateVersion: CRATE_VERSION
    },
    build: {
      rustVersion: RUST_VERSION,
      target: TARGET,
      sourceDateEpoch: SOURCE_DATE_EPOCH,
      rustflags: RUSTFLAGS,
      command: `cargo +${RUST_VERSION} build --release --locked --offline --target ${TARGET}`
    },
    dependencyCount: records.length,
    vendorPackageCount: vendorRecords.length,
    reviewedLegalOverrides: committedOverrides,
    files: {
      binary: {
        path: relative(repoRoot, binaryEvidencePath).replaceAll('\\', '/'),
        ...binaryRecord
      },
      cargoLock: {
        path: relative(repoRoot, cargoLockPath).replaceAll('\\', '/'),
        ...fileRecord(cargoLockPath)
      },
      inventory: {
        path: relative(repoRoot, inventoryPath).replaceAll('\\', '/'),
        ...fileRecord(inventoryPath)
      },
      vendorInventory: {
        path: relative(repoRoot, vendorInventoryPath).replaceAll('\\', '/'),
        ...fileRecord(vendorInventoryPath)
      },
      buildInfo: {
        path: relative(repoRoot, buildInfoPath).replaceAll('\\', '/'),
        ...fileRecord(buildInfoPath)
      },
      notice: {
        path: relative(repoRoot, noticePath).replaceAll('\\', '/'),
        ...fileRecord(noticePath)
      },
      correspondingSource: {
        path: relative(repoRoot, sourceArchivePath).replaceAll('\\', '/'),
        ...fileRecord(sourceArchivePath)
      },
      licenseNotices: {
        path: relative(repoRoot, licenseArchivePath).replaceAll('\\', '/'),
        ...fileRecord(licenseArchivePath)
      }
    }
  }
  writeText(evidenceLockPath, `${JSON.stringify(lock, null, 2)}\n`)
  verify()
  return lock
}

export function assertPeX64Dll(contents) {
  invariant(contents.length >= 256, 'Native module is too small to be a PE image')
  invariant(contents[0] === 0x4d && contents[1] === 0x5a, 'Native module has no MZ header')
  const peOffset = contents.readUInt32LE(0x3c)
  invariant(peOffset + 24 <= contents.length, 'Native module has an invalid PE offset')
  invariant(contents.toString('ascii', peOffset, peOffset + 4) === 'PE\0\0', 'PE signature missing')
  invariant(contents.readUInt16LE(peOffset + 4) === 0x8664, 'PE machine is not AMD64')
  invariant((contents.readUInt16LE(peOffset + 22) & 0x2000) !== 0, 'PE image is not a DLL')
}

function parseInventory(contents) {
  const lines = contents.replaceAll('\r\n', '\n').trim().split('\n')
  invariant(
    lines.shift() ===
      'crate\tversion\tspdx_license\tregistry_source\tcrate_sha256\tvendor_directory\tlegal_files\tlegal_provenance',
    'Dependency inventory header is invalid'
  )
  return lines.map((line) => {
    const [name, version, license, source, cargoChecksum, directoryName, legal, provenance] =
      line.split('\t')
    const legalFiles = legal?.split(';').filter(Boolean) ?? []
    invariant(
      name && version && license && source && directoryName && provenance,
      `Invalid inventory row: ${line}`
    )
    invariant(sha256Pattern.test(cargoChecksum), `${name}@${version}: invalid crate checksum`)
    invariant(legalFiles.length > 0, `${name}@${version}: legal file list is empty`)
    return {
      name,
      version,
      license,
      source,
      cargoChecksum,
      directoryName,
      legalFiles,
      provenance
    }
  })
}

function parseVendorInventory(contents) {
  const lines = contents.replaceAll('\r\n', '\n').trim().split('\n')
  invariant(
    lines.shift() === 'crate\tversion\tcrate_sha256\tvendor_directory',
    'Vendor inventory header is invalid'
  )
  return lines.map((line) => {
    const [name, version, cargoChecksum, directoryName] = line.split('\t')
    invariant(name && version && directoryName, `Invalid vendor inventory row: ${line}`)
    invariant(sha256Pattern.test(cargoChecksum), `${name}@${version}: invalid vendor checksum`)
    return { name, version, cargoChecksum, directoryName }
  })
}

function requireAddon(path) {
  const require = createRequire(import.meta.url)
  const loaded = require(path)
  const exports = Object.keys(loaded).sort()
  invariant(
    JSON.stringify(exports) === JSON.stringify([...EXPECTED_EXPORTS].sort()),
    `Unexpected native exports: ${exports.join(', ')}`
  )
}

function verifyRecord(record, label) {
  invariant(record && typeof record.path === 'string', `${label}: file record is missing`)
  invariant(Number.isSafeInteger(record.size) && record.size > 0, `${label}: size is invalid`)
  invariant(sha256Pattern.test(record.sha256), `${label}: SHA-256 is invalid`)
  const path = resolve(repoRoot, ...record.path.split('/'))
  invariant(path.startsWith(`${repoRoot}\\`), `${label}: path escapes repository`)
  invariant(existsSync(path), `${label}: file is missing`)
  invariant(lstatSync(path).isFile() && !lstatSync(path).isSymbolicLink(), `${label}: not a file`)
  const actual = fileRecord(path)
  invariant(
    actual.size === record.size && actual.sha256 === record.sha256,
    `${label}: size or SHA-256 differs from evidence lock`
  )
  return path
}

function verify() {
  invariant(existsSync(evidenceLockPath), 'sysproxy evidence-lock.json is missing')
  const lock = JSON.parse(readFileSync(evidenceLockPath, 'utf8'))
  invariant(lock.schemaVersion === 1, 'Unsupported sysproxy evidence schema')
  invariant(lock.upstream?.tag === UPSTREAM_TAG, 'Evidence tag differs from fixed tag')
  invariant(lock.upstream?.commit === UPSTREAM_COMMIT, 'Evidence commit differs from fixed commit')
  invariant(lock.upstream?.crateVersion === CRATE_VERSION, 'Evidence crate version differs')
  invariant(lock.build?.rustVersion === RUST_VERSION, 'Evidence Rust version differs')
  invariant(lock.build?.target === TARGET, 'Evidence target differs')
  invariant(lock.build?.rustflags === RUSTFLAGS, 'Evidence RUSTFLAGS differ')
  invariant(lock.build?.sourceDateEpoch === SOURCE_DATE_EPOCH, 'Evidence epoch differs')
  invariant(
    Number.isSafeInteger(lock.dependencyCount) && lock.dependencyCount >= 25,
    'Evidence dependency count is invalid'
  )

  const paths = {}
  for (const [name, record] of Object.entries(lock.files ?? {})) {
    paths[name] = verifyRecord(record, name)
  }
  for (const required of [
    'binary',
    'cargoLock',
    'inventory',
    'vendorInventory',
    'buildInfo',
    'notice',
    'correspondingSource',
    'licenseNotices'
  ]) {
    invariant(paths[required], `Evidence file record is missing: ${required}`)
  }

  const binary = readFileSync(paths.binary)
  assertPeX64Dll(binary)
  requireAddon(paths.binary)
  const packaged = fileRecord(packagedBinaryPath)
  invariant(
    packaged.size === lock.files.binary.size && packaged.sha256 === lock.files.binary.sha256,
    'Packaged sysproxy native module differs from the self-built evidence binary'
  )

  const records = parseInventory(readFileSync(paths.inventory, 'utf8'))
  invariant(records.length === lock.dependencyCount, 'Dependency inventory count differs from lock')
  const identities = new Set(records.map((item) => `${item.name}@${item.version}`))
  invariant(identities.size === records.length, 'Dependency inventory contains duplicates')
  const vendorRecords = parseVendorInventory(readFileSync(paths.vendorInventory, 'utf8'))
  invariant(
    vendorRecords.length === lock.vendorPackageCount && vendorRecords.length >= records.length,
    'Complete vendor inventory count differs from lock'
  )
  const vendorIdentities = new Set(vendorRecords.map((item) => item.directoryName))
  invariant(vendorIdentities.size === vendorRecords.length, 'Vendor inventory contains duplicates')
  const overrideByCrate = new Map()
  for (const item of lock.reviewedLegalOverrides ?? []) {
    invariant(reviewedLegalOverrides[item.crate], `${item.crate}: unreviewed legal override`)
    const expected = reviewedLegalOverrides[item.crate]
    invariant(item.sourceUrl === expected.sourceUrl, `${item.crate}: override URL differs`)
    invariant(item.vcsCommit === expected.vcsCommit, `${item.crate}: override commit differs`)
    invariant(item.sha256 === expected.sha256, `${item.crate}: override SHA-256 differs`)
    verifyRecord(item, `${item.crate} legal override`)
    invariant(!overrideByCrate.has(item.crate), `${item.crate}: duplicate legal override`)
    overrideByCrate.set(item.crate, item)
  }
  invariant(
    overrideByCrate.size === Object.keys(reviewedLegalOverrides).length,
    'Reviewed legal override set is incomplete'
  )

  const sourceEntries = archiveEntries(paths.correspondingSource)
  const licenseEntries = archiveEntries(paths.licenseNotices)
  assertSafeArchiveEntries(sourceEntries, 'corresponding source')
  assertSafeArchiveEntries(licenseEntries, 'license notices')
  const sourceNames = new Set(sourceEntries.map((entry) => entry.replace(/\/$/, '')))
  const licenseNames = new Set(licenseEntries.map((entry) => entry.replace(/\/$/, '')))
  const sourcePrefix = `sysproxy-rs-opti-${UPSTREAM_TAG}-windows-x64-corresponding-source`
  const licensePrefix = `sysproxy-rs-opti-${UPSTREAM_TAG}-windows-x64-license-notices`
  for (const required of [
    `${sourcePrefix}/upstream/Cargo.toml`,
    `${sourcePrefix}/upstream/Cargo.lock`,
    `${sourcePrefix}/upstream/LICENSE`,
    `${sourcePrefix}/.cargo/config.toml`,
    `${sourcePrefix}/BUILD-INFO.txt`,
    `${sourcePrefix}/rust-production-dependencies.tsv`,
    `${sourcePrefix}/rust-lock-vendor.tsv`
  ]) {
    invariant(sourceNames.has(required), `Corresponding source archive is missing ${required}`)
  }
  for (const record of vendorRecords) {
    invariant(
      sourceNames.has(`${sourcePrefix}/vendor/${record.directoryName}/Cargo.toml`),
      `${record.name}@${record.version}: source archive lacks vendored Cargo.toml`
    )
    invariant(
      sourceNames.has(`${sourcePrefix}/vendor/${record.directoryName}/.cargo-checksum.json`),
      `${record.name}@${record.version}: source archive lacks Cargo checksum`
    )
  }
  for (const record of records) {
    for (const legalPath of record.legalFiles) {
      invariant(
        licenseNames.has(`${licensePrefix}/crates/${record.directoryName}/${legalPath}`),
        `${record.name}@${record.version}: license archive lacks ${legalPath}`
      )
    }
  }

  const resources = JSON.parse(readFileSync(resourcesLockPath, 'utf8')).resources
  const resource = resources?.sysproxy
  invariant(resource?.type === 'local-file', 'sysproxy resource must use pinned local-file mode')
  invariant(
    resource.source === 'licenses/sysproxy-rs-opti/bin/sysproxy.win32-x64-msvc.node',
    'sysproxy local source path differs from evidence'
  )
  invariant(resource.output === 'extra/sidecar/sysproxy.win32-x64-msvc.node', 'output differs')
  invariant(resource.releaseTag === UPSTREAM_TAG, 'resource tag differs')
  invariant(resource.releaseTagCommit === UPSTREAM_COMMIT, 'resource commit differs')
  invariant(resource.size === lock.files.binary.size, 'resource size differs')
  invariant(resource.sha256 === lock.files.binary.sha256, 'resource SHA-256 differs')
  console.log(
    `sysproxy evidence verified: ${records.length} production crates, ${resource.size} bytes, ${resource.sha256}`
  )
  return { lock, records }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const { command, options } = parseArguments(process.argv.slice(2))
  if (command === 'generate') {
    generate(options)
  } else if (command === 'verify') {
    verify()
  } else if (command === 'help') {
    console.log(
      'Usage:\n' +
        '  node scripts/license-sysproxy-rs-opti.mjs verify\n' +
        '  node scripts/license-sysproxy-rs-opti.mjs generate --source PATH --vendor PATH ' +
        '--binary PATH --cargo PATH --cargoHome PATH --legalOverrides PATH'
    )
  } else {
    throw new Error(`Unsupported command: ${command}`)
  }
}
