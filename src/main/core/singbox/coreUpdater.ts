import { createHash, randomUUID } from 'crypto'
import { execFile } from 'child_process'
import { mkdir, readFile, rename, rm, writeFile } from 'fs/promises'
import path from 'path'
import { promisify } from 'util'
import AdmZip from 'adm-zip'
import { writeFileAtomically } from '../../config/remoteResource'
import {
  CORE_SELECTION_FILE,
  CORE_SELECTION_SCHEMA,
  managedCoreFilename,
  parseCoreSelectionManifest,
  resolveVerifiedManagedCorePath,
  type CoreSelectionEntry,
  type CoreSelectionManifest
} from './coreSelection'

const execFilePromise = promisify(execFile)

export const OFFICIAL_RELEASE_API = 'https://api.github.com/repos/SagerNet/sing-box/releases/latest'
const OFFICIAL_DOWNLOAD_PREFIX = 'https://github.com/SagerNet/sing-box/releases/download/'
const ALLOWED_RESPONSE_HOSTS = new Set([
  'api.github.com',
  'github.com',
  'objects.githubusercontent.com',
  'release-assets.githubusercontent.com'
])
const MAX_METADATA_BYTES = 2 * 1024 * 1024
const MAX_ARCHIVE_BYTES = 128 * 1024 * 1024
const MAX_EXECUTABLE_BYTES = 128 * 1024 * 1024
const REQUEST_TIMEOUT_MS = 60_000

export const CANDIDATE_VALIDATION_CONFIG = Object.freeze({
  log: { disabled: true },
  inbounds: [] as unknown[],
  outbounds: [{ type: 'direct', tag: 'direct' }],
  route: { final: 'direct' }
})

interface GithubAsset {
  name: string
  browser_download_url: string
  size?: number
  digest?: string | null
}

interface GithubRelease {
  tag_name: string
  html_url: string
  draft: boolean
  prerelease: boolean
  published_at?: string
  assets: GithubAsset[]
}

export interface CoreReleaseInfo {
  currentVersion: string
  latestVersion: string
  updateAvailable: boolean
  releaseUrl: string
  publishedAt?: string
  canRollback: boolean
}

export interface CoreUpdateResult {
  version: string
  previousVersion: string
  rolledBack: boolean
  canRollback: boolean
}

export interface StagedCoreUpdate {
  token: string
  version: string
  previousVersion: string
}

export interface CoreUpdaterDependencies {
  fetch: typeof fetch
  platform: NodeJS.Platform
  arch: string
  coreDir: string
  bundledCorePath: string
  elevated: boolean
  warn?: (message: string) => void
  execFile?: (file: string, args: readonly string[]) => Promise<{ stdout: string; stderr: string }>
}

interface TrustedRelease extends CoreReleaseInfo {
  archive: GithubAsset
  checksums?: GithubAsset
  previousSelection: CoreSelectionEntry | 'bundled'
}

interface PreparedCore {
  entry: CoreSelectionEntry
  stagedPath: string
  tempDir: string
}

function assertWindowsX64(platform: NodeJS.Platform, arch: string): void {
  if (platform !== 'win32' || arch !== 'x64') {
    throw new Error('sing-box core updates are supported only on Windows x64')
  }
}

function normalizeVersion(value: string): string {
  const version = value.startsWith('v') ? value.slice(1) : value
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error(`Untrusted sing-box release version: ${value}`)
  }
  return version
}

function compareIdentifiers(left: string, right: string): number {
  const leftNumeric = /^\d+$/.test(left)
  const rightNumeric = /^\d+$/.test(right)
  if (leftNumeric && rightNumeric) return Number(left) - Number(right)
  if (leftNumeric !== rightNumeric) return leftNumeric ? -1 : 1
  return left.localeCompare(right)
}

export function compareVersions(leftValue: string, rightValue: string): number {
  const left = normalizeVersion(leftValue)
  const right = normalizeVersion(rightValue)
  const [leftMain, leftPre] = left.split('-', 2)
  const [rightMain, rightPre] = right.split('-', 2)
  const leftParts = leftMain.split('.').map(Number)
  const rightParts = rightMain.split('.').map(Number)
  for (let i = 0; i < 3; i++) {
    if (leftParts[i] !== rightParts[i]) return leftParts[i] - rightParts[i]
  }
  if (leftPre === undefined || rightPre === undefined) {
    return leftPre === rightPre ? 0 : leftPre === undefined ? 1 : -1
  }
  const leftIds = leftPre.split('.')
  const rightIds = rightPre.split('.')
  for (let i = 0; i < Math.max(leftIds.length, rightIds.length); i++) {
    if (leftIds[i] === undefined) return -1
    if (rightIds[i] === undefined) return 1
    const result = compareIdentifiers(leftIds[i], rightIds[i])
    if (result !== 0) return result
  }
  return 0
}

function assertTrustedResponseUrl(urlValue: string): void {
  const url = new URL(urlValue)
  if (url.protocol !== 'https:' || !ALLOWED_RESPONSE_HOSTS.has(url.hostname)) {
    throw new Error(`Refusing untrusted update response URL: ${urlValue}`)
  }
}

function assertOfficialAsset(asset: GithubAsset, expectedName: string, version: string): void {
  if (asset.name !== expectedName) throw new Error(`Unexpected release asset: ${asset.name}`)
  const url = new URL(asset.browser_download_url)
  const expectedUrl = `${OFFICIAL_DOWNLOAD_PREFIX}v${version}/${expectedName}`
  if (url.protocol !== 'https:' || url.hostname !== 'github.com' || url.href !== expectedUrl) {
    throw new Error(`Refusing untrusted sing-box asset URL: ${asset.browser_download_url}`)
  }
}

async function readResponseLimited(response: Response, maxBytes: number): Promise<Buffer> {
  const declaredLength = Number(response.headers.get('content-length') || 0)
  if (declaredLength > maxBytes) throw new Error('Update response exceeds the size limit')
  if (!response.body) throw new Error('Update response has no body')

  const reader = response.body.getReader()
  const chunks: Buffer[] = []
  let total = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > maxBytes) {
      await reader.cancel()
      throw new Error('Update response exceeds the size limit')
    }
    chunks.push(Buffer.from(value))
  }
  return Buffer.concat(chunks, total)
}

async function trustedFetch(fetcher: typeof fetch, url: string, maxBytes: number): Promise<Buffer> {
  const controller = new AbortController()
  const timer = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS)
  try {
    const response = await fetcher(url, {
      redirect: 'follow',
      signal: controller.signal,
      headers: {
        Accept: 'application/vnd.github+json',
        'User-Agent': 'AikoBox-core-updater'
      }
    })
    if (!response.ok) throw new Error(`Update server returned HTTP ${response.status}`)
    assertTrustedResponseUrl(response.url || url)
    return await readResponseLimited(response, maxBytes)
  } finally {
    clearTimeout(timer)
  }
}

export function parseChecksumFile(content: string, archiveName: string): string {
  for (const line of content.split(/\r?\n/)) {
    const match = line.trim().match(/^([a-fA-F0-9]{64})\s+\*?(.+)$/)
    if (match && match[2].trim() === archiveName) {
      return match[1].toLowerCase()
    }
  }
  throw new Error(`Official checksum is missing for ${archiveName}`)
}

function parseVersionOutput(output: string): string {
  const match = output.match(/sing-box version\s+(\S+)/i)
  if (!match) throw new Error('Candidate does not identify itself as sing-box')
  return normalizeVersion(match[1])
}

async function sha256File(file: string): Promise<string> {
  return createHash('sha256')
    .update(await readFile(file))
    .digest('hex')
}

async function readManifest(coreDir: string): Promise<CoreSelectionManifest | null> {
  try {
    return parseCoreSelectionManifest(
      JSON.parse(await readFile(path.join(coreDir, CORE_SELECTION_FILE), 'utf8'))
    )
  } catch {
    return null
  }
}

async function writeManifest(coreDir: string, manifest: CoreSelectionManifest): Promise<void> {
  await mkdir(coreDir, { recursive: true })
  const destination = path.join(coreDir, CORE_SELECTION_FILE)
  await writeFileAtomically(destination, `${JSON.stringify(manifest, null, 2)}\n`)
}

async function removeManifest(coreDir: string): Promise<void> {
  await rm(path.join(coreDir, CORE_SELECTION_FILE), { force: true })
}

async function currentVersion(
  corePath: string,
  run: NonNullable<CoreUpdaterDependencies['execFile']>
): Promise<string> {
  const { stdout, stderr } = await run(corePath, ['version'])
  return parseVersionOutput(`${stdout}\n${stderr}`)
}

function defaultExecFile(
  file: string,
  args: readonly string[]
): Promise<{ stdout: string; stderr: string }> {
  return execFilePromise(file, [...args], {
    timeout: 15_000,
    windowsHide: true,
    maxBuffer: 1024 * 1024
  }) as Promise<{ stdout: string; stderr: string }>
}

export function createCoreUpdater(dependencies: CoreUpdaterDependencies): {
  check(): Promise<CoreReleaseInfo>
  stage(version: string): Promise<StagedCoreUpdate>
  apply(token: string): Promise<CoreUpdateResult>
  rollback(): Promise<CoreUpdateResult>
  undoSelectionChange(): Promise<void>
  commitSelectionChange(): Promise<void>
} {
  const run = dependencies.execFile ?? defaultExecFile
  let operation: Promise<unknown> | null = null
  let selectionUndo: CoreSelectionManifest | null | undefined
  const staged = new Map<
    string,
    PreparedCore & {
      previousVersion: string
      previousSelection: CoreSelectionEntry | 'bundled'
    }
  >()

  const selectedCore = async (): Promise<{
    path: string
    entry: CoreSelectionEntry | 'bundled'
  }> => {
    const verified = await resolveVerifiedManagedCorePath(dependencies.coreDir, {
      elevated: dependencies.elevated,
      execFile: run,
      warn: dependencies.warn
    })
    return verified
      ? { path: verified.path, entry: verified.entry }
      : { path: dependencies.bundledCorePath, entry: 'bundled' }
  }

  const discover = async (): Promise<TrustedRelease> => {
    assertWindowsX64(dependencies.platform, dependencies.arch)
    const metadata = await trustedFetch(
      dependencies.fetch,
      OFFICIAL_RELEASE_API,
      MAX_METADATA_BYTES
    )
    const release = JSON.parse(metadata.toString('utf8')) as Partial<GithubRelease>
    if (
      release.draft !== false ||
      release.prerelease !== false ||
      typeof release.tag_name !== 'string' ||
      typeof release.html_url !== 'string' ||
      !Array.isArray(release.assets)
    ) {
      throw new Error('GitHub returned an invalid or non-stable sing-box release')
    }
    const version = normalizeVersion(release.tag_name)
    const expectedArchive = `sing-box-${version}-windows-amd64.zip`
    const expectedChecksums = `sing-box-${version}-checksums.txt`
    const archive = release.assets.find((asset) => asset.name === expectedArchive)
    const checksums = release.assets.find((asset) => asset.name === expectedChecksums)
    if (!archive) throw new Error('Official Windows x64 archive is missing')
    assertOfficialAsset(archive, expectedArchive, version)
    if (archive.size !== undefined && (archive.size <= 0 || archive.size > MAX_ARCHIVE_BYTES)) {
      throw new Error('Official Windows x64 archive has an invalid size')
    }
    if (checksums) assertOfficialAsset(checksums, expectedChecksums, version)
    const githubDigest = archive.digest?.match(/^sha256:([a-f0-9]{64})$/)?.[1]
    if (!checksums && !githubDigest) {
      throw new Error('Official SHA-256 release digest or checksum manifest is missing')
    }
    const releaseUrl = new URL(release.html_url)
    if (
      releaseUrl.protocol !== 'https:' ||
      releaseUrl.hostname !== 'github.com' ||
      releaseUrl.pathname !== `/SagerNet/sing-box/releases/tag/v${version}`
    ) {
      throw new Error('GitHub returned an untrusted release page')
    }
    const selected = await selectedCore()
    const installed = await currentVersion(selected.path, run)
    const manifest = await readManifest(dependencies.coreDir)
    return {
      currentVersion: installed,
      latestVersion: version,
      updateAvailable: compareVersions(version, installed) > 0,
      releaseUrl: release.html_url,
      publishedAt: release.published_at,
      canRollback: !dependencies.elevated && Boolean(manifest?.previous),
      archive,
      checksums,
      previousSelection: selected.entry
    }
  }

  const prepare = async (release: TrustedRelease): Promise<PreparedCore> => {
    const tempDir = path.join(dependencies.coreDir, '.updates', randomUUID())
    await mkdir(tempDir, { recursive: true })
    const archivePath = path.join(tempDir, release.archive.name)
    const stagedPath = path.join(tempDir, 'sing-box.candidate.exe')
    try {
      const archiveBytes = await trustedFetch(
        dependencies.fetch,
        release.archive.browser_download_url,
        MAX_ARCHIVE_BYTES
      )
      await writeFile(archivePath, archiveBytes, { flag: 'wx' })
      // Prefer the project's checksum file when present. Current GitHub releases
      // expose a platform-generated sha256 digest directly on each asset.
      const expectedHash = release.checksums
        ? parseChecksumFile(
            (
              await trustedFetch(
                dependencies.fetch,
                release.checksums.browser_download_url,
                MAX_METADATA_BYTES
              )
            ).toString('utf8'),
            release.archive.name
          )
        : release.archive.digest?.slice('sha256:'.length)
      if (!expectedHash) throw new Error('Official SHA-256 verification material is missing')
      const actualHash = await sha256File(archivePath)
      if (actualHash !== expectedHash)
        throw new Error('sing-box archive SHA-256 verification failed')

      const zip = new AdmZip(archivePath)
      const executableEntries = zip
        .getEntries()
        .filter(
          (entry) => !entry.isDirectory && path.posix.basename(entry.entryName) === 'sing-box.exe'
        )
      if (executableEntries.length !== 1) {
        throw new Error('Official archive must contain exactly one sing-box.exe')
      }
      const executableSize = executableEntries[0].header.size
      if (
        !Number.isSafeInteger(executableSize) ||
        executableSize <= 0 ||
        executableSize > MAX_EXECUTABLE_BYTES
      ) {
        throw new Error('sing-box.exe in the official archive has an invalid size')
      }
      await writeFile(stagedPath, executableEntries[0].getData(), { flag: 'wx', mode: 0o755 })
      const executableHash = await sha256File(stagedPath)
      const { stdout, stderr } = await run(stagedPath, ['version'])
      const candidateVersion = parseVersionOutput(`${stdout}\n${stderr}`)
      if (candidateVersion !== release.latestVersion) {
        throw new Error(
          `Candidate version mismatch: expected ${release.latestVersion}, got ${candidateVersion}`
        )
      }

      const validationConfig = path.join(tempDir, 'validation.json')
      await writeFile(validationConfig, JSON.stringify(CANDIDATE_VALIDATION_CONFIG))
      await run(stagedPath, ['check', '-c', validationConfig, '--disable-color'])
      return {
        entry: {
          file: managedCoreFilename(candidateVersion),
          version: candidateVersion,
          sha256: executableHash
        },
        stagedPath,
        tempDir
      }
    } catch (error) {
      await rm(tempDir, { recursive: true, force: true })
      throw error
    }
  }

  const withLock = async <T>(task: () => Promise<T>): Promise<T> => {
    if (operation) throw new Error('Another sing-box core update operation is already running')
    const promise = task()
    operation = promise
    try {
      return await promise
    } finally {
      operation = null
    }
  }

  return {
    check: () => withLock(discover),
    stage: (requestedVersion) =>
      withLock(async () => {
        if (dependencies.elevated) {
          throw new Error(
            'For security, managed core updates require a non-elevated AikoBox session'
          )
        }
        const release = await discover()
        const normalizedRequested = normalizeVersion(requestedVersion)
        if (normalizedRequested !== release.latestVersion) {
          throw new Error('The selected sing-box release is no longer the latest stable release')
        }
        if (!release.updateAvailable)
          throw new Error('The installed sing-box core is already current')

        const prepared = await prepare(release)
        const token = randomUUID()
        staged.set(token, {
          ...prepared,
          previousVersion: release.currentVersion,
          previousSelection: release.previousSelection
        })
        return { token, version: prepared.entry.version, previousVersion: release.currentVersion }
      }),
    apply: (token) =>
      withLock(async () => {
        selectionUndo = undefined
        assertWindowsX64(dependencies.platform, dependencies.arch)
        if (dependencies.elevated) {
          throw new Error('Managed core activation is forbidden in an elevated AikoBox session')
        }
        const prepared = staged.get(token)
        if (!prepared) throw new Error('The staged sing-box update is missing or expired')
        try {
          const previousManifest = await readManifest(dependencies.coreDir)
          if ((await sha256File(prepared.stagedPath)) !== prepared.entry.sha256) {
            throw new Error('Staged sing-box core changed after verification')
          }
          const finalPath = path.join(dependencies.coreDir, prepared.entry.file)
          await mkdir(dependencies.coreDir, { recursive: true })
          await rm(finalPath, { force: true })
          await rename(prepared.stagedPath, finalPath)
          if ((await sha256File(finalPath)) !== prepared.entry.sha256) {
            throw new Error('Installed sing-box core failed post-write verification')
          }
          await writeManifest(dependencies.coreDir, {
            schema: CORE_SELECTION_SCHEMA,
            active: prepared.entry,
            previous: prepared.previousSelection
          })
          selectionUndo = previousManifest
          return {
            version: prepared.entry.version,
            previousVersion: prepared.previousVersion,
            rolledBack: false,
            canRollback: true
          }
        } finally {
          staged.delete(token)
          await rm(prepared.tempDir, { recursive: true, force: true })
        }
      }),
    rollback: () =>
      withLock(async () => {
        selectionUndo = undefined
        assertWindowsX64(dependencies.platform, dependencies.arch)
        if (dependencies.elevated) {
          throw new Error('Managed core rollback is forbidden in an elevated AikoBox session')
        }
        const manifest = await readManifest(dependencies.coreDir)
        if (!manifest?.previous) throw new Error('No previous sing-box core is available')
        const current = manifest.active
        const target = manifest.previous
        if (target === 'bundled') {
          const version = await currentVersion(dependencies.bundledCorePath, run)
          await removeManifest(dependencies.coreDir)
          selectionUndo = manifest
          return {
            version,
            previousVersion: current.version,
            rolledBack: true,
            canRollback: false
          }
        }
        const targetPath = path.join(dependencies.coreDir, target.file)
        if ((await sha256File(targetPath)) !== target.sha256) {
          throw new Error('Previous sing-box core SHA-256 verification failed')
        }
        const version = await currentVersion(targetPath, run)
        if (version !== target.version) throw new Error('Previous sing-box core version mismatch')
        await writeManifest(dependencies.coreDir, {
          schema: CORE_SELECTION_SCHEMA,
          active: target,
          previous: current
        })
        selectionUndo = manifest
        return {
          version,
          previousVersion: current.version,
          rolledBack: true,
          canRollback: true
        }
      }),
    undoSelectionChange: () =>
      withLock(async () => {
        if (selectionUndo === undefined) throw new Error('No core selection change can be undone')
        const previous = selectionUndo
        if (previous) await writeManifest(dependencies.coreDir, previous)
        else await removeManifest(dependencies.coreDir)
        selectionUndo = undefined
      }),
    commitSelectionChange: () =>
      withLock(async () => {
        selectionUndo = undefined
      })
  }
}
