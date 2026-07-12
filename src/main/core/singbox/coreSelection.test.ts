import { createHash } from 'crypto'
import { mkdtemp, rm, writeFile } from 'fs/promises'
import path from 'path'
import os from 'os'
import { afterEach, describe, expect, it } from 'vitest'
import {
  CORE_SELECTION_FILE,
  managedCoreFilename,
  parseCoreSelectionManifest,
  resolveVerifiedManagedCorePath
} from './coreSelection'

const tempDirs: string[] = []

afterEach(async () => {
  await Promise.all(tempDirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
})

describe('managed sing-box core selection', () => {
  it('fails closed to the bundled core for traversal, mismatch, or truncated manifests', () => {
    expect(
      parseCoreSelectionManifest({
        schema: 1,
        active: {
          file: '../sing-box.exe',
          version: '1.13.14',
          sha256: 'a'.repeat(64)
        }
      })
    ).toBeNull()
    expect(
      parseCoreSelectionManifest({
        schema: 1,
        active: {
          file: 'sing-box-1.13.15-windows-amd64.exe',
          version: '1.13.14',
          sha256: 'a'.repeat(64)
        }
      })
    ).toBeNull()
  })

  it('never resolves an AppData-managed executable for an elevated process', async () => {
    const coreDir = await mkdtemp(path.join(os.tmpdir(), 'aikobox-core-admin-'))
    tempDirs.push(coreDir)
    const file = managedCoreFilename('1.13.14')
    const contents = Buffer.from('managed-core')
    await writeFile(path.join(coreDir, file), contents)
    await writeFile(
      path.join(coreDir, CORE_SELECTION_FILE),
      JSON.stringify({
        schema: 1,
        active: {
          file,
          version: '1.13.14',
          sha256: createHash('sha256').update(contents).digest('hex')
        }
      })
    )
    const exec = async (): Promise<{ stdout: string; stderr: string }> => {
      throw new Error('must not execute')
    }

    await expect(
      resolveVerifiedManagedCorePath(coreDir, { elevated: true, execFile: exec })
    ).resolves.toBeNull()
  })

  it('warns and rejects a managed executable whose content was tampered with', async () => {
    const coreDir = await mkdtemp(path.join(os.tmpdir(), 'aikobox-core-tamper-'))
    tempDirs.push(coreDir)
    const file = managedCoreFilename('1.13.14')
    const original = Buffer.from('verified-core')
    await writeFile(path.join(coreDir, file), original)
    await writeFile(
      path.join(coreDir, CORE_SELECTION_FILE),
      JSON.stringify({
        schema: 1,
        active: {
          file,
          version: '1.13.14',
          sha256: createHash('sha256').update(original).digest('hex')
        }
      })
    )
    await writeFile(path.join(coreDir, file), 'tampered-core')
    const warnings: string[] = []
    let executed = false

    await expect(
      resolveVerifiedManagedCorePath(coreDir, {
        elevated: false,
        execFile: async () => {
          executed = true
          return { stdout: 'sing-box version 1.13.14', stderr: '' }
        },
        warn: (message) => warnings.push(message)
      })
    ).resolves.toBeNull()
    expect(executed).toBe(false)
    expect(warnings.join('\n')).toContain('SHA-256 mismatch')
  })

  it('accepts a non-elevated managed core only after hash, identity, and version checks', async () => {
    const coreDir = await mkdtemp(path.join(os.tmpdir(), 'aikobox-core-verified-'))
    tempDirs.push(coreDir)
    const file = managedCoreFilename('1.13.14')
    const contents = Buffer.from('verified-core')
    await writeFile(path.join(coreDir, file), contents)
    await writeFile(
      path.join(coreDir, CORE_SELECTION_FILE),
      JSON.stringify({
        schema: 1,
        active: {
          file,
          version: '1.13.14',
          sha256: createHash('sha256').update(contents).digest('hex')
        }
      })
    )

    const resolved = await resolveVerifiedManagedCorePath(coreDir, {
      elevated: false,
      execFile: async (executable, args) => {
        expect(executable).toBe(path.join(coreDir, file))
        expect(args).toEqual(['version'])
        return { stdout: 'sing-box version 1.13.14', stderr: '' }
      }
    })
    expect(resolved?.path).toBe(path.join(coreDir, file))
  })
})
