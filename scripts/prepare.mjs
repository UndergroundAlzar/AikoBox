import crypto from 'crypto'
import fs from 'fs'
import path from 'path'
import { fileURLToPath } from 'url'
import AdmZip from 'adm-zip'

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url))
const REPOSITORY_ROOT = path.resolve(SCRIPT_DIR, '..')
const TEMP_DIR = path.join(REPOSITORY_ROOT, 'node_modules', '.temp')
const LOCK_PATH = path.join(SCRIPT_DIR, 'resources-lock.json')
const SHA256_PATTERN = /^[a-f0-9]{64}$/
const EXPECTED_RESOURCES = ['notoColorEmoji', 'singBox', 'sysproxy']
const RETIRED_RESOURCE_OUTPUTS = [
  'extra/files/7za.exe',
  'extra/files/enableLoopback.exe',
  'extra/files/TrafficMonitor',
  'extra/files/sub-store.bundle.cjs',
  'extra/files/sub-store-frontend'
]
const cliArguments = new Set(process.argv.slice(2))
const unknownArguments = [...cliArguments].filter(
  (argument) => !['--offline', '--verify-only', '--x64'].includes(argument)
)

if (unknownArguments.length > 0) {
  throw new Error(`Unsupported prepare argument(s): ${unknownArguments.join(', ')}`)
}

const requestedArch = cliArguments.has('--x64') ? 'x64' : process.arch
const VERIFY_ONLY = cliArguments.has('--verify-only')
const OFFLINE =
  VERIFY_ONLY || cliArguments.has('--offline') || process.env.AIKOBOX_PREPARE_OFFLINE === '1'

if (process.platform !== 'win32' || requestedArch !== 'x64') {
  throw new Error(
    `AikoBox resources are locked for Windows x64 only (received ${process.platform}-${requestedArch})`
  )
}

function invariant(condition, message) {
  if (!condition) throw new Error(message)
}

function isPathWithin(candidate, parent) {
  const relative = path.relative(path.resolve(parent), path.resolve(candidate))
  return relative !== '' && !relative.startsWith('..') && !path.isAbsolute(relative)
}

function resolveRepositoryPath(relativePath, label) {
  invariant(typeof relativePath === 'string' && relativePath.length > 0, `${label} is missing`)
  invariant(!path.isAbsolute(relativePath), `${label} must be repository-relative`)
  invariant(!relativePath.includes('\0'), `${label} contains a NUL byte`)

  const resolved = path.resolve(REPOSITORY_ROOT, relativePath)
  invariant(isPathWithin(resolved, REPOSITORY_ROOT), `${label} escapes the repository root`)
  return resolved
}

function resolveCachePath(relativePath, label) {
  invariant(typeof relativePath === 'string' && relativePath.length > 0, `${label} is missing`)
  invariant(!path.isAbsolute(relativePath), `${label} must be relative`)
  invariant(!relativePath.includes('\0'), `${label} contains a NUL byte`)

  const resolved = path.resolve(TEMP_DIR, relativePath)
  invariant(isPathWithin(resolved, TEMP_DIR), `${label} escapes the resource cache`)
  return resolved
}

function assertSha256(value, label) {
  invariant(typeof value === 'string' && SHA256_PATTERN.test(value), `${label} is not SHA-256`)
}

function validateDownloadUrl(value, label, allowMutableLocator = false) {
  invariant(typeof value === 'string' && value.length > 0, `${label} is missing`)
  const parsed = new URL(value)
  invariant(parsed.protocol === 'https:', `${label} must use HTTPS`)
  invariant(!parsed.username && !parsed.password, `${label} must not include credentials`)
  invariant(!parsed.hash, `${label} must not include a fragment`)
  const usesMutableLocator = /(^|\/)latest(\/|$)|(^|\/)(main|master)(\/|$)/i.test(parsed.pathname)
  invariant(
    allowMutableLocator || !usesMutableLocator,
    `${label} uses a mutable release or branch alias`
  )
}

function loadResourceLock() {
  const lock = JSON.parse(fs.readFileSync(LOCK_PATH, 'utf8'))
  invariant(lock.schemaVersion === 1, 'Unsupported resources lock schema')
  invariant(lock.target === 'win32-x64', 'Resource lock target must be win32-x64')
  invariant(lock.resources && typeof lock.resources === 'object', 'Resource lock is empty')

  const resourceNames = Object.keys(lock.resources).sort()
  invariant(
    JSON.stringify(resourceNames) === JSON.stringify(EXPECTED_RESOURCES),
    'Resource lock must contain exactly the expected Windows runtime resources'
  )

  for (const [name, resource] of Object.entries(lock.resources)) {
    invariant(
      typeof resource.version === 'string' && resource.version.trim().length > 0,
      `${name}.version is missing`
    )
    invariant(
      !/\blatest\b|\bmain\b|\bmaster\b/i.test(resource.version),
      `${name}.version is not immutable`
    )
    resolveRepositoryPath(resource.output, `${name}.output`)

    switch (resource.type) {
      case 'file':
        validateDownloadUrl(
          resource.downloadUrl,
          `${name}.downloadUrl`,
          resource.allowMutableLocator === true
        )
        if (resource.allowMutableLocator === true) {
          invariant(
            typeof resource.sourceCommit === 'string' &&
              /^[a-f0-9]{40}$/.test(resource.sourceCommit),
            `${name}.sourceCommit must pin the reviewed release commit`
          )
        }
        resolveCachePath(resource.cacheFile, `${name}.cacheFile`)
        assertSha256(resource.sha256, `${name}.sha256`)
        invariant(
          Number.isSafeInteger(resource.size) && resource.size > 0,
          `${name}.size is invalid`
        )
        break
      case 'manual-file':
        invariant(!resource.downloadUrl, `${name} must not have an automatic download URL`)
        invariant(
          typeof resource.disabledReason === 'string' && resource.disabledReason.length > 0,
          `${name}.disabledReason is missing`
        )
        assertSha256(resource.sha256, `${name}.sha256`)
        invariant(
          Number.isSafeInteger(resource.size) && resource.size > 0,
          `${name}.size is invalid`
        )
        break
      case 'local-file':
        resolveRepositoryPath(resource.source, `${name}.source`)
        assertSha256(resource.sha256, `${name}.sha256`)
        invariant(
          Number.isSafeInteger(resource.size) && resource.size > 0,
          `${name}.size is invalid`
        )
        break
      case 'zip-entry':
        validateDownloadUrl(resource.downloadUrl, `${name}.downloadUrl`)
        resolveCachePath(resource.cacheFile, `${name}.cacheFile`)
        invariant(
          typeof resource.archiveEntry === 'string' && resource.archiveEntry.length > 0,
          `${name}.archiveEntry is missing`
        )
        invariant(
          Number.isSafeInteger(resource.maxArchiveSize) && resource.maxArchiveSize > 0,
          `${name}.maxArchiveSize is invalid`
        )
        assertSha256(resource.archiveSha256, `${name}.archiveSha256`)
        invariant(
          Number.isSafeInteger(resource.archiveSize) &&
            resource.archiveSize > 0 &&
            resource.archiveSize <= resource.maxArchiveSize,
          `${name}.archiveSize is invalid`
        )
        assertSha256(resource.sha256, `${name}.sha256`)
        invariant(
          Number.isSafeInteger(resource.size) && resource.size > 0,
          `${name}.size is invalid`
        )
        break
      case 'zip-directory':
        validateDownloadUrl(resource.downloadUrl, `${name}.downloadUrl`)
        resolveCachePath(resource.cacheFile, `${name}.cacheFile`)
        assertSha256(resource.archiveSha256, `${name}.archiveSha256`)
        assertSha256(resource.directorySha256, `${name}.directorySha256`)
        invariant(
          Number.isSafeInteger(resource.archiveSize) && resource.archiveSize > 0,
          `${name}.archiveSize is invalid`
        )
        invariant(
          Number.isSafeInteger(resource.fileCount) && resource.fileCount > 0,
          `${name}.fileCount is invalid`
        )
        invariant(typeof resource.archiveRoot === 'string', `${name}.archiveRoot is invalid`)
        break
      default:
        throw new Error(`${name}.type is unsupported`)
    }
  }

  return lock.resources
}

function sha256Buffer(buffer) {
  return crypto.createHash('sha256').update(buffer).digest('hex')
}

function sha256File(filePath) {
  const hash = crypto.createHash('sha256')
  const file = fs.openSync(filePath, 'r')
  const buffer = Buffer.allocUnsafe(1024 * 1024)

  try {
    let bytesRead
    do {
      bytesRead = fs.readSync(file, buffer, 0, buffer.length, null)
      if (bytesRead > 0) hash.update(buffer.subarray(0, bytesRead))
    } while (bytesRead > 0)
  } finally {
    fs.closeSync(file)
  }

  return hash.digest('hex')
}

function inspectFile(filePath, expectedSize, expectedSha256) {
  if (!fs.existsSync(filePath)) return { ok: false, reason: 'missing' }

  const stat = fs.lstatSync(filePath)
  if (!stat.isFile()) return { ok: false, reason: 'not a regular file' }
  if (stat.size !== expectedSize) {
    return { ok: false, reason: `size ${stat.size}, expected ${expectedSize}` }
  }

  const actualSha256 = sha256File(filePath)
  if (actualSha256 !== expectedSha256) {
    return { ok: false, reason: `SHA-256 ${actualSha256}, expected ${expectedSha256}` }
  }

  return { ok: true }
}

function collectDirectoryFiles(root, relativeDirectory = '') {
  const directory = path.join(root, relativeDirectory)
  const entries = fs.readdirSync(directory, { withFileTypes: true })
  const files = []

  for (const entry of entries) {
    const relativePath = relativeDirectory ? `${relativeDirectory}/${entry.name}` : entry.name
    const absolutePath = path.join(directory, entry.name)
    const stat = fs.lstatSync(absolutePath)

    if (stat.isSymbolicLink()) {
      throw new Error(`Directory contains a symbolic link: ${relativePath}`)
    }
    if (stat.isDirectory()) {
      files.push(...collectDirectoryFiles(root, relativePath))
    } else if (stat.isFile()) {
      files.push(relativePath)
    } else {
      throw new Error(`Directory contains a special file: ${relativePath}`)
    }
  }

  return files
}

function digestDirectory(directory) {
  const files = collectDirectoryFiles(directory).sort()
  const hash = crypto.createHash('sha256')
  hash.update('AIKOBOX-DIR-SHA256-v1\0')

  for (const relativePath of files) {
    const pathBuffer = Buffer.from(relativePath, 'utf8')
    const contents = fs.readFileSync(path.join(directory, ...relativePath.split('/')))
    const lengths = Buffer.alloc(16)
    lengths.writeBigUInt64BE(BigInt(pathBuffer.length), 0)
    lengths.writeBigUInt64BE(BigInt(contents.length), 8)
    hash.update(lengths)
    hash.update(pathBuffer)
    hash.update(contents)
  }

  return { fileCount: files.length, sha256: hash.digest('hex') }
}

function inspectDirectory(directory, expectedFileCount, expectedSha256) {
  if (!fs.existsSync(directory)) return { ok: false, reason: 'missing' }
  if (!fs.lstatSync(directory).isDirectory()) {
    return { ok: false, reason: 'not a regular directory' }
  }

  try {
    const actual = digestDirectory(directory)
    if (actual.fileCount !== expectedFileCount) {
      return {
        ok: false,
        reason: `file count ${actual.fileCount}, expected ${expectedFileCount}`
      }
    }
    if (actual.sha256 !== expectedSha256) {
      return {
        ok: false,
        reason: `directory SHA-256 ${actual.sha256}, expected ${expectedSha256}`
      }
    }
    return { ok: true }
  } catch (error) {
    return { ok: false, reason: error instanceof Error ? error.message : String(error) }
  }
}

function safeRemove(targetPath, allowedParent) {
  invariant(
    isPathWithin(targetPath, allowedParent),
    `Refusing to remove unsafe path: ${targetPath}`
  )
  fs.rmSync(targetPath, { recursive: true, force: true })
}

function uniqueSibling(targetPath, suffix) {
  return `${targetPath}.${suffix}-${process.pid}-${crypto.randomBytes(8).toString('hex')}`
}

function replaceFileAtomically(stagedPath, targetPath, allowedParent) {
  invariant(isPathWithin(stagedPath, allowedParent), `Unsafe staged file path: ${stagedPath}`)
  invariant(isPathWithin(targetPath, allowedParent), `Unsafe target file path: ${targetPath}`)
  const backupPath = uniqueSibling(targetPath, 'backup')
  const hadTarget = fs.existsSync(targetPath)

  try {
    if (hadTarget) fs.renameSync(targetPath, backupPath)
    fs.renameSync(stagedPath, targetPath)
    if (hadTarget) safeRemove(backupPath, allowedParent)
  } catch (error) {
    if (fs.existsSync(targetPath)) safeRemove(targetPath, allowedParent)
    if (hadTarget && fs.existsSync(backupPath)) fs.renameSync(backupPath, targetPath)
    throw error
  }
}

function replaceDirectoryAtomically(stagedPath, targetPath, allowedParent) {
  replaceFileAtomically(stagedPath, targetPath, allowedParent)
}

function normalizeZipEntry(entryName) {
  invariant(
    typeof entryName === 'string' && !entryName.includes('\0'),
    'ZIP entry has an invalid name'
  )
  const normalized = entryName.replaceAll('\\', '/').replace(/^\.\//, '')
  invariant(!normalized.startsWith('/'), `ZIP entry is absolute: ${entryName}`)
  invariant(!/^[a-z]:/i.test(normalized), `ZIP entry has a drive prefix: ${entryName}`)

  const segments = normalized.split('/').filter((segment) => segment !== '' && segment !== '.')
  invariant(!segments.includes('..'), `ZIP entry escapes its destination: ${entryName}`)
  return segments.join('/')
}

function validateArchiveEntryNames(zip) {
  let totalUncompressedSize = 0
  const names = new Set()

  for (const entry of zip.getEntries()) {
    const normalized = normalizeZipEntry(entry.entryName)
    invariant(normalized.length > 0 || entry.isDirectory, 'ZIP contains an unnamed file')
    invariant(!names.has(normalized), `ZIP contains a duplicate entry: ${normalized}`)
    names.add(normalized)

    if (!entry.isDirectory) {
      invariant(
        Number.isSafeInteger(entry.header.size),
        `ZIP entry has an invalid size: ${normalized}`
      )
      totalUncompressedSize += entry.header.size
      invariant(
        Number.isSafeInteger(totalUncompressedSize) && totalUncompressedSize <= 512 * 1024 * 1024,
        'ZIP uncompressed contents exceed the safety limit'
      )
    }
  }
}

function readVerifiedZipPayload(archivePath, resource) {
  const stat = fs.lstatSync(archivePath)
  invariant(stat.isFile(), 'sing-box archive is not a regular file')
  invariant(
    stat.size > 0 && stat.size <= resource.maxArchiveSize,
    'sing-box archive size is unsafe'
  )

  const zip = new AdmZip(archivePath)
  validateArchiveEntryNames(zip)
  const expectedEntry = normalizeZipEntry(resource.archiveEntry)
  const matches = zip
    .getEntries()
    .filter((entry) => !entry.isDirectory && normalizeZipEntry(entry.entryName) === expectedEntry)
  invariant(matches.length === 1, `sing-box archive must contain exactly one ${expectedEntry}`)
  invariant(matches[0].header.size === resource.size, 'sing-box archive payload size is incorrect')

  const payload = matches[0].getData()
  invariant(payload.length === resource.size, 'sing-box decompressed payload size is incorrect')
  invariant(sha256Buffer(payload) === resource.sha256, 'sing-box payload SHA-256 mismatch')
  return payload
}

function extractVerifiedZipDirectory(archivePath, destination, archiveRoot) {
  const zip = new AdmZip(archivePath)
  validateArchiveEntryNames(zip)
  const normalizedRoot = normalizeZipEntry(archiveRoot)
  const rootPrefix = normalizedRoot ? `${normalizedRoot}/` : ''

  fs.mkdirSync(destination, { recursive: true })

  for (const entry of zip.getEntries()) {
    const normalized = normalizeZipEntry(entry.entryName)
    let relativePath = normalized

    if (normalizedRoot) {
      if (normalized === normalizedRoot && entry.isDirectory) continue
      invariant(
        normalized.startsWith(rootPrefix),
        `ZIP entry is outside ${normalizedRoot}: ${normalized}`
      )
      relativePath = normalized.slice(rootPrefix.length)
    }

    if (!relativePath) continue
    const outputPath = path.resolve(destination, ...relativePath.split('/'))
    invariant(isPathWithin(outputPath, destination), `ZIP entry escapes destination: ${normalized}`)

    if (entry.isDirectory) {
      fs.mkdirSync(outputPath, { recursive: true })
      continue
    }

    fs.mkdirSync(path.dirname(outputPath), { recursive: true })
    fs.writeFileSync(outputPath, entry.getData(), { flag: 'wx' })
  }
}

async function fetchToFile(
  downloadUrl,
  destination,
  expectedSize,
  maximumSize = expectedSize,
  allowMutableLocator = false
) {
  if (OFFLINE) {
    throw new Error(`Network access is disabled; verified resource is unavailable: ${downloadUrl}`)
  }

  validateDownloadUrl(downloadUrl, 'download URL', allowMutableLocator)
  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 60_000)
  let file

  try {
    const response = await fetch(downloadUrl, {
      headers: {
        Accept: 'application/octet-stream',
        'User-Agent': 'AikoBox-resource-prepare/1'
      },
      redirect: 'follow',
      signal: controller.signal
    })

    invariant(response.ok, `Download failed: HTTP ${response.status} ${response.statusText}`)
    invariant(new URL(response.url).protocol === 'https:', 'Download redirected away from HTTPS')
    invariant(response.body, 'Download response has no body')

    const contentLengthHeader = response.headers.get('content-length')
    if (contentLengthHeader) {
      const contentLength = Number(contentLengthHeader)
      invariant(Number.isSafeInteger(contentLength) && contentLength >= 0, 'Invalid Content-Length')
      if (expectedSize !== undefined) {
        invariant(
          contentLength === expectedSize,
          `Content-Length ${contentLength} != ${expectedSize}`
        )
      }
      invariant(contentLength <= maximumSize, 'Download exceeds the size limit')
    }

    fs.mkdirSync(path.dirname(destination), { recursive: true })
    file = fs.openSync(destination, 'wx')
    const reader = response.body.getReader()
    let downloaded = 0

    while (true) {
      const { done, value } = await reader.read()
      if (done) break
      downloaded += value.byteLength
      invariant(downloaded <= maximumSize, 'Download exceeds the size limit')
      fs.writeSync(file, value)
    }

    if (expectedSize !== undefined) {
      invariant(downloaded === expectedSize, `Downloaded size ${downloaded} != ${expectedSize}`)
    }
  } catch (error) {
    if (file !== undefined) {
      fs.closeSync(file)
      file = undefined
    }
    if (fs.existsSync(destination)) safeRemove(destination, TEMP_DIR)
    throw error
  } finally {
    clearTimeout(timeout)
    if (file !== undefined) fs.closeSync(file)
  }
}

async function obtainVerifiedCache(name, resource, validator, expectedSize, maximumSize) {
  const cachePath = resolveCachePath(resource.cacheFile, `${name}.cacheFile`)

  if (fs.existsSync(cachePath)) {
    try {
      validator(cachePath)
      console.log(`[INFO] ${name}: verified cached download`)
      return cachePath
    } catch (error) {
      console.warn(
        `[WARN] ${name}: rejecting cached download (${error instanceof Error ? error.message : error})`
      )
      if (VERIFY_ONLY) throw error
      safeRemove(cachePath, TEMP_DIR)
    }
  }

  let lastError
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    const partialPath = uniqueSibling(cachePath, 'part')
    try {
      await fetchToFile(
        resource.downloadUrl,
        partialPath,
        expectedSize,
        maximumSize,
        resource.allowMutableLocator === true
      )
      validator(partialPath)
      fs.mkdirSync(path.dirname(cachePath), { recursive: true })
      replaceFileAtomically(partialPath, cachePath, TEMP_DIR)
      console.log(`[INFO] ${name}: downloaded and verified ${resource.version}`)
      return cachePath
    } catch (error) {
      lastError = error
      if (fs.existsSync(partialPath)) safeRemove(partialPath, TEMP_DIR)
      console.error(
        `[ERROR] ${name}: verified download attempt ${attempt}/3 failed: ${
          error instanceof Error ? error.message : error
        }`
      )
      if (OFFLINE) break
    }
  }

  throw lastError ?? new Error(`${name}: unable to obtain a verified download`)
}

function installVerifiedFile(name, sourcePath, targetPath, resource) {
  const targetParent = path.dirname(targetPath)
  fs.mkdirSync(targetParent, { recursive: true })
  const stagedPath = uniqueSibling(targetPath, 'staging')

  try {
    fs.copyFileSync(sourcePath, stagedPath, fs.constants.COPYFILE_EXCL)
    const staged = inspectFile(stagedPath, resource.size, resource.sha256)
    invariant(staged.ok, `${name}: staged file failed verification (${staged.reason})`)
    replaceFileAtomically(stagedPath, targetPath, targetParent)
    const installed = inspectFile(targetPath, resource.size, resource.sha256)
    invariant(installed.ok, `${name}: installed file failed verification (${installed.reason})`)
  } finally {
    if (fs.existsSync(stagedPath)) safeRemove(stagedPath, targetParent)
  }
}

async function ensureDownloadedFile(name, resource) {
  const targetPath = resolveRepositoryPath(resource.output, `${name}.output`)
  const current = inspectFile(targetPath, resource.size, resource.sha256)
  if (current.ok) {
    console.log(`[INFO] ${name}: verified installed ${resource.version}`)
    return
  }
  if (VERIFY_ONLY) throw new Error(`${name}: installed resource is ${current.reason}`)

  const validator = (filePath) => {
    const result = inspectFile(filePath, resource.size, resource.sha256)
    invariant(result.ok, `${name}: ${result.reason}`)
  }
  const cachePath = await obtainVerifiedCache(
    name,
    resource,
    validator,
    resource.size,
    resource.size
  )
  installVerifiedFile(name, cachePath, targetPath, resource)
}

async function ensureManualFile(name, resource) {
  const targetPath = resolveRepositoryPath(resource.output, `${name}.output`)
  const current = inspectFile(targetPath, resource.size, resource.sha256)
  if (!current.ok) {
    throw new Error(
      `${name}: installed resource is ${current.reason}. Automatic download is disabled: ${resource.disabledReason} ` +
        `Supply the reviewed ${resource.version} artifact at ${resource.output} with SHA-256 ${resource.sha256}.`
    )
  }
  console.log(`[INFO] ${name}: verified manually supplied ${resource.version}`)
}

async function ensureLocalFile(name, resource) {
  const sourcePath = resolveRepositoryPath(resource.source, `${name}.source`)
  const source = inspectFile(sourcePath, resource.size, resource.sha256)
  invariant(source.ok, `${name}: pinned local source is ${source.reason}`)

  const targetPath = resolveRepositoryPath(resource.output, `${name}.output`)
  const current = inspectFile(targetPath, resource.size, resource.sha256)
  if (current.ok) {
    console.log(`[INFO] ${name}: verified installed ${resource.version}`)
    return
  }
  if (VERIFY_ONLY) throw new Error(`${name}: installed resource is ${current.reason}`)

  installVerifiedFile(name, sourcePath, targetPath, resource)
  console.log(`[INFO] ${name}: installed verified local dependency ${resource.version}`)
}

async function ensureZipEntry(name, resource) {
  const targetPath = resolveRepositoryPath(resource.output, `${name}.output`)
  const current = inspectFile(targetPath, resource.size, resource.sha256)
  if (current.ok) {
    console.log(`[INFO] ${name}: verified installed ${resource.version}`)
    return
  }
  if (VERIFY_ONLY) throw new Error(`${name}: installed resource is ${current.reason}`)

  let verifiedPayload
  const validator = (archivePath) => {
    const archive = inspectFile(archivePath, resource.archiveSize, resource.archiveSha256)
    invariant(archive.ok, `${name}: archive ${archive.reason}`)
    verifiedPayload = readVerifiedZipPayload(archivePath, resource)
  }
  await obtainVerifiedCache(
    name,
    resource,
    validator,
    resource.archiveSize,
    resource.maxArchiveSize
  )
  invariant(verifiedPayload, `${name}: verified archive payload is unavailable`)

  const targetParent = path.dirname(targetPath)
  fs.mkdirSync(targetParent, { recursive: true })
  const stagedPath = uniqueSibling(targetPath, 'staging')

  try {
    fs.writeFileSync(stagedPath, verifiedPayload, { flag: 'wx' })
    const staged = inspectFile(stagedPath, resource.size, resource.sha256)
    invariant(staged.ok, `${name}: staged payload failed verification (${staged.reason})`)
    replaceFileAtomically(stagedPath, targetPath, targetParent)
    const installed = inspectFile(targetPath, resource.size, resource.sha256)
    invariant(installed.ok, `${name}: installed payload failed verification (${installed.reason})`)
  } finally {
    if (fs.existsSync(stagedPath)) safeRemove(stagedPath, targetParent)
  }
}

async function ensureZipDirectory(name, resource) {
  const targetPath = resolveRepositoryPath(resource.output, `${name}.output`)
  const current = inspectDirectory(targetPath, resource.fileCount, resource.directorySha256)
  if (current.ok) {
    console.log(`[INFO] ${name}: verified installed ${resource.version}`)
    return
  }
  if (VERIFY_ONLY) throw new Error(`${name}: installed resource is ${current.reason}`)

  const validator = (archivePath) => {
    const archive = inspectFile(archivePath, resource.archiveSize, resource.archiveSha256)
    invariant(archive.ok, `${name}: archive ${archive.reason}`)
  }
  const cachePath = await obtainVerifiedCache(
    name,
    resource,
    validator,
    resource.archiveSize,
    resource.archiveSize
  )

  const targetParent = path.dirname(targetPath)
  fs.mkdirSync(targetParent, { recursive: true })
  const stagedPath = uniqueSibling(targetPath, 'staging')

  try {
    extractVerifiedZipDirectory(cachePath, stagedPath, resource.archiveRoot)
    const staged = inspectDirectory(stagedPath, resource.fileCount, resource.directorySha256)
    invariant(staged.ok, `${name}: extracted directory failed verification (${staged.reason})`)
    replaceDirectoryAtomically(stagedPath, targetPath, targetParent)
    const installed = inspectDirectory(targetPath, resource.fileCount, resource.directorySha256)
    invariant(
      installed.ok,
      `${name}: installed directory failed verification (${installed.reason})`
    )
  } finally {
    if (fs.existsSync(stagedPath)) safeRemove(stagedPath, targetParent)
  }
}

async function ensureResource(name, resource) {
  switch (resource.type) {
    case 'file':
      return ensureDownloadedFile(name, resource)
    case 'manual-file':
      return ensureManualFile(name, resource)
    case 'local-file':
      return ensureLocalFile(name, resource)
    case 'zip-entry':
      return ensureZipEntry(name, resource)
    case 'zip-directory':
      return ensureZipDirectory(name, resource)
    default:
      throw new Error(`${name}: unsupported resource type ${resource.type}`)
  }
}

async function main() {
  const resources = loadResourceLock()
  for (const retiredOutput of RETIRED_RESOURCE_OUTPUTS) {
    const retiredPath = resolveRepositoryPath(retiredOutput, 'retired resource output')
    if (!fs.existsSync(retiredPath)) continue
    if (VERIFY_ONLY) {
      throw new Error(`Retired runtime resource is still installed: ${retiredOutput}`)
    }
    fs.rmSync(retiredPath, { force: true, recursive: true })
    console.log(`[INFO] Removed retired runtime resource ${retiredOutput}`)
  }
  const resourceOrder = ['singBox', 'notoColorEmoji', 'sysproxy']

  console.log(
    `[INFO] Preparing locked Windows x64 resources${OFFLINE ? ' (offline verification)' : ''}`
  )
  for (const name of resourceOrder) {
    await ensureResource(name, resources[name])
  }
  console.log(`[INFO] All ${resourceOrder.length} locked resources passed integrity verification`)
}

try {
  await main()
} catch (error) {
  console.error(
    `[FATAL] Resource preparation failed: ${error instanceof Error ? error.message : error}`
  )
  process.exitCode = 1
}
