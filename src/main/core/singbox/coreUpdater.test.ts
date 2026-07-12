import { execFile } from 'child_process'
import { createHash } from 'crypto'
import { existsSync } from 'fs'
import { mkdtemp, readFile, rm, writeFile } from 'fs/promises'
import os from 'os'
import path from 'path'
import AdmZip from 'adm-zip'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { CORE_SELECTION_FILE } from './coreSelection'
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
  zip.addFile(`sing-box-${version}-windows-amd64/sing-box.exe`, Buffer.from('new-core'))
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
    execFile: exec
  })
  return { updater, coreDir, exec, version, archiveName }
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
  })

  it('parses only the checksum belonging to the exact archive', () => {
    const hash = 'a'.repeat(64)
    expect(
      parseChecksumFile(`${'b'.repeat(64)} other.zip\n${hash} *wanted.zip`, 'wanted.zip')
    ).toBe(hash)
    expect(() => parseChecksumFile(`${hash} almost-wanted.zip`, 'wanted.zip')).toThrow()
  })

  it('verifies archive SHA-256, version and check before atomically selecting it', async () => {
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
      previous: 'bundled'
    })
  })

  it('never creates an active selection when digest validation fails', async () => {
    const { updater, version, coreDir } = await fixture({ corruptChecksum: true })
    await expect(updater.stage(version)).rejects.toThrow('SHA-256')
    await expect(readFile(path.join(coreDir, CORE_SELECTION_FILE))).rejects.toMatchObject({
      code: 'ENOENT'
    })
  })

  it('prefers an official checksum asset over the GitHub asset digest', async () => {
    const { updater, version } = await fixture({
      checksumAsset: true,
      corruptChecksumAsset: true
    })
    await expect(updater.stage(version)).rejects.toThrow('SHA-256')
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
  })

  it('supports an explicit rollback while retaining the newer core for a later switch', async () => {
    const { updater, version, coreDir } = await fixture()
    const staged = await updater.stage(version)
    await updater.apply(staged.token)
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
