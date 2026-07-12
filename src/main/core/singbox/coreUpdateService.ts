import { execFile } from 'child_process'
import path from 'path'
import { promisify } from 'util'
import { net } from 'electron'
import { dataDir } from '../../utils/dirs'
import { createLogger } from '../../utils/logger'
import { getSessionAdminStatus } from '../permissions'
import {
  resolveVerifiedManagedCorePath,
  resolveVerifiedPendingManagedCorePath,
  type VerifyManagedCoreOptions
} from './coreSelection'
import {
  createCoreUpdater,
  type CoreReleaseInfo,
  type CoreUpdateResult,
  type StagedCoreUpdate
} from './coreUpdater'
import { singboxBundledCorePath } from '.'

const logger = createLogger('CoreUpdater')
const execFilePromise = promisify(execFile)

let coreUpdater: ReturnType<typeof createCoreUpdater> | null = null

function updater(): ReturnType<typeof createCoreUpdater> {
  coreUpdater ??= createCoreUpdater({
    fetch: (input, init) => net.fetch(input, init),
    platform: process.platform,
    arch: process.arch,
    coreDir: path.join(dataDir(), 'core'),
    bundledCorePath: singboxBundledCorePath(),
    elevated: getSessionAdminStatus(),
    warn: (message) => logger.warn(message)
  })
  return coreUpdater
}

export async function checkCoreUpdate(): Promise<CoreReleaseInfo> {
  return updater().check()
}

/**
 * The only supported entry point for opting into an AppData-managed core.
 * Elevated sessions always resolve to the installation-owned bundled binary.
 */
export async function resolveSingboxCorePathForExecution(): Promise<string> {
  const bundled = singboxBundledCorePath()
  const coreDir = path.join(dataDir(), 'core')
  const verification: VerifyManagedCoreOptions = {
    elevated: getSessionAdminStatus(),
    execFile: async (file, args) =>
      (await execFilePromise(file, [...args], {
        timeout: 15_000,
        windowsHide: true,
        maxBuffer: 1024 * 1024
      })) as { stdout: string; stderr: string },
    warn: (message) => logger.warn(message)
  }
  const pending = updater().getPendingValidationSelection()
  if (pending) {
    // Only the updater instance that staged this exact candidate can take this
    // path. A fresh process has no in-memory authorization and resolves the
    // manifest's last-known-good selection instead.
    return (await resolveVerifiedPendingManagedCorePath(coreDir, pending, verification)).path
  }
  const managed = await resolveVerifiedManagedCorePath(coreDir, verification)
  return managed?.path ?? bundled
}

export async function stageCoreUpdate(version: string): Promise<StagedCoreUpdate> {
  logger.info(`User requested download and verification of sing-box ${version}`)
  const result = await updater().stage(version)
  logger.info(`sing-box ${result.version} is staged and verified`)
  return result
}

/** Manager-only: call after its serialized stop and proxy-safety sequence. */
export async function applyStagedCoreUpdate(token: string): Promise<CoreUpdateResult> {
  const result = await updater().apply(token)
  logger.info(`sing-box selection changed from ${result.previousVersion} to ${result.version}`)
  return result
}

/** Manager-only: call after its serialized stop and proxy-safety sequence. */
export async function rollbackCoreUpdateSelection(): Promise<CoreUpdateResult> {
  const result = await updater().rollback()
  logger.info(`sing-box selection rolled back from ${result.previousVersion} to ${result.version}`)
  return result
}

export async function undoCoreUpdateSelectionChange(): Promise<void> {
  await updater().undoSelectionChange()
}

export async function commitCoreUpdateSelectionChange(): Promise<void> {
  await updater().commitSelectionChange()
}
