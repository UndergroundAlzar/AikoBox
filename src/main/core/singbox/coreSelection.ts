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
}

const VERSION_PATTERN = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/
const HASH_PATTERN = /^[a-f0-9]{64}$/

export function managedCoreFilename(version: string): string {
  if (!VERSION_PATTERN.test(version)) throw new Error('Invalid sing-box version')
  return `sing-box-${version}-windows-amd64.exe`
}

export function isValidCoreSelectionEntry(value: unknown): value is CoreSelectionEntry {
  if (!value || typeof value !== 'object') return false
  const entry = value as Partial<CoreSelectionEntry>
  return (
    typeof entry.version === 'string' &&
    VERSION_PATTERN.test(entry.version) &&
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
    const rawManifest = await readFile(path.join(coreDir, CORE_SELECTION_FILE), 'utf8').catch(
      (error: NodeJS.ErrnoException) => {
        if (error.code === 'ENOENT') return null
        throw error
      }
    )
    if (rawManifest === null) return null
    const manifest = parseCoreSelectionManifest(JSON.parse(rawManifest))
    if (!manifest) throw new Error('managed core manifest is invalid')
    const selected = path.join(coreDir, manifest.active.file)
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
    if (firstHash !== manifest.active.sha256) throw new Error('managed core SHA-256 mismatch')

    const { stdout, stderr } = await options.execFile(selected, ['version'])
    const reported = `${stdout}\n${stderr}`.match(/sing-box version\s+(\S+)/i)?.[1]
    if (reported !== manifest.active.version) throw new Error('managed core version mismatch')

    // Close the validation/execution gap as far as Windows path execution
    // permits: verify identity and content again after the version process.
    const secondStat = await lstat(selected)
    if (!sameFileIdentity(firstIdentity, secondStat))
      throw new Error('managed core identity changed')
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
    return { path: selected, entry: manifest.active }
  } catch (error) {
    options.warn?.(
      `Managed sing-box core rejected; falling back to bundled core: ${
        error instanceof Error ? error.message : String(error)
      }`
    )
    return null
  }
}
