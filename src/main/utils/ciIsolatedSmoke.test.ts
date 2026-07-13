import { describe, expect, it } from 'vitest'
import {
  assertIsolatedSmokeAllows,
  ELECTRON_PROD_SMOKE_TOKEN_VALUE,
  isCiIsolatedSmokeMode
} from './ciIsolatedSmoke'

const authorized = {
  CI: 'true',
  GITHUB_ACTIONS: 'true',
  RUNNER_OS: 'Windows',
  RUNNER_ENVIRONMENT: 'github-hosted',
  AIKOBOX_CI_ISOLATED_SMOKE: '1',
  AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN: ELECTRON_PROD_SMOKE_TOKEN_VALUE
}

describe('ciIsolatedSmoke gate', () => {
  it('accepts only a fully authorized GitHub-hosted Windows isolated smoke job', () => {
    expect(isCiIsolatedSmokeMode(authorized, 'win32')).toBe(true)
    expect(isCiIsolatedSmokeMode({ ...authorized, GITHUB_ACTIONS: 'false' }, 'win32')).toBe(false)
    expect(isCiIsolatedSmokeMode({ ...authorized, RUNNER_OS: 'Linux' }, 'win32')).toBe(false)
    expect(isCiIsolatedSmokeMode({ ...authorized, AIKOBOX_CI_ISOLATED_SMOKE: '0' }, 'win32')).toBe(
      false
    )
    expect(
      isCiIsolatedSmokeMode({ ...authorized, AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN: 'wrong' }, 'win32')
    ).toBe(false)
    expect(isCiIsolatedSmokeMode(authorized, 'linux')).toBe(false)
  })

  it('blocks forbidden actions only while the isolated gate is active', () => {
    const original = { ...process.env }
    try {
      for (const [key, value] of Object.entries(authorized)) {
        process.env[key] = value
      }
      expect(() => assertIsolatedSmokeAllows('startCore')).toThrow(
        /SYSTEM_SIDE_EFFECT_BLOCKED:isolated-smoke:startCore/
      )
      process.env.AIKOBOX_CI_ISOLATED_SMOKE = '0'
      expect(() => assertIsolatedSmokeAllows('startCore')).not.toThrow()
    } finally {
      for (const key of Object.keys(authorized)) {
        if (original[key] === undefined) delete process.env[key]
        else process.env[key] = original[key]
      }
    }
  })
})
