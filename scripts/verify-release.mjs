import { createHash } from 'node:crypto'
import {
  createReadStream,
  existsSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  realpathSync,
  rmSync
} from 'node:fs'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { basename, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { spawnSync } from 'node:child_process'
import { extractFile, listPackage } from '@electron/asar'
import {
  assertAbsoluteChild,
  parseSevenZipTechnicalListing,
  selectPackagedApplication
} from './release-extraction.mjs'

const require = createRequire(import.meta.url)
const { getPath7za } = require('app-builder-lib/out/toolsets/7zip.js')

const projectRoot = resolve(import.meta.dirname, '..')
const distDir = resolve(projectRoot, 'dist')
const packageJson = JSON.parse(readFileSync(resolve(projectRoot, 'package.json'), 'utf8'))
const resourceLock = JSON.parse(
  readFileSync(resolve(projectRoot, 'scripts', 'resources-lock.json'), 'utf8')
)
const thirdPartyReview = JSON.parse(
  readFileSync(resolve(projectRoot, 'scripts', 'third-party-review.json'), 'utf8')
)
const releaseTag = process.env.AIKOBOX_RELEASE_TAG || process.env.GITHUB_REF_NAME
const expectedTag = `v${packageJson.version}`
const lockedSevenZip = {
  size: 849_920,
  sha256: '223b873c50380fe9a39f1a22b6abf8d46db506e1c08d08312902f6f3cd1f7ac3'
}

if (releaseTag && releaseTag !== expectedTag) {
  throw new Error(`Release tag ${releaseTag} does not match package version ${expectedTag}`)
}

const artifacts = [
  `aikobox-windows-${packageJson.version}-x64-setup.exe`,
  `aikobox-windows-${packageJson.version}-x64-portable.exe`
]
const expectedFiles = new Set([
  ...artifacts,
  ...artifacts.map((name) => `${name}.sha256`),
  'SHA256SUMS.txt'
])
const allowedReleaseLikeFiles = new Set([
  ...[...expectedFiles].filter((name) => /^aikobox-windows-/i.test(name)),
  `${artifacts[0]}.blockmap`
])

for (const name of expectedFiles) {
  if (!existsSync(resolve(distDir, name))) {
    throw new Error(`Missing release file: ${name}`)
  }
}

const releaseExecutables = readdirSync(distDir).filter((name) =>
  /^aikobox-windows-.*-(setup|portable)\.exe$/i.test(name)
)
const unexpectedReleaseLikeFiles = readdirSync(distDir).filter(
  (name) => /^aikobox-windows-/i.test(name) && !allowedReleaseLikeFiles.has(name)
)
if (unexpectedReleaseLikeFiles.length > 0) {
  throw new Error(
    `Unexpected stale Windows release output: ${unexpectedReleaseLikeFiles.join(', ')}`
  )
}
if (
  releaseExecutables.length !== artifacts.length ||
  releaseExecutables.some((name) => !artifacts.includes(name))
) {
  throw new Error(`Unexpected Windows release executables: ${releaseExecutables.join(', ')}`)
}

async function sha256(filePath) {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(filePath)) hash.update(chunk)
  return hash.digest('hex')
}

function sha256Buffer(buffer) {
  return createHash('sha256').update(buffer).digest('hex')
}

function boundedCommandOutput(output) {
  const text = String(output || '')
  return text.length > 16 * 1024 ? text.slice(-16 * 1024) : text
}

function runSevenZip(sevenZipPath, arguments_, label) {
  const result = spawnSync(sevenZipPath, arguments_, {
    encoding: 'utf8',
    maxBuffer: 64 * 1024 * 1024,
    shell: false,
    timeout: 120_000,
    windowsHide: true
  })
  if (result.error) throw new Error(`${label}: unable to run locked 7-Zip: ${result.error.message}`)
  if (result.status !== 0) {
    throw new Error(
      `${label}: locked 7-Zip exited with ${String(result.status)}\n${boundedCommandOutput(result.stdout)}\n${boundedCommandOutput(result.stderr)}`
    )
  }
  return result.stdout
}

function assertFile(filePath, expectedSize, expectedSha256, label) {
  if (!existsSync(filePath) || !lstatSync(filePath).isFile()) {
    throw new Error(`Missing packaged ${label}: ${filePath}`)
  }
  const contents = readFileSync(filePath)
  if (contents.length !== expectedSize || sha256Buffer(contents) !== expectedSha256) {
    throw new Error(`Packaged ${label} does not match the locked size and SHA-256`)
  }
}

function collectDirectoryFiles(root, directory = root) {
  const files = []
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolute = resolve(directory, entry.name)
    const stat = lstatSync(absolute)
    if (stat.isSymbolicLink()) throw new Error(`Packaged directory contains a link: ${absolute}`)
    if (entry.isDirectory()) files.push(...collectDirectoryFiles(root, absolute))
    else if (entry.isFile()) files.push(relative(root, absolute).split(sep).join('/'))
    else throw new Error(`Packaged directory contains a special file: ${absolute}`)
  }
  return files
}

function digestDirectory(directory) {
  const files = collectDirectoryFiles(directory).sort()
  const hash = createHash('sha256')
  let totalBytes = 0
  hash.update('AIKOBOX-DIR-SHA256-v1\0')
  for (const name of files) {
    const nameBuffer = Buffer.from(name, 'utf8')
    const contents = readFileSync(resolve(directory, ...name.split('/')))
    totalBytes += contents.length
    const lengths = Buffer.alloc(16)
    lengths.writeBigUInt64BE(BigInt(nameBuffer.length), 0)
    lengths.writeBigUInt64BE(BigInt(contents.length), 8)
    hash.update(lengths)
    hash.update(nameBuffer)
    hash.update(contents)
  }
  return { fileCount: files.length, totalBytes, sha256: hash.digest('hex') }
}

function assertAmd64Pe(filePath) {
  const contents = readFileSync(filePath)
  if (contents.length < 64 || contents.readUInt16LE(0) !== 0x5a4d) {
    throw new Error(`${basename(filePath)} is not a Windows PE executable`)
  }
  const peOffset = contents.readUInt32LE(0x3c)
  if (
    peOffset + 6 > contents.length ||
    contents.toString('ascii', peOffset, peOffset + 4) !== 'PE\0\0' ||
    contents.readUInt16LE(peOffset + 4) !== 0x8664
  ) {
    throw new Error(`${basename(filePath)} is not an AMD64 Windows executable`)
  }
}

function verifyAsarRepositoryFile(appAsar, archivePath, repositoryPath, label) {
  const packagedContents = extractFile(appAsar, archivePath.replaceAll('/', sep))
  const reviewedContents = readFileSync(resolve(projectRoot, ...repositoryPath.split('/')))
  if (
    sha256Buffer(packagedContents) !== sha256Buffer(reviewedContents) ||
    !packagedContents.equals(reviewedContents)
  ) {
    throw new Error(`${label}: app.asar ${archivePath} differs from ${repositoryPath}`)
  }
}

function verifyPackagedApplication(unpacked, label) {
  const resources = resolve(unpacked, 'resources')
  const appExecutable = resolve(unpacked, 'AikoBox.exe')
  const appAsar = resolve(resources, 'app.asar')
  assertAmd64Pe(appExecutable)
  if (!existsSync(appAsar)) throw new Error(`${label}: missing packaged app.asar`)
  for (const notice of ['LICENSE.electron.txt', 'LICENSES.chromium.html']) {
    const noticePath = resolve(unpacked, notice)
    if (!existsSync(noticePath) || !lstatSync(noticePath).isFile()) {
      throw new Error(`${label}: missing root Electron notice ${notice}`)
    }
  }
  if (existsSync(resolve(resources, 'files', '7za.exe'))) {
    throw new Error(`${label}: Retired 7za.exe must not be present in the packaged runtime`)
  }
  if (existsSync(resolve(resources, 'files', 'enableLoopback.exe'))) {
    throw new Error(
      `${label}: Retired enableLoopback.exe must not be present in the packaged runtime`
    )
  }
  if (existsSync(resolve(resources, 'files', 'TrafficMonitor'))) {
    throw new Error(`${label}: Retired TrafficMonitor must not be present in the packaged runtime`)
  }

  const asarEntries = listPackage(appAsar).map((entry) => entry.replaceAll('\\', '/'))
  const verifiedResourceLicenseFiles = Object.values(thirdPartyReview.resources).flatMap((item) =>
    item.status === 'verified' ? item.licenseFiles : (item.partialEvidence?.licenseFiles ?? [])
  )
  const productionPackageEvidence = Object.values(thirdPartyReview.productionPackageEvidence)
  const productionPackageLicenseFiles = productionPackageEvidence
    .map((item) => item.licenseFile)
    .filter(Boolean)
  const verifiedLicenseFiles = [...verifiedResourceLicenseFiles, ...productionPackageLicenseFiles]
  for (const evidence of productionPackageEvidence) {
    if (evidence.disposition !== 'excluded-from-application') continue
    const forbidden = evidence.forbiddenAsarPath
    if (asarEntries.some((entry) => entry === forbidden || entry.startsWith(`${forbidden}/`))) {
      throw new Error(`${label}: excluded production package entered app.asar: ${forbidden}`)
    }
    const unpackedForbidden = resolve(
      resources,
      'app.asar.unpacked',
      ...forbidden.slice(1).split('/')
    )
    if (existsSync(unpackedForbidden)) {
      throw new Error(
        `${label}: excluded production package entered app.asar.unpacked: ${forbidden}`
      )
    }
  }
  for (const required of [
    '/LICENSE',
    '/THIRD_PARTY_NOTICES.md',
    ...verifiedLicenseFiles.map((item) => `/${item.path}`)
  ]) {
    if (!asarEntries.includes(required))
      throw new Error(`${label}: app.asar is missing ${required}`)
  }

  verifyAsarRepositoryFile(appAsar, 'LICENSE', 'LICENSE', label)
  verifyAsarRepositoryFile(appAsar, 'THIRD_PARTY_NOTICES.md', 'THIRD_PARTY_NOTICES.md', label)

  for (const licenseFile of verifiedLicenseFiles) {
    const archivePath = licenseFile.path.replaceAll('/', sep)
    const packagedContents = extractFile(appAsar, archivePath)
    const reviewedContents = readFileSync(resolve(projectRoot, ...licenseFile.path.split('/')))
    if (
      sha256Buffer(packagedContents) !== licenseFile.sha256 ||
      !packagedContents.equals(reviewedContents)
    ) {
      throw new Error(`${label}: packaged license evidence does not match ${licenseFile.path}`)
    }
  }

  for (const [name, resource] of Object.entries(resourceLock.resources)) {
    if (resource.output.startsWith('extra/')) {
      const packaged = resolve(resources, ...resource.output.slice('extra/'.length).split('/'))
      if (resource.type === 'zip-directory') {
        if (!existsSync(packaged) || !lstatSync(packaged).isDirectory()) {
          throw new Error(`${label}: missing packaged ${name} directory`)
        }
        const digest = digestDirectory(packaged)
        if (digest.fileCount !== resource.fileCount || digest.sha256 !== resource.directorySha256) {
          throw new Error(`${label}: packaged ${name} directory does not match its resource lock`)
        }
      } else {
        assertFile(packaged, resource.size, resource.sha256, name)
      }
      continue
    }

    if (name === 'notoColorEmoji') {
      const matches = asarEntries.filter(
        (entry) =>
          entry.startsWith('/out/renderer/assets/NotoColorEmoji-') && entry.endsWith('.ttf')
      )
      if (matches.length !== 1) {
        throw new Error(
          `${label}: expected exactly one packaged Noto Color Emoji font, found ${matches.length}`
        )
      }
      const archivePath = matches[0].slice(1).replaceAll('/', sep)
      const contents = extractFile(appAsar, archivePath)
      if (contents.length !== resource.size || sha256Buffer(contents) !== resource.sha256) {
        throw new Error(`${label}: packaged Noto Color Emoji does not match its resource lock`)
      }
      continue
    }

    throw new Error(`${label}: release verifier does not map locked resource ${name}`)
  }

  return {
    appAsarSha256: sha256Buffer(readFileSync(appAsar)),
    treeDigest: digestDirectory(unpacked)
  }
}

function assertSameApplicationTree(actual, expected, label) {
  if (
    actual.fileCount !== expected.fileCount ||
    actual.totalBytes !== expected.totalBytes ||
    actual.sha256 !== expected.sha256
  ) {
    throw new Error(`${label}: extracted application tree differs from dist/win-unpacked`)
  }
}

function collectExtractedEntries(root, directory = root) {
  const entries = []
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolutePath = assertAbsoluteChild(root, resolve(directory, entry.name), 'extracted path')
    const stat = lstatSync(absolutePath)
    if (stat.isSymbolicLink())
      throw new Error(`Extracted artifact contains a link: ${absolutePath}`)
    const relativePath = relative(root, absolutePath).split(sep).join('/')
    entries.push(relativePath)
    if (entry.isDirectory()) entries.push(...collectExtractedEntries(root, absolutePath))
    else if (!entry.isFile()) {
      throw new Error(`Extracted artifact contains a special file: ${absolutePath}`)
    }
  }
  return entries
}

function resolveTemporaryBase() {
  const configured = process.env.RUNNER_TEMP || tmpdir()
  if (!isAbsolute(configured)) throw new Error('Release verification temp base must be absolute')
  const base = realpathSync(configured)
  if (!lstatSync(base).isDirectory())
    throw new Error('Release verification temp base is not a directory')
  return base
}

function removeExtractionDirectory(temporaryBase, extractionDirectory) {
  const safeDirectory = assertAbsoluteChild(
    temporaryBase,
    extractionDirectory,
    'release extraction directory'
  )
  rmSync(safeDirectory, { force: true, maxRetries: 3, recursive: true, retryDelay: 100 })
}

function extractAndVerifyFinalArtifact(sevenZipPath, artifactPath, expectedApplication) {
  const absoluteArtifact = assertAbsoluteChild(distDir, artifactPath, 'release artifact')
  const label = basename(absoluteArtifact)
  const listing = runSevenZip(
    sevenZipPath,
    ['l', '-slt', '-sccUTF-8', '--', absoluteArtifact],
    `${label} listing`
  )
  const listedEntries = parseSevenZipTechnicalListing(listing)
  const listedApplication = selectPackagedApplication(listedEntries)

  const temporaryBase = resolveTemporaryBase()
  const extractionDirectory = mkdtempSync(join(temporaryBase, 'aikobox-release-verify-'))
  assertAbsoluteChild(temporaryBase, extractionDirectory, 'release extraction directory')
  try {
    runSevenZip(
      sevenZipPath,
      ['x', '-y', '-bd', '-bb0', '-sccUTF-8', `-o${extractionDirectory}`, '--', absoluteArtifact],
      `${label} extraction`
    )
    const extractedEntries = collectExtractedEntries(extractionDirectory)
    const extractedApplication = selectPackagedApplication(extractedEntries)
    if (
      extractedApplication.appAsar.toLocaleLowerCase('en-US') !==
      listedApplication.appAsar.toLocaleLowerCase('en-US')
    ) {
      throw new Error(`${label}: extracted application path differs from its archive listing`)
    }
    const unpacked = extractedApplication.appRoot
      ? assertAbsoluteChild(
          extractionDirectory,
          resolve(extractionDirectory, ...extractedApplication.appRoot.split('/')),
          `${label} application root`
        )
      : extractionDirectory
    const result = verifyPackagedApplication(unpacked, label)
    if (result.appAsarSha256 !== expectedApplication.appAsarSha256) {
      throw new Error(`${label}: embedded app.asar differs from dist/win-unpacked`)
    }
    assertSameApplicationTree(result.treeDigest, expectedApplication.treeDigest, label)
    return result
  } finally {
    removeExtractionDirectory(temporaryBase, extractionDirectory)
  }
}

async function resolveLockedSevenZip() {
  if (process.env.ELECTRON_BUILDER_7ZIP_PATH !== undefined) {
    throw new Error(
      'ELECTRON_BUILDER_7ZIP_PATH overrides are forbidden during release verification'
    )
  }
  if (process.platform !== 'win32' || process.arch !== 'x64') {
    throw new Error('Final Windows artifact extraction requires a Windows x64 verifier')
  }
  const sevenZipPath = await getPath7za()
  if (!isAbsolute(sevenZipPath)) throw new Error('electron-builder returned a relative 7-Zip path')
  assertFile(sevenZipPath, lockedSevenZip.size, lockedSevenZip.sha256, 'electron-builder 7-Zip')
  return sevenZipPath
}

const expectedLines = []
for (const artifact of artifacts) {
  const digest = await sha256(resolve(distDir, artifact))
  const line = `${digest}  ${artifact}`
  const sidecar = readFileSync(resolve(distDir, `${artifact}.sha256`), 'utf8').trim()
  if (sidecar !== line) {
    throw new Error(`Checksum sidecar does not match ${artifact}`)
  }
  expectedLines.push(line)
}

const aggregate = readFileSync(resolve(distDir, 'SHA256SUMS.txt'), 'utf8').trim().split(/\r?\n/)
if (
  aggregate.length !== expectedLines.length ||
  aggregate.some((line, i) => line !== expectedLines[i])
) {
  throw new Error('SHA256SUMS.txt does not exactly match the two release artifacts')
}

const unpackedResult = verifyPackagedApplication(
  resolve(distDir, 'win-unpacked'),
  'dist/win-unpacked'
)
const sevenZipPath = await resolveLockedSevenZip()
for (const artifact of artifacts) {
  extractAndVerifyFinalArtifact(sevenZipPath, resolve(distDir, artifact), unpackedResult)
}

console.log(
  `Verified ${artifacts.length} immutable Windows artifacts, each independently extracted AMD64 app, dist/win-unpacked, and all locked packaged resources for ${expectedTag}.`
)
