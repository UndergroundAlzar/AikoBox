import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import {
  singboxCandidateConfigPath,
  singboxLastGoodConfigPath,
  singboxRejectedConfigPath,
  singboxWorkConfigPath,
  runtimeCandidateProfilePath,
  runtimeLastGoodProfilePath,
  runtimeProfilePath,
  runtimeRejectedProfilePath
} from './configPaths'
import { markActiveConfigGood, promoteCandidateConfig, restoreLastGoodConfig } from './configStore'

let workDir = ''
const config = (name: string): string => JSON.stringify({ name })

beforeEach(() => {
  workDir = mkdtempSync(join(tmpdir(), 'aikobox-config-store-'))
})

afterEach(() => {
  rmSync(workDir, { recursive: true, force: true })
})

describe('sing-box config store', () => {
  it('promotes a candidate while seeding the previous active config as LKG', async () => {
    writeFileSync(singboxWorkConfigPath(workDir), config('old'))
    writeFileSync(singboxCandidateConfigPath(workDir), config('candidate'))
    writeFileSync(runtimeProfilePath(workDir), 'name: old\n')
    writeFileSync(runtimeCandidateProfilePath(workDir), 'name: candidate\n')

    await promoteCandidateConfig(workDir)

    expect(JSON.parse(readFileSync(singboxWorkConfigPath(workDir), 'utf8')).name).toBe('candidate')
    expect(JSON.parse(readFileSync(singboxLastGoodConfigPath(workDir), 'utf8')).name).toBe('old')
    expect(readFileSync(runtimeProfilePath(workDir), 'utf8')).toBe('name: candidate\n')
    expect(readFileSync(runtimeLastGoodProfilePath(workDir), 'utf8')).toBe('name: old\n')
  })

  it('marks a healthy active config as last-known-good', async () => {
    writeFileSync(singboxWorkConfigPath(workDir), config('healthy'))
    writeFileSync(runtimeProfilePath(workDir), 'name: healthy\n')
    await markActiveConfigGood(workDir)
    expect(JSON.parse(readFileSync(singboxLastGoodConfigPath(workDir), 'utf8')).name).toBe(
      'healthy'
    )
    expect(readFileSync(runtimeLastGoodProfilePath(workDir), 'utf8')).toBe('name: healthy\n')
  })

  it('restores LKG and retains the rejected config for diagnostics', async () => {
    writeFileSync(singboxWorkConfigPath(workDir), config('bad'))
    writeFileSync(singboxLastGoodConfigPath(workDir), config('good'))
    writeFileSync(runtimeProfilePath(workDir), 'name: bad\n')
    writeFileSync(runtimeLastGoodProfilePath(workDir), 'name: good\n')

    const restored = await restoreLastGoodConfig(workDir)

    expect(restored?.config.name).toBe('good')
    expect(restored?.runtimeProfile).toBe('name: good\n')
    expect(JSON.parse(readFileSync(singboxWorkConfigPath(workDir), 'utf8')).name).toBe('good')
    expect(JSON.parse(readFileSync(singboxRejectedConfigPath(workDir), 'utf8')).name).toBe('bad')
    expect(readFileSync(runtimeRejectedProfilePath(workDir), 'utf8')).toBe('name: bad\n')
  })

  it('restores a cold-start LKG without mislabeling the previous active snapshot', async () => {
    writeFileSync(singboxWorkConfigPath(workDir), config('previous-active'))
    writeFileSync(singboxLastGoodConfigPath(workDir), config('good'))
    writeFileSync(runtimeProfilePath(workDir), 'name: previous-active\n')
    writeFileSync(runtimeLastGoodProfilePath(workDir), 'name: good\n')

    const restored = await restoreLastGoodConfig(workDir, { retainActiveAsRejected: false })

    expect(restored?.config.name).toBe('good')
    expect(() => readFileSync(singboxRejectedConfigPath(workDir), 'utf8')).toThrow()
    expect(() => readFileSync(runtimeRejectedProfilePath(workDir), 'utf8')).toThrow()
  })
})
