import path from 'path'

export const SINGBOX_CONFIG_NAME = 'sing-box.json'
export const SINGBOX_CANDIDATE_CONFIG_NAME = 'sing-box.candidate.json'
export const SINGBOX_LAST_GOOD_CONFIG_NAME = 'sing-box.last-good.json'
export const SINGBOX_REJECTED_CONFIG_NAME = 'sing-box.rejected.json'
export const RUNTIME_PROFILE_NAME = 'config.yaml'
export const RUNTIME_CANDIDATE_PROFILE_NAME = 'config.candidate.yaml'
export const RUNTIME_LAST_GOOD_PROFILE_NAME = 'config.last-good.yaml'
export const RUNTIME_REJECTED_PROFILE_NAME = 'config.rejected.yaml'

export type SingboxRecoverySlot = 'candidate' | 'last-good' | 'active'

export function singboxWorkConfigPath(workDir: string): string {
  return path.join(workDir, SINGBOX_CONFIG_NAME)
}

export function singboxCandidateConfigPath(workDir: string): string {
  return path.join(workDir, SINGBOX_CANDIDATE_CONFIG_NAME)
}

export function singboxLastGoodConfigPath(workDir: string): string {
  return path.join(workDir, SINGBOX_LAST_GOOD_CONFIG_NAME)
}

export function singboxRejectedConfigPath(workDir: string): string {
  return path.join(workDir, SINGBOX_REJECTED_CONFIG_NAME)
}

export function singboxRecoveryConfigPath(
  workDir: string,
  slot: SingboxRecoverySlot,
  port: number
): string {
  if (!['candidate', 'last-good', 'active'].includes(slot)) {
    throw new Error('Invalid sing-box recovery slot')
  }
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error('Invalid sing-box recovery port')
  }
  return path.join(workDir, `sing-box.recovery-${slot}-${port}.json`)
}

export function runtimeProfilePath(workDir: string): string {
  return path.join(workDir, RUNTIME_PROFILE_NAME)
}

export function runtimeCandidateProfilePath(workDir: string): string {
  return path.join(workDir, RUNTIME_CANDIDATE_PROFILE_NAME)
}

export function runtimeLastGoodProfilePath(workDir: string): string {
  return path.join(workDir, RUNTIME_LAST_GOOD_PROFILE_NAME)
}

export function runtimeRejectedProfilePath(workDir: string): string {
  return path.join(workDir, RUNTIME_REJECTED_PROFILE_NAME)
}
