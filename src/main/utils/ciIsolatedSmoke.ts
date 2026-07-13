/**
 * Double-gated CI isolation for a future production main/preload Electron smoke.
 *
 * Never enable side effects unless every condition is true. This helper is pure
 * and unit-tested; production main should consult it before core/sysproxy/TUN.
 */

export const CI_ISOLATED_SMOKE_ENV = 'AIKOBOX_CI_ISOLATED_SMOKE'
export const ELECTRON_PROD_SMOKE_TOKEN_ENV = 'AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN'
export const ELECTRON_PROD_SMOKE_TOKEN_VALUE = 'aikobox-github-windows-electron-prod-smoke-v1'

export interface IsolatedSmokeEnv {
  CI?: string
  GITHUB_ACTIONS?: string
  RUNNER_OS?: string
  RUNNER_ENVIRONMENT?: string
  AIKOBOX_CI_ISOLATED_SMOKE?: string
  AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN?: string
  [key: string]: string | undefined
}

export function isCiIsolatedSmokeMode(
  env: IsolatedSmokeEnv = process.env,
  platform: NodeJS.Platform = process.platform
): boolean {
  return (
    platform === 'win32' &&
    env.CI === 'true' &&
    env.GITHUB_ACTIONS === 'true' &&
    env.RUNNER_OS === 'Windows' &&
    env.RUNNER_ENVIRONMENT === 'github-hosted' &&
    env.AIKOBOX_CI_ISOLATED_SMOKE === '1' &&
    env.AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN === ELECTRON_PROD_SMOKE_TOKEN_VALUE
  )
}

/** Surfaces that production main must refuse while isolated. */
export const ISOLATED_SMOKE_FORBIDDEN_ACTIONS = [
  'startCore',
  'triggerSysProxy',
  'setTunEnabled',
  'setupFirewall',
  'restartAsAdmin',
  'grantTunPermissions',
  'installCoreUpdate',
  'rollbackCoreUpdate',
  'recoverStaleSystemProxy',
  'child_process.spawn',
  'child_process.execFile'
] as const

export type IsolatedSmokeForbiddenAction = (typeof ISOLATED_SMOKE_FORBIDDEN_ACTIONS)[number]

export function assertIsolatedSmokeAllows(action: IsolatedSmokeForbiddenAction): void {
  if (!isCiIsolatedSmokeMode()) return
  throw new Error(`SYSTEM_SIDE_EFFECT_BLOCKED:isolated-smoke:${action}`)
}
