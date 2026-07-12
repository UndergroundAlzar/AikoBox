import { createHash } from 'crypto'
import { lstat, open, readFile, realpath } from 'fs/promises'
import path from 'path'

export const CORE_SELECTION_SCHEMA = 1
export const CORE_SELECTION_FILE = 'active-core.json'

export interface CoreSelectionEntry {
  file: string
  version: string
  sha256: string
}

export interface CoreSelectionManifest {
  schema: typeof CORE_SELECTION_SCHEMA
  active: CoreSelectionEntry
  previous?: CoreSelectionEntry | 'bundled'
  /** Active is a candidate until a health-checked restart atomically clears this marker. */
  pending?: true
}

const MAX_CORE_VERSION_LENGTH = 128
const SEMVER_NUMBER = '(?:0|[1-9]\\d*)'
const SEMVER_PRERELEASE_IDENTIFIER = '(?:(?:0|[1-9]\\d*)|(?:[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*))'
const VERSION_PATTERN = new RegExp(
  `^${SEMVER_NUMBER}\\.${SEMVER_NUMBER}\\.${SEMVER_NUMBER}(?:-${SEMVER_PRERELEASE_IDENTIFIER}(?:\\.${SEMVER_PRERELEASE_IDENTIFIER})*)?$`
)
const HASH_PATTERN = /^[a-f0-9]{64}$/

export function isValidCoreVersion(value: unknown): value is string {
  return (
    typeof value === 'string' &&
    value.length > 0 &&
    value.length <= MAX_CORE_VERSION_LENGTH &&
    VERSION_PATTERN.test(value)
  )
}

export function managedCoreFilename(version: string): string {
  if (!isValidCoreVersion(version)) throw new Error('Invalid sing-box version')
  return `sing-box-${version}-windows-amd64.exe`
}

export function isValidCoreSelectionEntry(value: unknown): value is CoreSelectionEntry {
  if (!value || typeof value !== 'object') return false
  const entry = value as Partial<CoreSelectionEntry>
  return (
    isValidCoreVersion(entry.version) &&
    entry.file === managedCoreFilename(entry.version) &&
    typeof entry.sha256 === 'string' &&
    HASH_PATTERN.test(entry.sha256)
  )
}

export function parseCoreSelectionManifest(value: unknown): CoreSelectionManifest | null {
  if (!value || typeof value !== 'object') return null
  const manifest = value as Partial<CoreSelectionManifest>
  if (manifest.schema !== CORE_SELECTION_SCHEMA || !isValidCoreSelectionEntry(manifest.active)) {
    return null
  }
  if (
    manifest.previous !== undefined &&
    manifest.previous !== 'bundled' &&
    !isValidCoreSelectionEntry(manifest.previous)
  ) {
    return null
  }
  if (manifest.pending !== undefined && manifest.pending !== true) return null
  if (manifest.pending === true && manifest.previous === undefined) return null
  return manifest as CoreSelectionManifest
}

export interface VerifiedCoreSelection {
  path: string
  entry: CoreSelectionEntry
}

export interface VerifyManagedCoreOptions {
  elevated: boolean
  execFile(file: string, args: readonly string[]): Promise<{ stdout: string; stderr: string }>
  warn?: (message: string) => void
}

function sameFileIdentity(
  before: { dev: number; ino: number; size: number; mtimeMs: number },
  after: { dev: number; ino: number; size: number; mtimeMs: number }
): boolean {
  return (
    before.dev === after.dev &&
    before.ino === after.ino &&
    before.size === after.size &&
    before.mtimeMs === after.mtimeMs
  )
}

function sameSelectionEntry(left: CoreSelectionEntry, right: CoreSelectionEntry): boolean {
  return left.file === right.file && left.version === right.version && left.sha256 === right.sha256
}

async function readSelectionManifest(coreDir: string): Promise<CoreSelectionManifest> {
  const rawManifest = await readFile(path.join(coreDir, CORE_SELECTION_FILE), 'utf8')
  const manifest = parseCoreSelectionManifest(JSON.parse(rawManifest))
  if (!manifest) throw new Error('managed core manifest is invalid')
  return manifest
}

async function verifyManagedCoreEntry(
  coreDir: string,
  entry: CoreSelectionEntry,
  options: VerifyManagedCoreOptions
): Promise<VerifiedCoreSelection> {
  const selected = path.join(coreDir, entry.file)
  const coreRoot = await realpath(coreDir)
  const resolved = await realpath(selected)
  if (path.dirname(resolved).toLowerCase() !== coreRoot.toLowerCase()) {
    throw new Error('managed core escapes its trusted directory')
  }
  const linkStat = await lstat(selected)
  if (!linkStat.isFile() || linkStat.isSymbolicLink()) {
    throw new Error('managed core is not a regular file')
  }

  const handle = await open(selected, 'r')
  let firstIdentity
  let firstHash
  try {
    firstIdentity = await handle.stat()
    firstHash = createHash('sha256')
      .update(await handle.readFile())
      .digest('hex')
    const afterRead = await handle.stat()
    if (!sameFileIdentity(firstIdentity, afterRead))
      throw new Error('managed core changed while read')
  } finally {
    await handle.close()
  }
  if (firstHash !== entry.sha256) throw new Error('managed core SHA-256 mismatch')

  const { stdout, stderr } = await options.execFile(selected, ['version'])
  const reported = `${stdout}\n${stderr}`.match(/sing-box version\s+(\S+)/i)?.[1]
  if (reported !== entry.version) throw new Error('managed core version mismatch')

  // Close the validation/execution gap as far as Windows path execution
  // permits: verify identity and content again after the version process.
  const secondStat = await lstat(selected)
  if (!sameFileIdentity(firstIdentity, secondStat)) throw new Error('managed core identity changed')
  const secondHandle = await open(selected, 'r')
  try {
    const secondBefore = await secondHandle.stat()
    if (!sameFileIdentity(firstIdentity, secondBefore)) {
      throw new Error('managed core identity changed after version check')
    }
    const secondHash = createHash('sha256')
      .update(await secondHandle.readFile())
      .digest('hex')
    if (secondHash !== firstHash) throw new Error('managed core changed after verification')
    const secondAfter = await secondHandle.stat()
    if (!sameFileIdentity(secondBefore, secondAfter)) {
      throw new Error('managed core changed during final verification')
    }
  } finally {
    await secondHandle.close()
  }
  return { path: selected, entry }
}

/**
 * Resolves a managed core only for a non-elevated process and re-verifies the
 * exact file immediately before it may be executed. Elevated/TUN sessions must
 * always use the installation-owned bundled core: otherwise a standard user
 * could replace an AppData executable and gain administrator code execution.
 */
export async function resolveVerifiedManagedCorePath(
  coreDir: string,
  options: VerifyManagedCoreOptions
): Promise<VerifiedCoreSelection | null> {
  if (options.elevated) return null

  try {
    const manifest = await readSelectionManifest(coreDir)
    const selected = manifest.pending ? manifest.previous : manifest.active
    if (selected === 'bundled') return null
    if (!selected) throw new Error('pending managed core has no last-known-good selection')
    return await verifyManagedCoreEntry(coreDir, selected, options)
  } catch (error) {
    options.warn?.(
      `Managed sing-box core rejected; falling back to bundled core: ${
        error instanceof Error ? error.message : String(error)
      }`
    )
    return null
  }
}

/**
 * Resolves a pending candidate only when the current update transaction presents
 * the exact in-memory entry it staged. A fresh process has no such authorization
 * and therefore always takes the last-known-good path above.
 */
export async function resolveVerifiedPendingManagedCorePath(
  coreDir: string,
  expected: CoreSelectionEntry,
  options: VerifyManagedCoreOptions
): Promise<VerifiedCoreSelection> {
  if (options.elevated)
    throw new Error('pending managed core validation is forbidden when elevated')
  const manifest = await readSelectionManifest(coreDir)
  if (!manifest.pending || !sameSelectionEntry(manifest.active, expected)) {
    throw new Error('pending managed core selection no longer matches this update transaction')
  }
  return await verifyManagedCoreEntry(coreDir, expected, options)
}
