/* eslint-disable import/order -- Vitest mocks must be installed before the module under test. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({
  getProfileConfig: vi.fn(),
  getAppConfig: vi.fn(),
  getProfileItem: vi.fn(),
  getProfile: vi.fn(),
  getOverrideConfig: vi.fn(),
  getOverrideItem: vi.fn(),
  getOverride: vi.fn(),
  getControledMihomoConfig: vi.fn(),
  getHealthyProxyEndpoint: vi.fn(),
  resolveProxyProviders: vi.fn(),
  resolveRuleProviders: vi.fn(),
  convertClashToSingbox: vi.fn(),
  mkdir: vi.fn(),
  writeFile: vi.fn(),
  readFile: vi.fn(),
  mihomoProfileWorkDir: vi.fn(),
  mihomoWorkDir: vi.fn(),
  dataDir: vi.fn(),
  rulePath: vi.fn(),
  warn: vi.fn(),
  error: vi.fn(),
  info: vi.fn()
}))

vi.mock('fs/promises', () => ({
  mkdir: mocks.mkdir,
  writeFile: mocks.writeFile,
  readFile: mocks.readFile
}))

vi.mock('fs', () => ({
  existsSync: vi.fn(() => false)
}))

vi.mock('../config', () => ({
  getProfileConfig: mocks.getProfileConfig,
  getAppConfig: mocks.getAppConfig,
  getProfileItem: mocks.getProfileItem,
  getProfile: mocks.getProfile,
  getOverrideConfig: mocks.getOverrideConfig,
  getOverrideItem: mocks.getOverrideItem,
  getOverride: mocks.getOverride,
  getControledMihomoConfig: mocks.getControledMihomoConfig
}))

vi.mock('../utils/dirs', () => ({
  mihomoProfileWorkDir: mocks.mihomoProfileWorkDir,
  mihomoWorkDir: mocks.mihomoWorkDir,
  dataDir: mocks.dataDir,
  rulePath: mocks.rulePath
}))

vi.mock('../utils/logger', () => ({
  createLogger: () => ({
    warn: mocks.warn,
    error: mocks.error,
    info: mocks.info,
    debug: vi.fn()
  })
}))

vi.mock('./healthyProxyEndpoint', () => ({
  getHealthyProxyEndpoint: mocks.getHealthyProxyEndpoint
}))

vi.mock('./singbox/providerResolver', () => ({
  resolveProxyProviders: mocks.resolveProxyProviders
}))

vi.mock('./singbox/ruleProviderResolver', () => ({
  resolveRuleProviders: mocks.resolveRuleProviders
}))

vi.mock('./singbox/convert', () => ({
  convertClashToSingbox: mocks.convertClashToSingbox
}))

vi.mock('./singbox', () => ({
  runtimeCandidateProfilePath: (dir: string) => `${dir}/runtime-candidate.yaml`,
  singboxCandidateConfigPath: (dir: string) => `${dir}/singbox-candidate.json`
}))

import {
  discardPendingRuntimeConfig,
  generateProfile,
  getPendingRuntimeConfig,
  getRuntimeConfig,
  getRuntimeConfigStr,
  promotePendingRuntimeConfig,
  restoreRuntimeConfig
} from './factory'

function baseConfigMocks(): void {
  mocks.getProfileConfig.mockResolvedValue({ current: 'profile-1' })
  mocks.getAppConfig.mockResolvedValue({
    diffWorkDir: false,
    controlDns: true,
    controlSniff: true,
    useNameserverPolicy: false,
    userAgent: 'AikoBox-Test'
  })
  mocks.getProfileItem.mockResolvedValue({
    type: 'remote',
    url: 'https://example.test/sub',
    useProxy: false
  })
  mocks.getProfile.mockResolvedValue({
    proxies: [{ name: 'local', type: 'socks5', server: '127.0.0.1', port: 1080 }],
    'proxy-groups': [{ name: 'PROXY', type: 'select', proxies: ['local'] }],
    rules: ['MATCH,PROXY']
  })
  mocks.getOverrideConfig.mockResolvedValue({ items: [] })
  mocks.getControledMihomoConfig.mockResolvedValue({})
  mocks.getHealthyProxyEndpoint.mockReturnValue(undefined)
  mocks.mihomoWorkDir.mockReturnValue('C:/tmp/aikobox-work')
  mocks.dataDir.mockReturnValue('C:/tmp/aikobox-data')
  mocks.mkdir.mockResolvedValue(undefined)
  mocks.writeFile.mockResolvedValue(undefined)
  mocks.resolveProxyProviders.mockResolvedValue({
    config: {
      proxies: [{ name: 'local', type: 'socks5', server: '127.0.0.1', port: 1080 }],
      'proxy-groups': [{ name: 'PROXY', type: 'select', proxies: ['local'] }],
      rules: ['MATCH,PROXY']
    },
    warnings: [],
    errors: []
  })
  mocks.resolveRuleProviders.mockResolvedValue({
    config: {
      proxies: [{ name: 'local', type: 'socks5', server: '127.0.0.1', port: 1080 }],
      'proxy-groups': [{ name: 'PROXY', type: 'select', proxies: ['local'] }],
      rules: ['MATCH,PROXY']
    },
    warnings: [],
    errors: []
  })
  mocks.convertClashToSingbox.mockReturnValue({
    config: { log: { level: 'info' }, outbounds: [] },
    warnings: [],
    errors: []
  })
}

describe('factory generateProfile pipeline', () => {
  beforeEach(() => {
    discardPendingRuntimeConfig()
    restoreRuntimeConfig(undefined)
    vi.clearAllMocks()
    baseConfigMocks()
  })

  afterEach(() => {
    discardPendingRuntimeConfig()
  })

  it('throws proxy-provider errors before convert and does not write candidates', async () => {
    mocks.resolveProxyProviders.mockResolvedValue({
      config: {},
      warnings: [],
      errors: ['provider a failed']
    })

    await expect(generateProfile()).rejects.toThrow(
      /Proxy providers cannot be resolved safely:[\s\S]*provider a failed/
    )
    expect(mocks.resolveRuleProviders).not.toHaveBeenCalled()
    expect(mocks.convertClashToSingbox).not.toHaveBeenCalled()
    expect(mocks.writeFile).not.toHaveBeenCalled()
  })

  it('throws rule-provider errors before convert after proxy providers succeed', async () => {
    mocks.resolveRuleProviders.mockResolvedValue({
      config: {},
      warnings: [],
      errors: ['rule-set b failed']
    })

    await expect(generateProfile()).rejects.toThrow(
      /Rule providers cannot be resolved safely:[\s\S]*rule-set b failed/
    )
    expect(mocks.resolveProxyProviders).toHaveBeenCalledOnce()
    expect(mocks.convertClashToSingbox).not.toHaveBeenCalled()
    expect(mocks.writeFile).not.toHaveBeenCalled()
  })

  it('throws joined convert errors and keeps runtime config unpromoted', async () => {
    mocks.convertClashToSingbox.mockReturnValue({
      config: {},
      warnings: ['warn-1'],
      errors: ['bad proxy', 'bad rule']
    })

    await expect(generateProfile()).rejects.toThrow(
      /Configuration cannot be converted safely:[\s\S]*bad proxy[\s\S]*bad rule/
    )
    expect(mocks.writeFile).not.toHaveBeenCalled()
    expect(getPendingRuntimeConfig()).toBeNull()
    promotePendingRuntimeConfig()
    await expect(getRuntimeConfigStr()).resolves.toBe('')
  })

  it('writes candidates and promotes pending runtime only after success path', async () => {
    const current = await generateProfile()
    expect(current).toBe('profile-1')
    expect(mocks.convertClashToSingbox).toHaveBeenCalledOnce()
    expect(mocks.writeFile).toHaveBeenCalledTimes(2)
    expect(getPendingRuntimeConfig()?.proxies?.[0]?.name).toBe('local')

    // Pending until promote — committed runtime stays empty/old until promote.
    await expect(getRuntimeConfigStr()).resolves.toBe('')
    promotePendingRuntimeConfig()
    expect(getPendingRuntimeConfig()).toBeNull()
    const after = await getRuntimeConfig()
    expect(after.proxies?.[0]?.name).toBe('local')
    await expect(getRuntimeConfigStr()).resolves.toMatch(/local/)
  })
})
