import { existsSync } from 'fs'
import { readFile, rm } from 'fs/promises'
import { writeFileAtomically } from '../../config/remoteResource'
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

async function replaceFileAtomically(source: string, target: string): Promise<void> {
  await writeFileAtomically(target, await readFile(source, 'utf8'))
}

export async function promoteCandidateConfig(workDir: string): Promise<void> {
  const active = singboxWorkConfigPath(workDir)
  const candidate = singboxCandidateConfigPath(workDir)
  const lastGood = singboxLastGoodConfigPath(workDir)
  const runtimeActive = runtimeProfilePath(workDir)
  const runtimeCandidate = runtimeCandidateProfilePath(workDir)
  const runtimeLastGood = runtimeLastGoodProfilePath(workDir)
  if (!existsSync(candidate)) throw new Error('Converted sing-box candidate config is missing')
  if (!existsSync(runtimeCandidate)) throw new Error('Converted Clash runtime candidate is missing')

  if (!existsSync(lastGood) && existsSync(active)) {
    await replaceFileAtomically(active, lastGood)
  }
  if (!existsSync(runtimeLastGood) && existsSync(runtimeActive)) {
    await replaceFileAtomically(runtimeActive, runtimeLastGood)
  }
  await replaceFileAtomically(candidate, active)
  await replaceFileAtomically(runtimeCandidate, runtimeActive)
  await rm(candidate, { force: true })
  await rm(runtimeCandidate, { force: true })
}

export async function markActiveConfigGood(workDir: string): Promise<void> {
  const active = singboxWorkConfigPath(workDir)
  if (!existsSync(active)) return
  await replaceFileAtomically(active, singboxLastGoodConfigPath(workDir))
  const runtimeActive = runtimeProfilePath(workDir)
  if (existsSync(runtimeActive)) {
    await replaceFileAtomically(runtimeActive, runtimeLastGoodProfilePath(workDir))
  }
}

export interface RestoredLastGoodConfig {
  config: Record<string, unknown>
  runtimeProfile?: string
}

export async function restoreLastGoodConfig(
  workDir: string,
  options: { retainActiveAsRejected?: boolean } = {}
): Promise<RestoredLastGoodConfig | null> {
  const active = singboxWorkConfigPath(workDir)
  const lastGood = singboxLastGoodConfigPath(workDir)
  if (!existsSync(lastGood)) return null

  if (options.retainActiveAsRejected !== false && existsSync(active)) {
    await replaceFileAtomically(active, singboxRejectedConfigPath(workDir)).catch(() => {})
  }
  await replaceFileAtomically(lastGood, active)

  const runtimeActive = runtimeProfilePath(workDir)
  const runtimeLastGood = runtimeLastGoodProfilePath(workDir)
  let runtimeProfile: string | undefined
  if (existsSync(runtimeLastGood)) {
    if (options.retainActiveAsRejected !== false && existsSync(runtimeActive)) {
      await replaceFileAtomically(runtimeActive, runtimeRejectedProfilePath(workDir)).catch(
        () => {}
      )
    }
    await replaceFileAtomically(runtimeLastGood, runtimeActive)
    runtimeProfile = await readFile(runtimeActive, 'utf8')
  }

  return {
    config: JSON.parse(await readFile(active, 'utf8')) as Record<string, unknown>,
    runtimeProfile
  }
}
