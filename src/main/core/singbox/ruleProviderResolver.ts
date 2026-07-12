import { parse } from '../../utils/yaml'
import { readProviderSource, type ProxyProviderResolveOptions } from './providerResolver'

type Dict = Record<string, unknown>

export interface RuleProviderResolveResult {
  config: Dict
  warnings: string[]
  errors: string[]
}

function asDict(value: unknown): Dict {
  return value && typeof value === 'object' && !Array.isArray(value) ? (value as Dict) : {}
}

function asArray(value: unknown): unknown[] {
  return Array.isArray(value) ? value : []
}

function payloadFromSource(provider: Dict, source?: string): string[] {
  if (String(provider.type || '').toLowerCase() === 'inline') {
    return asArray(provider.payload).map(String).filter(Boolean)
  }
  const parsed = parse<unknown>(source || '')
  if (Array.isArray(parsed)) return parsed.map(String).filter(Boolean)
  const payload = asArray(asDict(parsed).payload)
  if (payload.length > 0) return payload.map(String).filter(Boolean)

  // Classical text providers are also commonly distributed one rule per line.
  return (source || '')
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line && !line.startsWith('#'))
}

function appendTarget(rule: string, target: string): string {
  const parts = rule.split(',').map((part) => part.trim())
  if (parts.length < 2) throw new Error(`invalid classical rule "${rule}"`)
  if (parts[parts.length - 1].toLowerCase() === 'no-resolve') {
    return [...parts.slice(0, -1), target, 'no-resolve'].join(',')
  }
  return [...parts, target].join(',')
}

function expandPayload(
  providerName: string,
  provider: Dict,
  payload: string[],
  target: string
): string[] {
  const behavior = String(provider.behavior || 'classical').toLowerCase()
  if (behavior === 'classical') return payload.map((rule) => appendTarget(rule, target))
  if (behavior === 'domain') {
    return payload.map((entry) => {
      const value = entry.trim()
      if (value.startsWith('+.')) return `DOMAIN-SUFFIX,${value.slice(2)},${target}`
      if (value.startsWith('*.')) return `DOMAIN-SUFFIX,${value.slice(2)},${target}`
      if (value.startsWith('.')) return `DOMAIN-SUFFIX,${value.slice(1)},${target}`
      return `DOMAIN,${value},${target}`
    })
  }
  if (behavior === 'ipcidr') {
    return payload.map((entry) =>
      entry.includes(':') ? `IP-CIDR6,${entry},${target}` : `IP-CIDR,${entry},${target}`
    )
  }
  throw new Error(`rule-provider "${providerName}" has unsupported behavior "${behavior}"`)
}

export async function resolveRuleProviders(
  input: Dict,
  options: ProxyProviderResolveOptions
): Promise<RuleProviderResolveResult> {
  const config = structuredClone(input)
  const warnings: string[] = []
  const errors: string[] = []
  const definitions = asDict(config['rule-providers'])
  if (Object.keys(definitions).length === 0) return { config, warnings, errors }

  const rules = asArray(config.rules).map(String)
  const referenced = new Set<string>()
  for (const rule of rules) {
    const parts = rule.split(',').map((part) => part.trim())
    if (parts[0]?.toUpperCase() === 'RULE-SET' && parts[1]) referenced.add(parts[1])
  }

  const payloads = new Map<string, string[]>()
  for (const name of referenced) {
    const provider = asDict(definitions[name])
    if (Object.keys(provider).length === 0) {
      errors.push(`rule-provider "${name}" is referenced but not defined`)
      continue
    }
    const configuredPath = String(provider.path || provider.url || '')
    if (/\.mrs(?:$|\?)/i.test(configuredPath)) {
      errors.push(`rule-provider "${name}" uses MRS, which cannot be converted to sing-box safely`)
      continue
    }
    try {
      const source =
        String(provider.type || '').toLowerCase() === 'inline'
          ? undefined
          : await readProviderSource(
              name,
              provider,
              options,
              warnings,
              (content) => {
                if (payloadFromSource(provider, content).length === 0) {
                  throw new Error('provider payload is empty')
                }
              },
              'rule'
            )
      const payload = payloadFromSource(provider, source)
      if (payload.length === 0) throw new Error('provider payload is empty')
      payloads.set(name, payload)
    } catch (error) {
      errors.push(`rule-provider "${name}" could not be loaded: ${String(error)}`)
    }
  }

  const expanded: string[] = []
  for (const rule of rules) {
    const parts = rule.split(',').map((part) => part.trim())
    if (parts[0]?.toUpperCase() !== 'RULE-SET') {
      expanded.push(rule)
      continue
    }
    const [, providerName, target] = parts
    if (!providerName || !target) {
      errors.push(`invalid RULE-SET rule "${rule}"`)
      continue
    }
    const provider = asDict(definitions[providerName])
    const payload = payloads.get(providerName)
    if (!payload) continue
    try {
      expanded.push(...expandPayload(providerName, provider, payload, target))
    } catch (error) {
      errors.push(String(error))
    }
  }

  config.rules = expanded
  delete config['rule-providers']
  return { config, warnings, errors }
}
