import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { convertClashToSingbox } from './convert'
import { resolveRuleProviders } from './ruleProviderResolver'

let root = ''

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), 'aikobox-rule-provider-'))
})

afterEach(() => {
  rmSync(root, { recursive: true, force: true })
})

describe('rule provider resolver', () => {
  it('expands domain and IP-CIDR providers before pure conversion', async () => {
    const result = await resolveRuleProviders(
      {
        proxies: [
          {
            name: 'Proxy',
            type: 'ss',
            server: '192.0.2.1',
            port: 443,
            cipher: 'aes-128-gcm',
            password: 'x'
          }
        ],
        'rule-providers': {
          domains: { type: 'inline', behavior: 'domain', payload: ['+.example.com'] },
          networks: { type: 'inline', behavior: 'ipcidr', payload: ['10.0.0.0/8', '2001:db8::/32'] }
        },
        rules: ['RULE-SET,domains,Proxy', 'RULE-SET,networks,DIRECT', 'MATCH,Proxy']
      },
      { baseDir: root, cacheDir: join(root, 'cache') }
    )

    expect(result.errors).toEqual([])
    expect(result.config.rules).toEqual([
      'DOMAIN-SUFFIX,example.com,Proxy',
      'IP-CIDR,10.0.0.0/8,DIRECT',
      'IP-CIDR6,2001:db8::/32,DIRECT',
      'MATCH,Proxy'
    ])
    expect(convertClashToSingbox(result.config).errors).toEqual([])
  })

  it('expands classical no-resolve rules with the target in the correct position', async () => {
    const result = await resolveRuleProviders(
      {
        'rule-providers': {
          classic: {
            type: 'inline',
            behavior: 'classical',
            payload: ['IP-CIDR,10.0.0.0/8,no-resolve']
          }
        },
        rules: ['RULE-SET,classic,DIRECT']
      },
      { baseDir: root, cacheDir: join(root, 'cache') }
    )
    expect(result.config.rules).toEqual(['IP-CIDR,10.0.0.0/8,DIRECT,no-resolve'])
  })

  it('rejects MRS instead of silently skipping it', async () => {
    const result = await resolveRuleProviders(
      {
        'rule-providers': {
          mrs: { type: 'http', behavior: 'domain', url: 'https://example.invalid/rules.mrs' }
        },
        rules: ['RULE-SET,mrs,DIRECT']
      },
      { baseDir: root, cacheDir: join(root, 'cache') }
    )
    expect(result.errors.join('\n')).toMatch(/MRS/)
  })

  it('rejects file rule providers that escape the profile directory', async () => {
    const baseDir = join(root, 'profile')
    mkdirSync(baseDir)
    writeFileSync(join(root, 'outside.yaml'), 'payload:\n  - +.example.com\n')
    const result = await resolveRuleProviders(
      {
        'rule-providers': {
          unsafe: { type: 'file', behavior: 'domain', path: '..\\outside.yaml' }
        },
        rules: ['RULE-SET,unsafe,DIRECT']
      },
      { baseDir, cacheDir: join(root, 'cache'), allowFileProviders: true }
    )

    expect(result.errors.join('\n')).toMatch(/escapes/)
    expect(result.config.rules).toEqual([])
  })
})
