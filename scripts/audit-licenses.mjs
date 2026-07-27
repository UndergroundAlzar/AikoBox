import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(scriptDirectory, '..')

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8'))
}

function invariant(condition, message) {
  if (!condition) throw new Error(message)
}

function sha256(contents) {
  return createHash('sha256').update(contents).digest('hex')
}

function canonicalLicenseText(contents) {
  invariant(Buffer.isBuffer(contents), 'License contents must be a buffer')
  return Buffer.from(contents.toString('utf8').replace(/\r\n?/g, '\n'), 'utf8')
}

export function isRecognizedRootLicenseFileName(name) {
  return (
    /^(?:license|licence|copying|notice)(?:\.|$)/i.test(name) || /^licen[cs]e-mit\.txt$/i.test(name)
  )
}

export function extractReviewedLicenseSection(contents, startMarker, endMarker, label) {
  invariant(Buffer.isBuffer(contents), `${label}: source contents must be a buffer`)
  invariant(
    typeof startMarker === 'string' && startMarker.length > 0,
    `${label}: section start marker is missing`
  )
  invariant(
    typeof endMarker === 'string' && endMarker.length > 0,
    `${label}: section end marker is missing`
  )
  const start = contents.indexOf(Buffer.from(startMarker, 'utf8'))
  invariant(start >= 0, `${label}: section start marker was not found`)
  invariant(
    contents.indexOf(Buffer.from(startMarker, 'utf8'), start + 1) === -1,
    `${label}: section start marker is ambiguous`
  )
  const endMarkerBuffer = Buffer.from(endMarker, 'utf8')
  const end = contents.indexOf(endMarkerBuffer, start)
  invariant(end >= 0, `${label}: section end marker was not found`)
  invariant(
    contents.indexOf(endMarkerBuffer, end + 1) === -1,
    `${label}: section end marker is ambiguous`
  )
  return contents.subarray(start, end + endMarkerBuffer.length)
}

function comparableFsPath(filePath) {
  const normalized = path.normalize(filePath).replace(/^\\\\\?\\/, '')
  return process.platform === 'win32' ? normalized.toLowerCase() : normalized
}

export function resolveEvidenceFile(
  relativePath,
  label,
  root = repositoryRoot,
  allowMissing = false
) {
  invariant(typeof relativePath === 'string' && relativePath.length > 0, `${label}: empty path`)
  invariant(!relativePath.includes('\0'), `${label}: path contains a NUL byte`)
  invariant(!relativePath.includes('\\'), `${label}: path must use forward slashes`)
  invariant(
    !path.posix.isAbsolute(relativePath) && !path.win32.isAbsolute(relativePath),
    `${label}: path must be repository-relative`
  )
  const segments = relativePath.split('/')
  invariant(
    segments.every(
      (segment) =>
        segment.length > 0 && segment !== '.' && segment !== '..' && !segment.includes(':')
    ),
    `${label}: path must be canonical and must not escape the repository`
  )

  const absoluteRoot = path.resolve(root)
  invariant(fs.existsSync(absoluteRoot), `${label}: repository root is missing`)
  const realRoot = fs.realpathSync.native(absoluteRoot)
  const absolutePath = path.resolve(absoluteRoot, ...segments)
  const relative = path.relative(absoluteRoot, absolutePath)
  invariant(
    relative && !relative.startsWith('..') && !path.isAbsolute(relative),
    `${label}: path escapes the repository`
  )

  let lexicalPath = absoluteRoot
  let expectedRealPath = realRoot
  for (const segment of segments) {
    lexicalPath = path.join(lexicalPath, segment)
    expectedRealPath = path.join(expectedRealPath, segment)
    let stat
    try {
      stat = fs.lstatSync(lexicalPath)
    } catch (error) {
      if (error?.code === 'ENOENT' && allowMissing) return absolutePath
      throw error
    }
    invariant(!stat.isSymbolicLink(), `${label}: path passes through a symbolic link or junction`)
    const actualRealPath = fs.realpathSync.native(lexicalPath)
    invariant(
      comparableFsPath(actualRealPath) === comparableFsPath(expectedRealPath),
      `${label}: path passes through a symbolic link or junction`
    )
  }

  const realPath = fs.realpathSync.native(absolutePath)
  const realRelative = path.relative(realRoot, realPath)
  invariant(
    realRelative && !realRelative.startsWith('..') && !path.isAbsolute(realRelative),
    `${label}: resolved path escapes the repository`
  )
  return absolutePath
}

export function getResourceNoticeSection(notice, name) {
  const marker = `<!-- resource:${name} -->`
  const start = notice.indexOf(marker)
  invariant(start >= 0, `${name}: notice marker is missing`)
  invariant(notice.lastIndexOf(marker) === start, `${name}: notice marker is duplicated`)
  const candidates = [
    notice.indexOf('<!-- resource:', start + marker.length),
    notice.indexOf('\n## ', start + marker.length)
  ].filter((offset) => offset >= 0)
  const end = candidates.length > 0 ? Math.min(...candidates) : notice.length
  return notice.slice(start, end)
}

export function parseGoBuildinfoModules(text) {
  invariant(typeof text === 'string' && text.length > 0, 'buildinfo text is empty')
  const lines = text.replace(/\r\n?/g, '\n').split('\n')
  let goVersion = ''
  let mainModule = ''
  let mainVersion = ''
  const deps = []
  for (const rawLine of lines) {
    const line = rawLine.replace(/^\t/, '')
    const goMatch = /: (go\d+\.\d+(?:\.\d+)?)\s*$/.exec(rawLine)
    if (
      goMatch &&
      !rawLine.startsWith('\t') &&
      !rawLine.startsWith('dep') &&
      !rawLine.startsWith('mod')
    ) {
      goVersion = goMatch[1]
      continue
    }
    if (line.startsWith('mod\t')) {
      const parts = line.slice(4).split('\t')
      mainModule = parts[0] ?? ''
      mainVersion = parts[1] ?? ''
      continue
    }
    if (line.startsWith('dep\t')) {
      const parts = line.slice(4).split('\t')
      if (parts[0]) deps.push({ path: parts[0], version: parts[1] ?? '', sum: parts[2] ?? '' })
    }
  }
  invariant(goVersion, 'buildinfo is missing the Go toolchain version')
  invariant(mainModule && mainVersion, 'buildinfo is missing the main module identity')
  invariant(deps.length > 0, 'buildinfo contains no static dependency entries')
  return { goVersion, mainModule, mainVersion, depCount: deps.length, deps }
}

function assertSourceIdentityFiles(name, partial, noticeSection) {
  invariant(
    Array.isArray(partial.sourceIdentityFiles) && partial.sourceIdentityFiles.length > 0,
    `${name}: source identity files are missing`
  )
  for (const identity of partial.sourceIdentityFiles) {
    invariant(
      typeof identity.kind === 'string' && identity.kind.length > 0,
      `${name}: source identity kind is missing`
    )
    invariant(
      Number.isSafeInteger(identity.size) && identity.size > 0,
      `${name}: source identity size is invalid`
    )
    invariant(/^[a-f0-9]{64}$/.test(identity.sha256), `${name}: source identity SHA-256 is invalid`)
    invariant(
      /^https:\/\/raw\.githubusercontent\.com\//.test(identity.sourceUrl) &&
        identity.sourceUrl.includes(`/${partial.release.tagCommit}/`),
      `${name}: source identity URL is not pinned to the release commit`
    )
    const absolutePath = resolveEvidenceFile(identity.path, `${name}: source identity file`)
    const contents = fs.readFileSync(absolutePath)
    invariant(
      contents.length === identity.size && sha256(contents) === identity.sha256,
      `${name}: source identity file differs from review`
    )
    for (const required of [identity.path, identity.sha256, identity.sourceUrl]) {
      invariant(
        noticeSection.includes(required),
        `${name}: source identity evidence is absent from notice`
      )
    }
  }
}

function assertBuildinfoInventory(name, partial, resource, noticeSection) {
  const inventory = partial.buildinfoInventory
  invariant(inventory && typeof inventory === 'object', `${name}: buildinfo inventory is missing`)
  invariant(
    Number.isSafeInteger(inventory.size) && inventory.size > 0,
    `${name}: buildinfo inventory size is invalid`
  )
  invariant(
    /^[a-f0-9]{64}$/.test(inventory.sha256),
    `${name}: buildinfo inventory SHA-256 is invalid`
  )
  invariant(
    inventory.binarySha256 === resource.sha256,
    `${name}: buildinfo inventory is not bound to the locked binary SHA-256`
  )
  invariant(
    Number.isSafeInteger(inventory.depCount) && inventory.depCount > 0,
    `${name}: buildinfo dependency count is invalid`
  )
  const absolutePath = resolveEvidenceFile(inventory.path, `${name}: buildinfo inventory`)
  const contents = fs.readFileSync(absolutePath)
  invariant(
    contents.length === inventory.size && sha256(contents) === inventory.sha256,
    `${name}: buildinfo inventory differs from review`
  )
  const parsed = parseGoBuildinfoModules(contents.toString('utf8'))
  invariant(
    parsed.goVersion === inventory.goVersion,
    `${name}: buildinfo Go version differs from review`
  )
  invariant(
    parsed.mainModule === inventory.mainModule && parsed.mainVersion === inventory.mainVersion,
    `${name}: buildinfo main module differs from review`
  )
  invariant(
    parsed.depCount === inventory.depCount,
    `${name}: buildinfo dependency count differs from review`
  )
  if (inventory.tsvPath) {
    invariant(
      Number.isSafeInteger(inventory.tsvSize) && inventory.tsvSize > 0,
      `${name}: buildinfo TSV size is invalid`
    )
    invariant(
      /^[a-f0-9]{64}$/.test(inventory.tsvSha256),
      `${name}: buildinfo TSV SHA-256 is invalid`
    )
    const tsvPath = resolveEvidenceFile(inventory.tsvPath, `${name}: buildinfo TSV`)
    const tsvContents = fs.readFileSync(tsvPath)
    invariant(
      tsvContents.length === inventory.tsvSize && sha256(tsvContents) === inventory.tsvSha256,
      `${name}: buildinfo TSV differs from review`
    )
  }
  for (const required of [
    inventory.path,
    inventory.sha256,
    inventory.goVersion,
    inventory.mainModule,
    inventory.mainVersion,
    String(inventory.depCount),
    inventory.binarySha256
  ]) {
    invariant(
      noticeSection.includes(required),
      `${name}: buildinfo inventory evidence is absent from notice`
    )
  }

  // When the locked sidecar is present, re-extract build-info offline and
  // compare normalized module identity (never runs the proxy service).
  if (resource.output && typeof resource.output === 'string') {
    const binaryPath = resolveEvidenceFile(
      resource.output,
      `${name}: sidecar binary`,
      repositoryRoot,
      true
    )
    if (fs.existsSync(binaryPath)) {
      const binaryContents = fs.readFileSync(binaryPath)
      invariant(
        binaryContents.length === resource.size && sha256(binaryContents) === resource.sha256,
        `${name}: local sidecar binary does not match the lock`
      )
      const probe = spawnSync('go', ['version', '-m', binaryPath], {
        cwd: repositoryRoot,
        encoding: 'utf8',
        windowsHide: true
      })
      if (probe.error?.code === 'ENOENT') {
        // Go toolchain is optional on hosts that only run the audit.
        return
      }
      invariant(probe.status === 0, `${name}: go version -m failed for the locked sidecar`)
      const live = parseGoBuildinfoModules(String(probe.stdout))
      invariant(
        live.goVersion === parsed.goVersion &&
          live.mainModule === parsed.mainModule &&
          live.mainVersion === parsed.mainVersion &&
          live.depCount === parsed.depCount,
        `${name}: live go version -m identity differs from packaged buildinfo inventory`
      )
      const packagedKeys = new Set(parsed.deps.map((dep) => `${dep.path}@${dep.version}`))
      const liveKeys = new Set(live.deps.map((dep) => `${dep.path}@${dep.version}`))
      invariant(
        packagedKeys.size === liveKeys.size && [...packagedKeys].every((key) => liveKeys.has(key)),
        `${name}: live go version -m dependency set differs from packaged buildinfo inventory`
      )
    }
  }
}

function assertBufferRange(contents, offset, length, label) {
  invariant(
    Number.isSafeInteger(offset) &&
      Number.isSafeInteger(length) &&
      offset >= 0 &&
      length >= 0 &&
      offset + length <= contents.length,
    `${label}: invalid or truncated font table`
  )
}

function decodeSfntNameString(contents, platformId) {
  if (platformId !== 0 && platformId !== 3) return contents.toString('latin1')
  invariant(contents.length % 2 === 0, 'Font name record has invalid UTF-16BE length')
  let value = ''
  for (let offset = 0; offset < contents.length; offset += 2) {
    value += String.fromCharCode(contents.readUInt16BE(offset))
  }
  return value
}

export function readSfntNameMetadata(filePath) {
  const contents = fs.readFileSync(filePath)
  assertBufferRange(contents, 0, 12, 'SFNT header')
  const tableCount = contents.readUInt16BE(4)
  assertBufferRange(contents, 12, tableCount * 16, 'SFNT table directory')

  let nameTable
  for (let index = 0; index < tableCount; index += 1) {
    const recordOffset = 12 + index * 16
    if (contents.toString('ascii', recordOffset, recordOffset + 4) !== 'name') continue
    nameTable = {
      offset: contents.readUInt32BE(recordOffset + 8),
      length: contents.readUInt32BE(recordOffset + 12)
    }
    break
  }
  invariant(nameTable, 'Font has no SFNT name table')
  assertBufferRange(contents, nameTable.offset, nameTable.length, 'SFNT name table')
  invariant(nameTable.length >= 6, 'SFNT name table header is truncated')

  const recordCount = contents.readUInt16BE(nameTable.offset + 2)
  const stringOffset = contents.readUInt16BE(nameTable.offset + 4)
  invariant(6 + recordCount * 12 <= nameTable.length, 'SFNT name records are truncated')
  invariant(stringOffset <= nameTable.length, 'SFNT name string storage is invalid')

  const values = new Map()
  for (let index = 0; index < recordCount; index += 1) {
    const recordOffset = nameTable.offset + 6 + index * 12
    const platformId = contents.readUInt16BE(recordOffset)
    const nameId = contents.readUInt16BE(recordOffset + 6)
    if (nameId !== 0 && nameId !== 5) continue
    const length = contents.readUInt16BE(recordOffset + 8)
    const offset = contents.readUInt16BE(recordOffset + 10)
    const valueOffset = nameTable.offset + stringOffset + offset
    assertBufferRange(contents, valueOffset, length, 'SFNT name value')
    invariant(
      valueOffset + length <= nameTable.offset + nameTable.length,
      'SFNT name value escapes its table'
    )
    const value = decodeSfntNameString(
      contents.subarray(valueOffset, valueOffset + length),
      platformId
    )
    if (!values.has(nameId)) values.set(nameId, new Set())
    values.get(nameId).add(value)
  }

  const copyrightValues = [...(values.get(0) ?? [])]
  const versionValues = [...(values.get(5) ?? [])]
  invariant(copyrightValues.length === 1, 'Font must contain one unique copyright record')
  invariant(versionValues.length === 1, 'Font must contain one unique version record')
  const versionRecord = versionValues[0]
  const match = /^Version ([0-9]+\.[0-9]+);GOOG;noto-emoji:([0-9]{8}):([a-f0-9]{40})$/.exec(
    versionRecord
  )
  invariant(match, 'Font version record does not contain pinned noto-emoji build metadata')
  return {
    version: match[1],
    buildDate: match[2],
    buildRevision: match[3],
    copyright: copyrightValues[0],
    versionRecord
  }
}

function assertVerifiedNotice(name, noticeSection) {
  invariant(
    /### [^\n]+ — `VERIFIED`/.test(noticeSection),
    `${name}: notice does not claim VERIFIED evidence`
  )
}

function verifyEvidenceRecord(record, label, noticeSection) {
  invariant(record && typeof record === 'object', `${label}: evidence record is missing`)
  invariant(
    Number.isSafeInteger(record.size) && record.size > 0,
    `${label}: evidence size is invalid`
  )
  invariant(/^[a-f0-9]{64}$/.test(record.sha256), `${label}: evidence SHA-256 is invalid`)
  const absolutePath = resolveEvidenceFile(record.path, label)
  const contents = fs.readFileSync(absolutePath)
  invariant(
    contents.length === record.size && sha256(contents) === record.sha256,
    `${label}: size or SHA-256 differs from its evidence lock`
  )
  if (noticeSection) {
    invariant(noticeSection.includes(record.path), `${label}: path is absent from notice`)
    invariant(noticeSection.includes(record.sha256), `${label}: SHA-256 is absent from notice`)
  }
  return { absolutePath, contents }
}

export function assertSafeEvidenceArchiveEntries(entries, label) {
  invariant(Array.isArray(entries) && entries.length > 0, `${label}: archive is empty`)
  const roots = new Set()
  for (const entry of entries) {
    invariant(typeof entry === 'string' && entry.length > 0, `${label}: empty archive entry`)
    invariant(!entry.includes('\0') && !entry.includes('\\'), `${label}: unsafe archive entry`)
    invariant(
      !path.posix.isAbsolute(entry) && !path.win32.isAbsolute(entry),
      `${label}: absolute archive entry`
    )
    const normalized = entry.replace(/\/$/, '')
    const segments = normalized.split('/')
    invariant(
      segments.every((segment) => segment.length > 0 && segment !== '.' && segment !== '..'),
      `${label}: archive traversal entry`
    )
    roots.add(segments[0])
  }
  invariant(roots.size === 1, `${label}: archive must have exactly one top-level directory`)
  return [...roots][0]
}

function listTarGzEntries(archivePath, label) {
  const result = spawnSync('tar', ['-tzf', archivePath], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    windowsHide: true,
    maxBuffer: 64 * 1024 * 1024
  })
  invariant(result.error === undefined, `${label}: unable to inspect archive: ${result.error}`)
  invariant(result.status === 0, `${label}: tar listing failed: ${String(result.stderr).trim()}`)
  const entries = String(result.stdout).replaceAll('\r\n', '\n').split('\n').filter(Boolean)
  assertSafeEvidenceArchiveEntries(entries, label)
  return new Set(entries.map((entry) => entry.replace(/\/$/, '')))
}

function parseSysproxyInventory(contents) {
  const lines = contents.toString('utf8').replaceAll('\r\n', '\n').trim().split('\n')
  invariant(
    lines.shift() ===
      'crate\tversion\tspdx_license\tregistry_source\tcrate_sha256\tvendor_directory\tlegal_files\tlegal_provenance',
    'sysproxy: dependency inventory header is invalid'
  )
  const records = lines.map((line) => {
    const fields = line.split('\t')
    invariant(fields.length === 8, `sysproxy: malformed dependency inventory row: ${line}`)
    const [crate, version, license, source, crateSha256, vendorDirectory, legal, provenance] =
      fields
    invariant(crate && version && license, 'sysproxy: dependency identity is incomplete')
    invariant(
      source === 'registry+https://github.com/rust-lang/crates.io-index',
      `${crate}@${version}: registry source is not fixed`
    )
    invariant(/^[a-f0-9]{64}$/.test(crateSha256), `${crate}@${version}: crate hash is invalid`)
    invariant(
      vendorDirectory === `${crate}-${version}` &&
        !vendorDirectory.includes('/') &&
        !vendorDirectory.includes('\\'),
      `${crate}@${version}: vendor directory is invalid`
    )
    const legalFiles = legal.split(';').filter(Boolean)
    invariant(legalFiles.length > 0, `${crate}@${version}: legal files are missing`)
    invariant(provenance.length > 0, `${crate}@${version}: legal provenance is missing`)
    return { crate, version, vendorDirectory, legalFiles }
  })
  const identities = new Set(records.map((record) => `${record.crate}@${record.version}`))
  invariant(identities.size === records.length, 'sysproxy: duplicate dependency inventory row')
  return records
}

function assertPeAmd64Dll(contents, label) {
  invariant(contents.length >= 256, `${label}: native module is too small`)
  invariant(contents[0] === 0x4d && contents[1] === 0x5a, `${label}: MZ header is missing`)
  const peOffset = contents.readUInt32LE(0x3c)
  invariant(peOffset + 24 <= contents.length, `${label}: PE header is truncated`)
  invariant(
    contents.toString('ascii', peOffset, peOffset + 4) === 'PE\0\0',
    `${label}: PE signature is missing`
  )
  invariant(contents.readUInt16LE(peOffset + 4) === 0x8664, `${label}: PE machine is not AMD64`)
  invariant(
    (contents.readUInt16LE(peOffset + 22) & 0x2000) !== 0,
    `${label}: PE image is not a DLL`
  )
}

export function verifyPinnedEvidenceLock(contents, reviewedLock, label = 'evidence lock') {
  invariant(Buffer.isBuffer(contents), `${label}: contents must be a buffer`)
  invariant(
    reviewedLock &&
      Number.isSafeInteger(reviewedLock.size) &&
      reviewedLock.size > 0 &&
      /^[a-f0-9]{64}$/.test(reviewedLock.sha256),
    `${label}: reviewed size or SHA-256 is invalid`
  )
  invariant(
    contents.length === reviewedLock.size && sha256(contents) === reviewedLock.sha256,
    `${label}: size or SHA-256 differs from review`
  )
  return JSON.parse(contents.toString('utf8'))
}

export function verifySysproxyVerifiedEvidence(resource, item, noticeSection) {
  assertVerifiedNotice('sysproxy', noticeSection)
  invariant(
    item.evidenceLock?.path === 'licenses/sysproxy-rs-opti/evidence-lock.json' &&
      item.evidenceLock.schemaVersion === 1 &&
      Number.isSafeInteger(item.evidenceLock.size) &&
      item.evidenceLock.size > 0 &&
      /^[a-f0-9]{64}$/.test(item.evidenceLock.sha256) &&
      item.evidenceLock.dependencyCount === 48 &&
      item.evidenceLock.vendorPackageCount === 126,
    'sysproxy: review does not pin the expected evidence-lock contract'
  )
  const evidenceLockPath = resolveEvidenceFile(item.evidenceLock.path, 'sysproxy: evidence lock')
  const evidenceLockContents = fs.readFileSync(evidenceLockPath)
  const evidenceLockHash = sha256(evidenceLockContents)
  invariant(
    noticeSection.includes('licenses/sysproxy-rs-opti/evidence-lock.json'),
    'sysproxy: evidence-lock path is absent from notice'
  )
  const evidence = verifyPinnedEvidenceLock(
    evidenceLockContents,
    item.evidenceLock,
    'sysproxy: evidence lock'
  )
  invariant(evidence.schemaVersion === 1, 'sysproxy: unsupported evidence schema')
  invariant(
    evidence.upstream?.project === 'https://github.com/mihomo-party-org/sysproxy-rs-opti' &&
      evidence.upstream.tag === resource.releaseTag &&
      evidence.upstream.commit === resource.releaseTagCommit &&
      evidence.upstream.crateVersion === '0.5.1',
    'sysproxy: upstream identity differs from resource lock'
  )
  invariant(
    evidence.build?.rustVersion === resource.rustVersion &&
      evidence.build.target === resource.target &&
      evidence.build.sourceDateEpoch === resource.sourceDateEpoch &&
      evidence.build.rustflags === resource.rustflags,
    'sysproxy: build identity differs from resource lock'
  )
  invariant(
    Number.isSafeInteger(evidence.dependencyCount) && evidence.dependencyCount >= 25,
    'sysproxy: dependency count is invalid'
  )
  invariant(
    evidence.schemaVersion === item.evidenceLock.schemaVersion &&
      evidence.dependencyCount === item.evidenceLock.dependencyCount &&
      evidence.vendorPackageCount === item.evidenceLock.vendorPackageCount,
    'sysproxy: evidence lock differs from reviewed schema or dependency counts'
  )

  const requiredRecords = [
    'binary',
    'cargoLock',
    'inventory',
    'vendorInventory',
    'buildInfo',
    'notice',
    'correspondingSource',
    'licenseNotices'
  ]
  invariant(
    JSON.stringify(Object.keys(evidence.files ?? {}).sort()) ===
      JSON.stringify([...requiredRecords].sort()),
    'sysproxy: evidence file set is not exact'
  )
  const verified = {}
  for (const name of requiredRecords) {
    verified[name] = verifyEvidenceRecord(
      evidence.files[name],
      `sysproxy: ${name}`,
      name === 'vendorInventory' ? undefined : noticeSection
    )
  }
  invariant(
    evidence.files.binary.path === resource.source &&
      evidence.files.binary.size === resource.size &&
      evidence.files.binary.sha256 === resource.sha256,
    'sysproxy: binary evidence differs from resource lock'
  )
  assertPeAmd64Dll(verified.binary.contents, 'sysproxy')

  const packagedPath = resolveEvidenceFile(
    resource.output,
    'sysproxy: packaged sidecar',
    repositoryRoot,
    true
  )
  if (fs.existsSync(packagedPath)) {
    const packaged = fs.readFileSync(packagedPath)
    invariant(
      packaged.length === resource.size && sha256(packaged) === resource.sha256,
      'sysproxy: packaged sidecar differs from verified binary'
    )
  }

  const records = parseSysproxyInventory(verified.inventory.contents)
  invariant(
    records.length === evidence.dependencyCount,
    'sysproxy: dependency inventory count differs from evidence lock'
  )
  const vendorLines = verified.vendorInventory.contents
    .toString('utf8')
    .replaceAll('\r\n', '\n')
    .trim()
    .split('\n')
  invariant(
    vendorLines.shift() === 'crate\tversion\tcrate_sha256\tvendor_directory',
    'sysproxy: vendor inventory header is invalid'
  )
  const vendorDirectories = new Set()
  for (const line of vendorLines) {
    const [crate, version, crateSha256, vendorDirectory, ...extra] = line.split('\t')
    invariant(
      crate &&
        version &&
        /^[a-f0-9]{64}$/.test(crateSha256) &&
        vendorDirectory === `${crate}-${version}` &&
        extra.length === 0,
      `sysproxy: malformed vendor inventory row: ${line}`
    )
    invariant(
      !vendorDirectories.has(vendorDirectory),
      `sysproxy: duplicate vendor ${vendorDirectory}`
    )
    vendorDirectories.add(vendorDirectory)
  }
  invariant(
    vendorDirectories.size === evidence.vendorPackageCount,
    'sysproxy: vendor inventory count differs from evidence lock'
  )
  const sourceEntries = listTarGzEntries(
    verified.correspondingSource.absolutePath,
    'sysproxy corresponding source'
  )
  const licenseEntries = listTarGzEntries(
    verified.licenseNotices.absolutePath,
    'sysproxy license notices'
  )
  const sourcePrefix = 'sysproxy-rs-opti-v0.1.0-windows-x64-corresponding-source'
  const licensePrefix = 'sysproxy-rs-opti-v0.1.0-windows-x64-license-notices'
  for (const required of [
    `${sourcePrefix}/upstream/Cargo.toml`,
    `${sourcePrefix}/upstream/Cargo.lock`,
    `${sourcePrefix}/upstream/LICENSE`,
    `${sourcePrefix}/.cargo/config.toml`,
    `${sourcePrefix}/BUILD-INFO.txt`,
    `${sourcePrefix}/rust-production-dependencies.tsv`,
    `${licensePrefix}/upstream/LICENSE`,
    `${licensePrefix}/NOTICE.txt`,
    `${licensePrefix}/rust-production-dependencies.tsv`
  ]) {
    invariant(
      sourceEntries.has(required) || licenseEntries.has(required),
      `sysproxy: release archive is missing ${required}`
    )
  }
  for (const record of records) {
    invariant(
      sourceEntries.has(`${sourcePrefix}/vendor/${record.vendorDirectory}/Cargo.toml`) &&
        sourceEntries.has(`${sourcePrefix}/vendor/${record.vendorDirectory}/.cargo-checksum.json`),
      `${record.crate}@${record.version}: corresponding source is incomplete`
    )
    for (const legalFile of record.legalFiles) {
      invariant(
        licenseEntries.has(`${licensePrefix}/crates/${record.vendorDirectory}/${legalFile}`),
        `${record.crate}@${record.version}: license bundle is missing ${legalFile}`
      )
    }
  }
  for (const vendorDirectory of vendorDirectories) {
    invariant(
      sourceEntries.has(`${sourcePrefix}/vendor/${vendorDirectory}/Cargo.toml`) &&
        sourceEntries.has(`${sourcePrefix}/vendor/${vendorDirectory}/.cargo-checksum.json`),
      `sysproxy: corresponding source omits vendored package ${vendorDirectory}`
    )
  }
  const vendoredCargoManifests = [...sourceEntries].filter((entry) =>
    new RegExp(`^${sourcePrefix}/vendor/[^/]+/Cargo\\.toml$`).test(entry)
  )
  const vendoredChecksums = [...sourceEntries].filter((entry) =>
    new RegExp(`^${sourcePrefix}/vendor/[^/]+/\\.cargo-checksum\\.json$`).test(entry)
  )
  invariant(
    vendoredCargoManifests.length === evidence.vendorPackageCount &&
      vendoredChecksums.length === evidence.vendorPackageCount,
    'sysproxy: corresponding source does not cover the complete vendored package graph'
  )
  invariant(
    Array.isArray(evidence.reviewedLegalOverrides) && evidence.reviewedLegalOverrides.length === 6,
    'sysproxy: reviewed legal override set is incomplete'
  )
  for (const override of evidence.reviewedLegalOverrides) {
    invariant(
      /^[a-f0-9]{40}$/.test(override.vcsCommit) &&
        override.sourceUrl.includes(`/${override.vcsCommit}/`),
      `${override.crate}: reviewed legal override is not commit-pinned`
    )
    verifyEvidenceRecord(override, `${override.crate}: reviewed legal override`)
    const directory = override.crate.replace('@', '-')
    invariant(
      sourceEntries.has(
        `${sourcePrefix}/reviewed-license-overrides/${directory}/LICENSE.reviewed-upstream`
      ),
      `${override.crate}: corresponding source omits reviewed legal override`
    )
  }
  return { dependencyCount: records.length, evidenceLockHash }
}

function verifyGeneratedComponentChecksums(distDirectory, prefix, expectedNames, label) {
  const checksumPath = path.join(distDirectory, `${prefix}-SHA256SUMS.txt`)
  const lines = fs.readFileSync(checksumPath, 'utf8').replaceAll('\r\n', '\n').trim().split('\n')
  const found = new Map()
  for (const line of lines) {
    const match = /^([a-f0-9]{64}) {2}([A-Za-z0-9._-]+)$/.exec(line)
    invariant(match, `${label}: malformed component checksum line`)
    invariant(!found.has(match[2]), `${label}: duplicate component checksum entry`)
    found.set(match[2], match[1])
  }
  invariant(
    JSON.stringify([...found.keys()].sort()) === JSON.stringify([...expectedNames].sort()),
    `${label}: component checksum set is not exact`
  )
  for (const [name, digest] of found) {
    const contents = fs.readFileSync(path.join(distDirectory, name))
    invariant(sha256(contents) === digest, `${label}: checksum differs for ${name}`)
  }
}

export function verifyWindowsSingBoxVerifiedEvidence(resource, partial, noticeSection) {
  assertVerifiedNotice('singBox', noticeSection)
  invariant(partial?.release?.tag === resource.releaseTag, 'singBox: release tag differs')
  invariant(
    partial.release.tagCommit === resource.releaseTagCommit,
    'singBox: release commit differs'
  )
  invariant(
    Array.isArray(partial.licenseFiles) && partial.licenseFiles.length === 1,
    'singBox: upstream license evidence is incomplete'
  )
  const licenseFile = partial.licenseFiles[0]
  const licenseContents = fs.readFileSync(
    resolveEvidenceFile(licenseFile.path, 'singBox: upstream license')
  )
  invariant(
    licenseContents.length === licenseFile.size &&
      sha256(licenseContents) === licenseFile.sha256 &&
      licenseFile.sha256 === licenseFile.upstreamSha256,
    'singBox: upstream license evidence differs'
  )
  for (const required of [
    partial.release.tag,
    partial.release.tagCommit,
    partial.release.url,
    partial.release.sourceUrl,
    licenseFile.path,
    licenseFile.sha256,
    licenseFile.sourceUrl,
    licenseFile.upstreamSha256
  ]) {
    invariant(
      noticeSection.includes(required),
      'singBox: reviewed release evidence is absent from notice'
    )
  }
  assertSourceIdentityFiles('singBox', partial, noticeSection)
  assertBuildinfoInventory('singBox', partial, resource, noticeSection)

  const prefix = 'aikobox-sing-box-1.13.14-windows-amd64'
  const generatedNames = [
    `${prefix}-corresponding-source.tar.gz`,
    `${prefix}-licenses.tar.gz`,
    `${prefix}-COVERAGE.json`,
    `${prefix}-SHA256SUMS.txt`
  ]
  for (const name of generatedNames) {
    invariant(noticeSection.includes(name), `singBox: required release asset is absent from notice`)
  }
  const workflow = fs.readFileSync(
    path.join(repositoryRoot, '.github', 'workflows', 'release.yml'),
    'utf8'
  )
  invariant(
    workflow.includes('scripts/license-windows-sing-box-release.mjs'),
    'singBox: release workflow does not invoke the evidence generator'
  )
  for (const name of generatedNames) {
    invariant(workflow.includes(name), `singBox: release workflow omits ${name}`)
  }
  for (const relativePath of [
    'scripts/license-windows-sing-box-release.mjs',
    'scripts/license-windows-sing-box-release.test.mjs'
  ]) {
    const absolutePath = resolveEvidenceFile(relativePath, `singBox: ${relativePath}`)
    invariant(fs.statSync(absolutePath).isFile(), `singBox: ${relativePath} is not a file`)
  }

  const distDirectory = path.join(repositoryRoot, 'dist')
  const presentGenerated = generatedNames.filter((name) =>
    fs.existsSync(path.join(distDirectory, name))
  )
  if (presentGenerated.length > 0) {
    invariant(
      presentGenerated.length === generatedNames.length,
      'singBox: generated release evidence is only partially present'
    )
    const coverage = JSON.parse(
      fs.readFileSync(path.join(distDirectory, `${prefix}-COVERAGE.json`), 'utf8')
    )
    invariant(
      coverage.releaseReady === true &&
        Array.isArray(coverage.blockers) &&
        coverage.blockers.length === 0 &&
        coverage.component === 'sing-box' &&
        coverage.version === '1.13.14' &&
        coverage.commit === resource.releaseTagCommit &&
        coverage.target === 'windows/amd64' &&
        coverage.actualStaticModules === 100 &&
        coverage.coveredActualStaticModules === 100 &&
        Array.isArray(coverage.linkedNativeInputs) &&
        coverage.linkedNativeInputs.length === 0,
      'singBox: generated coverage report is not release-ready'
    )
    verifyGeneratedComponentChecksums(
      distDirectory,
      prefix,
      generatedNames.filter((name) => !name.endsWith('-SHA256SUMS.txt')),
      'singBox'
    )
    const sourceEntries = listTarGzEntries(
      path.join(distDirectory, `${prefix}-corresponding-source.tar.gz`),
      'singBox corresponding source'
    )
    const licenseEntries = listTarGzEntries(
      path.join(distDirectory, `${prefix}-licenses.tar.gz`),
      'singBox licenses'
    )
    invariant(
      sourceEntries.has(`${prefix}-corresponding-source/BUILDING.md`) &&
        sourceEntries.has(`${prefix}-corresponding-source/COVERAGE.json`) &&
        licenseEntries.has(`${prefix}-licenses/COVERAGE.json`) &&
        licenseEntries.has(`${prefix}-licenses/MODULE-LICENSE-MANIFEST.json`),
      'singBox: generated release archives are incomplete'
    )
  }
  return { dynamicAssets: generatedNames.length, generatedAssetsPresent: presentGenerated.length }
}

function inspectResourceReview() {
  const lock = readJson('scripts/resources-lock.json')
  const review = readJson('scripts/third-party-review.json')
  const notice = fs.readFileSync(path.join(repositoryRoot, 'THIRD_PARTY_NOTICES.md'), 'utf8')

  invariant(review.schemaVersion === 1, 'Unsupported third-party review schema')
  invariant(lock.schemaVersion === 1, 'Unsupported resource lock schema')

  const lockNames = Object.keys(lock.resources).sort()
  const reviewNames = Object.keys(review.resources).sort()
  invariant(
    JSON.stringify(reviewNames) === JSON.stringify(lockNames),
    'The third-party review must cover exactly every locked runtime resource'
  )
  const noticeMarkerNames = [...notice.matchAll(/<!-- resource:([A-Za-z0-9_-]+) -->/g)].map(
    (match) => match[1]
  )
  invariant(
    new Set(noticeMarkerNames).size === noticeMarkerNames.length,
    'Third-party notice contains a duplicate resource marker'
  )
  invariant(
    JSON.stringify([...noticeMarkerNames].sort()) === JSON.stringify(lockNames),
    'The third-party notice must contain exactly one section for every locked runtime resource'
  )

  const blockers = []
  const verifiedNativeEvidence = []
  for (const name of lockNames) {
    const resource = lock.resources[name]
    const item = review.resources[name]
    const noticeSection = getResourceNoticeSection(notice, name)
    invariant(item.status === 'blocked' || item.status === 'verified', `${name}: invalid status`)
    invariant(/^https:\/\//.test(item.project), `${name}: project URL must use HTTPS`)
    invariant(
      noticeSection.includes(resource.version),
      `${name}: locked version is absent from notice`
    )
    invariant(
      noticeSection.includes(item.project),
      `${name}: reviewed project URL is absent from notice`
    )

    const locator = resource.downloadUrl ?? resource.source
    invariant(
      noticeSection.includes(locator),
      `${name}: locked source locator is absent from notice`
    )

    for (const hashField of ['sha256', 'archiveSha256', 'directorySha256']) {
      if (resource[hashField]) {
        invariant(
          noticeSection.includes(resource[hashField]),
          `${name}: ${hashField} is absent from notice`
        )
      }
    }

    if (item.status === 'verified' && item.verificationModel !== undefined) {
      invariant(item.blocker === undefined, `${name}: verified item still declares a blocker`)
      invariant(
        typeof item.license === 'string' && item.license.length > 0,
        `${name}: verified license expression is missing`
      )
      invariant(
        typeof item.licenseCopyright === 'string' && item.licenseCopyright.length > 0,
        `${name}: verified license copyright is missing`
      )
      invariant(noticeSection.includes(item.license), `${name}: license is absent from notice`)
      invariant(
        noticeSection.includes(item.licenseCopyright),
        `${name}: license copyright is absent from notice`
      )
      if (item.verificationModel === 'windows-sing-box-release-v1') {
        verifyWindowsSingBoxVerifiedEvidence(resource, item, noticeSection)
      } else if (item.verificationModel === 'sysproxy-evidence-lock-v1') {
        verifySysproxyVerifiedEvidence(resource, item, noticeSection)
      } else {
        throw new Error(`${name}: unsupported verification model ${item.verificationModel}`)
      }
      verifiedNativeEvidence.push(name)
      continue
    }

    if (item.status === 'blocked') {
      invariant(item.blocker.length >= 40, `${name}: release blocker is not specific enough`)
      invariant(
        noticeSection.includes(item.blocker),
        `${name}: release blocker is absent from notice`
      )
      if (item.partialEvidence !== undefined) {
        const partial = item.partialEvidence
        invariant(
          typeof partial.license === 'string' && partial.license.length > 0,
          `${name}: partial license expression is missing`
        )
        invariant(
          typeof partial.licenseCopyright === 'string' && partial.licenseCopyright.length > 0,
          `${name}: partial license copyright is missing`
        )
        invariant(
          partial.release && typeof partial.release === 'object',
          `${name}: partial release is missing`
        )
        invariant(
          partial.release.tag === resource.releaseTag,
          `${name}: partial release tag differs from lock`
        )
        invariant(
          partial.release.tagCommit === resource.releaseTagCommit &&
            /^[a-f0-9]{40}$/.test(partial.release.tagCommit),
          `${name}: partial release commit differs from lock`
        )
        for (const [label, value] of [
          ['release URL', partial.release.url],
          ['source URL', partial.release.sourceUrl]
        ]) {
          invariant(/^https:\/\//.test(value), `${name}: partial ${label} must use HTTPS`)
        }
        invariant(
          partial.release.sourceUrl.includes(partial.release.tagCommit),
          `${name}: partial source URL is not pinned to the release commit`
        )
        invariant(
          Array.isArray(partial.licenseFiles) && partial.licenseFiles.length > 0,
          `${name}: partial license files are missing`
        )
        for (const licenseFile of partial.licenseFiles) {
          invariant(
            Number.isSafeInteger(licenseFile.size) && licenseFile.size > 0,
            `${name}: partial license file size is invalid`
          )
          invariant(
            /^[a-f0-9]{64}$/.test(licenseFile.sha256) &&
              licenseFile.sha256 === licenseFile.upstreamSha256,
            `${name}: partial license SHA-256 is invalid`
          )
          invariant(
            /^https:\/\/raw\.githubusercontent\.com\//.test(licenseFile.sourceUrl) &&
              licenseFile.sourceUrl.includes(`/${partial.release.tagCommit}/`),
            `${name}: partial license URL is not pinned to the release commit`
          )
          const absolutePath = resolveEvidenceFile(
            licenseFile.path,
            `${name}: partial license file`
          )
          const contents = fs.readFileSync(absolutePath)
          invariant(
            contents.length === licenseFile.size && sha256(contents) === licenseFile.sha256,
            `${name}: partial license file differs from review`
          )
          invariant(
            contents.toString('utf8').includes(partial.licenseCopyright),
            `${name}: partial license file omits copyright`
          )
          for (const required of [
            partial.license,
            partial.licenseCopyright,
            partial.release.tag,
            partial.release.tagCommit,
            partial.release.url,
            partial.release.sourceUrl,
            licenseFile.path,
            licenseFile.sha256,
            licenseFile.sourceUrl,
            licenseFile.upstreamSha256
          ]) {
            invariant(
              noticeSection.includes(required),
              `${name}: partial evidence is absent from notice`
            )
          }
        }
        if (partial.sourceIdentityFiles !== undefined) {
          assertSourceIdentityFiles(name, partial, noticeSection)
        }
        if (partial.buildinfoInventory !== undefined) {
          assertBuildinfoInventory(name, partial, resource, noticeSection)
        }
      }
      blockers.push(name)
    } else {
      invariant(
        typeof item.license === 'string' && item.license.length > 0,
        `${name}: verified license expression is missing`
      )
      invariant(
        typeof item.licenseCopyright === 'string' && item.licenseCopyright.length > 0,
        `${name}: verified license copyright notice is missing`
      )
      invariant(item.blocker === undefined, `${name}: verified item still declares a blocker`)
      invariant(item.release && typeof item.release === 'object', `${name}: release is missing`)
      invariant(/^https:\/\//.test(item.release.url), `${name}: release URL must use HTTPS`)
      invariant(/^v?\d/.test(item.release.tag), `${name}: release tag is invalid`)
      invariant(
        /^[a-f0-9]{40}$/.test(item.release.tagCommit),
        `${name}: release tag commit is invalid`
      )
      invariant(resource.releaseTag === item.release.tag, `${name}: release tag differs from lock`)
      invariant(
        resource.releaseTagCommit === item.release.tagCommit,
        `${name}: release tag commit differs from lock`
      )

      invariant(noticeSection.includes(item.license), `${name}: license is absent from notice`)
      invariant(
        noticeSection.includes(item.licenseCopyright),
        `${name}: license copyright is absent from notice`
      )
      invariant(
        noticeSection.includes(item.release.url),
        `${name}: release URL is absent from notice`
      )
      invariant(
        noticeSection.includes(item.release.tag),
        `${name}: release tag is absent from notice`
      )
      invariant(
        noticeSection.includes(item.release.tagCommit),
        `${name}: release tag commit is absent from notice`
      )

      if (resource.fontMetadata !== undefined || item.fontMetadata !== undefined) {
        invariant(
          resource.fontMetadata && item.fontMetadata,
          `${name}: font metadata must be present in both lock and review`
        )
        invariant(
          JSON.stringify(resource.fontMetadata) === JSON.stringify(item.fontMetadata),
          `${name}: reviewed font metadata differs from lock`
        )
        invariant(
          resource.version === item.fontMetadata.version,
          `${name}: font metadata version differs from locked version`
        )
        invariant(/^[0-9]{8}$/.test(item.fontMetadata.buildDate), `${name}: build date is invalid`)
        invariant(
          /^[a-f0-9]{40}$/.test(item.fontMetadata.buildRevision),
          `${name}: embedded build revision is invalid`
        )
        invariant(
          typeof item.fontMetadata.copyright === 'string' && item.fontMetadata.copyright.length > 0,
          `${name}: embedded font copyright is missing`
        )

        const fontPath = resolveEvidenceFile(
          resource.output,
          `${name}: packaged font`,
          repositoryRoot,
          true
        )
        if (fs.existsSync(fontPath)) {
          const fontStat = fs.lstatSync(fontPath)
          invariant(
            fontStat.isFile() && !fontStat.isSymbolicLink(),
            `${name}: font path is not a file`
          )
          const fontContents = fs.readFileSync(fontPath)
          invariant(
            fontContents.length === resource.size && sha256(fontContents) === resource.sha256,
            `${name}: local font does not match its locked size and SHA-256`
          )
          const embedded = readSfntNameMetadata(fontPath)
          for (const field of ['version', 'buildDate', 'buildRevision', 'copyright']) {
            invariant(
              embedded[field] === item.fontMetadata[field],
              `${name}: embedded font ${field} differs from reviewed metadata`
            )
          }
        }
        for (const field of ['version', 'buildDate', 'buildRevision', 'copyright']) {
          invariant(
            noticeSection.includes(item.fontMetadata[field]),
            `${name}: embedded font ${field} is absent from notice`
          )
        }
      }

      invariant(
        Array.isArray(item.evidence) && item.evidence.length > 0,
        `${name}: verified evidence is missing`
      )
      const evidenceTypes = new Set()
      const evidenceUrls = new Set()
      for (const evidence of item.evidence) {
        invariant(
          evidence && typeof evidence.type === 'string' && evidence.type.length > 0,
          `${name}: evidence type is missing`
        )
        invariant(/^https:\/\//.test(evidence.url), `${name}: evidence URL must use HTTPS`)
        invariant(!evidenceTypes.has(evidence.type), `${name}: duplicate evidence type`)
        invariant(!evidenceUrls.has(evidence.url), `${name}: duplicate evidence URL`)
        evidenceTypes.add(evidence.type)
        evidenceUrls.add(evidence.url)
        invariant(
          noticeSection.includes(evidence.url),
          `${name}: evidence URL is absent from notice`
        )
      }

      invariant(
        Array.isArray(item.licenseFiles) && item.licenseFiles.length > 0,
        `${name}: verified license files are missing`
      )
      const licensePaths = new Set()
      for (const licenseFile of item.licenseFiles) {
        invariant(
          licenseFile && /^[a-f0-9]{64}$/.test(licenseFile.sha256),
          `${name}: license file SHA-256 is invalid`
        )
        invariant(
          /^https:\/\//.test(licenseFile.sourceUrl),
          `${name}: license source URL must use HTTPS`
        )
        invariant(
          /^[a-f0-9]{64}$/.test(licenseFile.upstreamSha256),
          `${name}: upstream license SHA-256 is invalid`
        )
        invariant(
          typeof licenseFile.transformation === 'string' && licenseFile.transformation.length >= 40,
          `${name}: license normalization record is missing`
        )
        invariant(!licensePaths.has(licenseFile.path), `${name}: duplicate license file`)
        licensePaths.add(licenseFile.path)
        const absolutePath = resolveEvidenceFile(licenseFile.path, `${name}: license file`)
        invariant(fs.existsSync(absolutePath), `${name}: license file is missing`)
        const stat = fs.lstatSync(absolutePath)
        invariant(stat.isFile() && !stat.isSymbolicLink(), `${name}: license path is not a file`)
        const contents = fs.readFileSync(absolutePath)
        invariant(
          sha256(contents) === licenseFile.sha256,
          `${name}: license file does not match its reviewed SHA-256`
        )
        invariant(
          contents.toString('utf8').includes(item.licenseCopyright),
          `${name}: license file omits the reviewed license copyright`
        )
        invariant(
          noticeSection.includes(licenseFile.path),
          `${name}: license path is absent from notice`
        )
        invariant(
          noticeSection.includes(licenseFile.sha256),
          `${name}: license file SHA-256 is absent from notice`
        )
        invariant(
          noticeSection.includes(licenseFile.sourceUrl),
          `${name}: license source URL is absent from notice`
        )
        invariant(
          noticeSection.includes(licenseFile.upstreamSha256),
          `${name}: upstream license SHA-256 is absent from notice`
        )
        invariant(
          noticeSection.includes(licenseFile.transformation),
          `${name}: license normalization record is absent from notice`
        )
      }
    }
  }

  return {
    blockers,
    verifiedNativeEvidence,
    reviewedLicenseExpressions: review.reviewedProductionLicenseExpressions,
    expectedPackagesWithoutLicenseFiles: review.productionPackagesWithoutLicenseFiles,
    productionPackageEvidence: review.productionPackageEvidence,
    thirdPartyNotice: notice
  }
}

function inspectProductionDependencyMetadata(
  reviewedLicenseExpressions,
  expectedPackagesWithoutLicenseFiles,
  productionPackageEvidence,
  thirdPartyNotice
) {
  const command =
    process.platform === 'win32'
      ? {
          executable: process.env.ComSpec ?? 'C:\\Windows\\System32\\cmd.exe',
          arguments: ['/d', '/s', '/c', 'pnpm licenses list --prod --json']
        }
      : { executable: 'pnpm', arguments: ['licenses', 'list', '--prod', '--json'] }
  const result = spawnSync(command.executable, command.arguments, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    shell: false,
    windowsHide: true
  })

  invariant(result.error === undefined, `Unable to run pnpm license inventory: ${result.error}`)
  invariant(result.status === 0, `pnpm license inventory failed: ${result.stderr.trim()}`)
  const inventory = JSON.parse(result.stdout)
  const expressions = Object.keys(inventory).sort()
  const reviewed = [...reviewedLicenseExpressions].sort()
  invariant(
    JSON.stringify(expressions) === JSON.stringify(reviewed),
    `Production license expressions changed; review required. Found: ${expressions.join(', ')}`
  )

  let packages = 0
  const packagesWithoutLicenseFiles = []
  const reviewedEvidence = new Set()
  const reviewedLicensePaths = new Set()
  invariant(
    productionPackageEvidence && typeof productionPackageEvidence === 'object',
    'Production package evidence is missing'
  )
  for (const [expression, entries] of Object.entries(inventory)) {
    invariant(Array.isArray(entries) && entries.length > 0, `${expression}: empty inventory group`)
    for (const entry of entries) {
      invariant(entry.name && entry.license, `${expression}: dependency metadata is incomplete`)
      invariant(entry.license === expression, `${entry.name}: grouped under the wrong license`)
      invariant(
        Array.isArray(entry.versions) && entry.versions.length > 0,
        `${entry.name}: no version`
      )
      packages += entry.versions.length

      for (const packagePath of entry.paths) {
        const metadata = JSON.parse(fs.readFileSync(path.join(packagePath, 'package.json'), 'utf8'))
        const identity = `${metadata.name}@${metadata.version}`
        const evidence = productionPackageEvidence[identity]
        const hasLicenseFile = fs
          .readdirSync(packagePath, { withFileTypes: true })
          .some((item) => item.isFile() && isRecognizedRootLicenseFileName(item.name))

        if (evidence) {
          invariant(
            !reviewedEvidence.has(identity),
            `${identity}: duplicate installed evidence root`
          )
          reviewedEvidence.add(identity)
          invariant(
            evidence.license === expression,
            `${identity}: reviewed license differs from inventory`
          )
          invariant(
            [
              'packaged-license-file',
              'packaged-readme-section',
              'pinned-upstream-license',
              'aikobox-owned-code',
              'excluded-from-application'
            ].includes(evidence.disposition),
            `${identity}: invalid evidence disposition`
          )
          invariant(
            Number.isSafeInteger(evidence.sourceSize) && evidence.sourceSize > 0,
            `${identity}: source evidence size is invalid`
          )
          invariant(
            /^[a-f0-9]{64}$/.test(evidence.sourceSha256),
            `${identity}: source evidence SHA-256 is invalid`
          )
          const sourcePath = resolveEvidenceFile(
            evidence.sourceFile,
            `${identity}: installed source evidence`,
            packagePath
          )
          const sourceContents = fs.readFileSync(sourcePath)
          invariant(
            sourceContents.length === evidence.sourceSize &&
              sha256(sourceContents) === evidence.sourceSha256,
            `${identity}: installed source evidence differs from review`
          )
          for (const required of [identity, evidence.sourceSha256]) {
            invariant(
              thirdPartyNotice.includes(required),
              `${identity}: ${required} is absent from third-party notice`
            )
          }

          if (evidence.disposition === 'pinned-upstream-license') {
            invariant(
              /^[a-f0-9]{40}$/.test(evidence.upstreamRevision),
              `${identity}: pinned upstream revision is invalid`
            )
            for (const [field, value] of [
              ['upstream source URL', evidence.upstreamSourceUrl],
              ['upstream license URL', evidence.upstreamLicenseUrl]
            ]) {
              invariant(
                typeof value === 'string' &&
                  value.startsWith('https://raw.githubusercontent.com/') &&
                  value.includes(`/${evidence.upstreamRevision}/`),
                `${identity}: ${field} is not pinned to the reviewed revision`
              )
            }
            invariant(
              evidence.upstreamSourceUrl.endsWith(`/${evidence.sourceFile}`),
              `${identity}: upstream source URL differs from installed evidence path`
            )
            invariant(
              /^[a-f0-9]{64}$/.test(evidence.upstreamLicenseSha256),
              `${identity}: upstream license SHA-256 is invalid`
            )
            for (const required of [
              evidence.upstreamRevision,
              evidence.upstreamSourceUrl,
              evidence.upstreamLicenseUrl,
              evidence.upstreamLicenseSha256
            ]) {
              invariant(
                thirdPartyNotice.includes(required),
                `${identity}: pinned upstream evidence is absent from third-party notice`
              )
            }
          }

          if (evidence.disposition === 'excluded-from-application') {
            invariant(
              evidence.licenseFile === undefined,
              `${identity}: excluded package has a license file`
            )
            invariant(
              typeof evidence.forbiddenAsarPath === 'string' &&
                /^\/node_modules\/(?:@[^/]+\/)?[^/]+$/.test(evidence.forbiddenAsarPath),
              `${identity}: forbidden app.asar path is invalid`
            )
            invariant(
              thirdPartyNotice.includes(evidence.forbiddenAsarPath),
              `${identity}: exclusion path is absent from third-party notice`
            )
          } else {
            const licenseFile = evidence.licenseFile
            invariant(
              licenseFile && typeof licenseFile === 'object',
              `${identity}: license file is missing`
            )
            invariant(
              !reviewedLicensePaths.has(licenseFile.path),
              `${identity}: duplicate reviewed license path`
            )
            reviewedLicensePaths.add(licenseFile.path)
            invariant(
              Number.isSafeInteger(licenseFile.size) && licenseFile.size > 0,
              `${identity}: packaged license size is invalid`
            )
            invariant(
              /^[a-f0-9]{64}$/.test(licenseFile.sha256),
              `${identity}: packaged license SHA-256 is invalid`
            )
            const packagedPath = resolveEvidenceFile(
              licenseFile.path,
              `${identity}: packaged license evidence`
            )
            const packagedContents = fs.readFileSync(packagedPath)
            const reviewedPackagedContents =
              evidence.disposition === 'aikobox-owned-code'
                ? canonicalLicenseText(packagedContents)
                : packagedContents
            invariant(
              reviewedPackagedContents.length === licenseFile.size &&
                sha256(reviewedPackagedContents) === licenseFile.sha256,
              `${identity}: packaged license differs from review`
            )
            if (evidence.disposition === 'pinned-upstream-license') {
              invariant(
                sha256(packagedContents) === evidence.upstreamLicenseSha256,
                `${identity}: packaged license differs from pinned upstream license`
              )
            } else if (evidence.disposition === 'aikobox-owned-code') {
              invariant(
                licenseFile.path === 'LICENSE' && evidence.license === 'GPL-3.0-only',
                `${identity}: AikoBox-owned code must use the packaged project GPL license`
              )
            } else {
              const reviewedContents =
                evidence.disposition === 'packaged-readme-section'
                  ? extractReviewedLicenseSection(
                      sourceContents,
                      evidence.sectionStart,
                      evidence.sectionEnd,
                      identity
                    )
                  : sourceContents
              invariant(
                reviewedContents.equals(packagedContents),
                `${identity}: packaged license differs from installed source evidence`
              )
            }
            for (const required of [licenseFile.path, licenseFile.sha256]) {
              invariant(
                thirdPartyNotice.includes(required),
                `${identity}: ${required} is absent from third-party notice`
              )
            }
          }
        } else if (!hasLicenseFile) {
          packagesWithoutLicenseFiles.push(identity)
        }
      }
    }
  }

  const expectedEvidence = Object.keys(productionPackageEvidence).sort()
  invariant(
    JSON.stringify([...reviewedEvidence].sort()) === JSON.stringify(expectedEvidence),
    `Reviewed production package evidence differs from the frozen install. Found: ${[...reviewedEvidence].sort().join(', ')}`
  )

  packagesWithoutLicenseFiles.sort()
  const expectedMissing = [...expectedPackagesWithoutLicenseFiles].sort()
  invariant(
    JSON.stringify(packagesWithoutLicenseFiles) === JSON.stringify(expectedMissing),
    `Production packages without reviewed license evidence changed; review required. Found: ${packagesWithoutLicenseFiles.join(', ')}`
  )

  return {
    expressions,
    packages,
    packagesWithoutLicenseFiles,
    reviewedEvidence: [...reviewedEvidence].sort()
  }
}

export function runAudit() {
  try {
    const resourceReview = inspectResourceReview()
    const production = inspectProductionDependencyMetadata(
      resourceReview.reviewedLicenseExpressions,
      resourceReview.expectedPackagesWithoutLicenseFiles,
      resourceReview.productionPackageEvidence,
      resourceReview.thirdPartyNotice
    )

    console.log(
      `[OK] ${production.packages} production dependency versions use reviewed license expressions: ${production.expressions.join(', ')}`
    )
    console.log(
      `[OK] ${production.reviewedEvidence.length} exact production package evidence records passed: ${production.reviewedEvidence.join(', ')}`
    )
    if (resourceReview.verifiedNativeEvidence.length > 0) {
      console.log(
        `[OK] Machine-verified native redistribution evidence passed: ${resourceReview.verifiedNativeEvidence.join(', ')}`
      )
    }

    if (production.packagesWithoutLicenseFiles.length > 0) {
      console.error(
        `[BLOCKED] Production packages without reviewed license evidence: ${production.packagesWithoutLicenseFiles.join(', ')}`
      )
    }

    if (resourceReview.blockers.length > 0) {
      console.error(
        `[BLOCKED] Runtime resource licensing is unresolved for: ${resourceReview.blockers.join(', ')}`
      )
    } else {
      console.log('[OK] Every locked runtime resource has verified redistribution evidence')
    }

    if (resourceReview.blockers.length > 0 || production.packagesWithoutLicenseFiles.length > 0) {
      process.exitCode = 1
    }
  } catch (error) {
    console.error(`[FATAL] License audit failed: ${error instanceof Error ? error.message : error}`)
    process.exitCode = 1
  }
}

const entrypoint = process.argv[1] && path.resolve(process.argv[1])
if (
  entrypoint &&
  comparableFsPath(entrypoint) === comparableFsPath(fileURLToPath(import.meta.url))
) {
  runAudit()
}
