import { execFile } from 'child_process'
import { createHash } from 'crypto'
import { existsSync } from 'fs'
import { mkdtemp, readFile, rm, writeFile } from 'fs/promises'
import os from 'os'
import path from 'path'
import AdmZip from 'adm-zip'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { CORE_SELECTION_FILE, resolveVerifiedManagedCorePath } from './coreSelection'
import {
  CANDIDATE_VALIDATION_CONFIG,
  compareVersions,
  createCoreUpdater,
  OFFICIAL_RELEASE_API,
  parseChecksumFile
} from './coreUpdater'

const tempDirs: string[] = []

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

function response(body: BodyInit, url: string, status = 200): Response {
  const result = new Response(body, { status })
  Object.defineProperty(result, 'url', { value: url })
  return result
}

async function fixture(options?: {
  corruptChecksum?: boolean
  corruptChecksumAsset?: boolean
  elevated?: boolean
  checksumAsset?: boolean
  omitDigest?: boolean
  candidateVersion?: string
  checkFails?: boolean
  untrustedAssetUrl?: boolean
  untrustedRedirect?: boolean
  wrongArchiveLayout?: boolean
  now?: () => number
  stagedUpdateTtlMs?: number
}) {
  const root = await mkdtemp(path.join(os.tmpdir(), 'aikobox-core-updater-'))
  tempDirs.push(root)
  const coreDir = path.join(root, 'core')
  const bundledCorePath = path.join(root, 'sing-box.exe')
  await writeFile(bundledCorePath, 'bundled')

  const version = '1.2.0'
  const archiveName = `sing-box-${version}-windows-amd64.zip`
  const checksumName = `sing-box-${version}-checksums.txt`
  const base = `https://github.com/SagerNet/sing-box/releases/download/v${version}`
  const archiveUrl = `${base}/${archiveName}`
  const advertisedArchiveUrl = options?.untrustedAssetUrl
    ? `https://example.com/${archiveName}`
    : archiveUrl
  const checksumUrl = `${base}/${checksumName}`
  const zip = new AdmZip()
  zip.addFile(
    options?.wrongArchiveLayout
      ? 'unexpected/sing-box.exe'
      : `sing-box-${version}-windows-amd64/sing-box.exe`,
    Buffer.from('new-core')
  )
  const archive = zip.toBuffer()
  const checksum = createHash('sha256').update(archive).digest('hex')
  const release = {
    tag_name: `v${version}`,
    html_url: `https://github.com/SagerNet/sing-box/releases/tag/v${version}`,
    draft: false,
    prerelease: false,
    published_at: '2026-07-10T00:00:00Z',
    assets: [
      {
        name: archiveName,
        browser_download_url: advertisedArchiveUrl,
        size: archive.length,
        ...(options?.omitDigest
          ? {}
          : { digest: `sha256:${options?.corruptChecksum ? '0'.repeat(64) : checksum}` })
      },
      ...(options?.checksumAsset ? [{ name: checksumName, browser_download_url: checksumUrl }] : [])
    ]
  }
  const fetcher = vi.fn(async (input: string | URL | Request) => {
    const url = String(input)
    if (url === OFFICIAL_RELEASE_API) return response(JSON.stringify(release), url)
    if (url === archiveUrl) {
      return response(archive, options?.untrustedRedirect ? 'https://example.com/archive.zip' : url)
    }
    if (url === checksumUrl) {
      const value = options?.corruptChecksumAsset ? '0'.repeat(64) : checksum
      return response(`${value}  ${archiveName}\n`, url)
    }
    return response('', url, 404)
  }) as unknown as typeof fetch
  const exec = vi.fn(async (file: string, args: readonly string[]) => {
    if (args[0] === 'version') {
      return {
        stdout:
          file === bundledCorePath
            ? 'sing-box version 1.0.0'
            : `sing-box version ${options?.candidateVersion ?? version}`,
        stderr: ''
      }
    }
    if (args[0] === 'check') {
      if (options?.checkFails) throw new Error('invalid candidate config')
      return { stdout: '', stderr: '' }
    }
    throw new Error('unexpected command')
  })
  const updater = createCoreUpdater({
    fetch: fetcher,
    platform: 'win32',
    arch: 'x64',
    coreDir,
    bundledCorePath,
    elevated: options?.elevated ?? false,
    execFile: exec,
    now: options?.now,
    stagedUpdateTtlMs: options?.stagedUpdateTtlMs
  })
  return { updater, coreDir, bundledCorePath, exec, version, archiveName }
}

describe('sing-box core updater', () => {
  it.skipIf(!existsSync(path.resolve('extra/sidecar/sing-box.exe')))(
    'uses a validation config accepted by the bundled sing-box check command',
    async () => {
      const root = await mkdtemp(path.join(os.tmpdir(), 'aikobox-core-check-'))
      tempDirs.push(root)
      const config = path.join(root, 'validation.json')
      await writeFile(config, JSON.stringify(CANDIDATE_VALIDATION_CONFIG))
      await new Promise<void>((resolve, reject) => {
        execFile(
          path.resolve('extra/sidecar/sing-box.exe'),
          ['check', '-c', config, '--disable-color'],
          { windowsHide: true, timeout: 15_000 },
          (error) => (error ? reject(error) : resolve())
        )
      })
    }
  )

  it('compares stable and prerelease versions correctly', () => {
    expect(compareVersions('1.13.0', '1.12.9')).toBeGreaterThan(0)
    expect(compareVersions('1.13.0', '1.13.0-beta.2')).toBeGreaterThan(0)
    expect(compareVersions('1.13.0-beta.10', '1.13.0-beta.2')).toBeGreaterThan(0)
    expect(compareVersions('1.13.0-beta-2', '1.13.0-beta-1')).toBeGreaterThan(0)
    expect(compareVersions('999999999999999999999.0.0', '2.0.0')).toBeGreaterThan(0)
    expect(() => compareVersions('01.13.0', '1.13.0')).toThrow('Untrusted')
    expect(() => compareVersions('1.13.0-beta..1', '1.13.0')).toThrow('Untrusted')
  })

  it('parses only the checksum belonging to the exact archive', () => {
    const hash = 'a'.repeat(64)
    expect(
      parseChecksumFile(`${'b'.repeat(64)} other.zip\n${hash} *wanted.zip`, 'wanted.zip')
    ).toBe(hash)
    expect(() => parseChecksumFile(`${hash} almost-wanted.zip`, 'wanted.zip')).toThrow()
    expect(() =>
      parseChecksumFile(`${hash} wanted.zip\n${hash} *wanted.zip`, 'wanted.zip')
    ).toThrow('duplicate')
  })

  it('keeps an applied candidate pending until its health-checked restart is committed', async () => {
    const { updater, coreDir, exec, version } = await fixture()
    const available = await updater.check()
    expect(available).toMatchObject({
      currentVersion: '1.0.0',
      latestVersion: version,
      updateAvailable: true,
      canRollback: false
    })

    const staged = await updater.stage(version)
    await expect(readFile(path.join(coreDir, CORE_SELECTION_FILE))).rejects.toMatchObject({
      code: 'ENOENT'
    })
    const result = await updater.apply(staged.token)
    expect(result).toEqual({
      version,
      previousVersion: '1.0.0',
      rolledBack: false,
      canRollback: true
    })
    expect(exec).toHaveBeenCalledWith(expect.stringContaining('sing-box.candidate.exe'), [
      'check',
      '-c',
      expect.stringContaining('validation.json'),
      '--disable-color'
    ])
    const manifest = JSON.parse(await readFile(path.join(coreDir, CORE_SELECTION_FILE), 'utf8'))
    expect(manifest).toMatchObject({
      schema: 1,
      active: { version, file: `sing-box-${version}-windows-amd64.exe` },
      previous: 'bundled',
      pending: true
    })
    expect(updater.getPendingValidationSelection()).toEqual(manifest.active)

    // Simulate a process crash after apply but before commit. A fresh resolver
    // has no in-memory transaction authorization and must stay on bundled.
    await expect(
      resolveVerifiedManagedCorePath(coreDir, {
        elevated: false,
        execFile: async () => {
          throw new Error('pending candidate must not execute after a crash')
        }
      })
    ).resolves.toBeNull()

    await updater.commitSelectionChange()
    const committed = JSON.parse(await readFile(path.join(coreDir, CORE_SELECTION_FILE), 'utf8'))
    expect(committed).toMatchObject({ active: manifest.active, previous: 'bundled' })
    expect(committed).not.toHaveProperty('pending')
    expect(updater.getPendingValidationSelection()).toBeNull()
  })

  it('never creates an active selection when digest validation fails', async () => {
    const { updater, version, coreDir } = await fixture({ corruptChecksum: true })
    await expect(updater.stage(version)).rejects.toThrow('SHA-256')
    await expect(readFile(path.join(coreDir, CORE_SELECTION_FILE))).rejects.toMatchObject({
      code: 'ENOENT'
    })
  })

  it('requires the official checksum asset and GitHub digest to agree', async () => {
    const { updater, version } = await fixture({
      checksumAsset: true,
      corruptChecksumAsset: true
    })
    await expect(updater.stage(version)).rejects.toThrow('SHA-256 sources disagree')

    const corruptDigest = await fixture({ checksumAsset: true, corruptChecksum: true })
    await expect(corruptDigest.updater.stage(corruptDigest.version)).rejects.toThrow(
      'SHA-256 sources disagree'
    )
  })

  it('fails closed when the release supplies no official SHA-256 material', async () => {
    const { updater } = await fixture({ omitDigest: true })
    await expect(updater.check()).rejects.toThrow('SHA-256 release digest')
  })

  it('rejects spoofed asset URLs and redirects outside trusted GitHub hosts', async () => {
    const spoofed = await fixture({ untrustedAssetUrl: true })
    await expect(spoofed.updater.check()).rejects.toThrow('untrusted sing-box asset URL')

    const redirected = await fixture({ untrustedRedirect: true })
    await expect(redirected.updater.stage(redirected.version)).rejects.toThrow(
      'untrusted update response URL'
    )
  })

  it('rejects a candidate with a mismatched version or failing check before activation', async () => {
    const mismatched = await fixture({ candidateVersion: '1.2.1' })
    await expect(mismatched.updater.stage(mismatched.version)).rejects.toThrow(
      'Candidate version mismatch'
    )

    const invalid = await fixture({ checkFails: true })
    await expect(invalid.updater.stage(invalid.version)).rejects.toThrow('invalid candidate config')

    const wrongLayout = await fixture({ wrongArchiveLayout: true })
    await expect(wrongLayout.updater.stage(wrongLayout.version)).rejects.toThrow(
      `sing-box-${wrongLayout.version}-windows-amd64/sing-box.exe`
    )
  })

  it('expires staged updates instead of activating an indefinitely reusable token', async () => {
    let currentTime = 1_000
    const { updater, version } = await fixture({
      now: () => currentTime,
      stagedUpdateTtlMs: 100
    })
    const staged = await updater.stage(version)
    currentTime += 100
    await expect(updater.apply(staged.token)).rejects.toThrow('expired before activation')
    await expect(updater.apply(staged.token)).rejects.toThrow('missing or expired')
  })

  it('refuses activation if the selected core changed while the archive was staged', async () => {
    const { updater, version, coreDir } = await fixture()
    const staged = await updater.stage(version)
    const file = `sing-box-${version}-windows-amd64.exe`
    const contents = Buffer.from('different-selected-core')
    await writeFile(path.join(coreDir, file), contents)
    await writeFile(
      path.join(coreDir, CORE_SELECTION_FILE),
      JSON.stringify({
        schema: 1,
        active: {
          file,
          version,
          sha256: createHash('sha256').update(contents).digest('hex')
        },
        previous: 'bundled'
      })
    )

    await expect(updater.apply(staged.token)).rejects.toThrow(
      'active sing-box core changed while the update was being prepared'
    )
  })

  it('supports an explicit rollback while retaining the newer core for a later switch', async () => {
    const { updater, version, coreDir } = await fixture()
    const staged = await updater.stage(version)
    await updater.apply(staged.token)
    await updater.commitSelectionChange()
    const result = await updater.rollback()
    expect(result).toEqual({
      version: '1.0.0',
      previousVersion: version,
      rolledBack: true,
      canRollback: false
    })
    await expect(readFile(path.join(coreDir, CORE_SELECTION_FILE))).rejects.toMatchObject({
      code: 'ENOENT'
    })
    await updater.undoSelectionChange()
    const restored = JSON.parse(await readFile(path.join(coreDir, CORE_SELECTION_FILE), 'utf8'))
    expect(restored.active.version).toBe(version)
  })

  it('rejects non-Windows and non-x64 platforms before any network request', async () => {
    const { updater: _unused, ...base } = await fixture()
    const fetcher = vi.fn()
    const updater = createCoreUpdater({
      fetch: fetcher,
      platform: 'linux',
      arch: 'x64',
      coreDir: base.coreDir,
      bundledCorePath: path.join(path.dirname(base.coreDir), 'sing-box.exe'),
      elevated: false,
      execFile: base.exec
    })
    await expect(updater.check()).rejects.toThrow('Windows x64')
    expect(fetcher).not.toHaveBeenCalled()
  })

  it('refuses to activate AppData-managed executables in an elevated session', async () => {
    const { updater, version, coreDir } = await fixture({ elevated: true })
    await expect(updater.stage(version)).rejects.toThrow('require a non-elevated')
    await expect(readFile(path.join(coreDir, CORE_SELECTION_FILE))).rejects.toMatchObject({
      code: 'ENOENT'
    })
  })
})
