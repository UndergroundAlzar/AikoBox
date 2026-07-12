import { execFile } from 'child_process'
import { readFile, writeFile } from 'fs/promises'
import { isIP } from 'net'
import { promisify } from 'util'

const execFilePromise = promisify(execFile)

interface NetworkRange {
  version: 4 | 6
  prefixLength: number
  start: bigint
  end: bigint
}

export interface TunAddressDecision {
  addresses: string[]
  changes: Array<{ from: string; to: string }>
}

const DEFAULT_TUN_IPV4_ADDRESS = '198.19.0.1/30'
const DEFAULT_TUN_IPV6_ADDRESS = 'fdfe:dcba:9876::1/126'

function ipv4ToBigInt(address: string): bigint | null {
  const parts = address.split('.')
  if (parts.length !== 4) return null
  let value = 0n
  for (const part of parts) {
    if (!/^\d+$/.test(part)) return null
    const octet = Number(part)
    if (!Number.isInteger(octet) || octet < 0 || octet > 255) return null
    value = (value << 8n) | BigInt(octet)
  }
  return value
}

function ipv6ToBigInt(address: string): bigint | null {
  const withoutZone = address.split('%')[0].toLowerCase()
  if (withoutZone.split('::').length > 2) return null

  const convertEmbeddedIpv4 = (parts: string[]): string[] | null => {
    if (parts.length === 0 || !parts[parts.length - 1].includes('.')) return parts
    const ipv4 = ipv4ToBigInt(parts[parts.length - 1])
    if (ipv4 === null) return null
    return [
      ...parts.slice(0, -1),
      ((ipv4 >> 16n) & 0xffffn).toString(16),
      (ipv4 & 0xffffn).toString(16)
    ]
  }

  const [leftRaw, rightRaw] = withoutZone.split('::')
  const left = convertEmbeddedIpv4(leftRaw ? leftRaw.split(':') : [])
  const right = convertEmbeddedIpv4(rightRaw ? rightRaw.split(':') : [])
  if (!left || !right) return null

  const hasCompression = withoutZone.includes('::')
  const missing = 8 - left.length - right.length
  if ((hasCompression && missing < 1) || (!hasCompression && missing !== 0)) return null
  const parts = [...left, ...Array(hasCompression ? missing : 0).fill('0'), ...right]
  if (parts.length !== 8) return null

  let value = 0n
  for (const part of parts) {
    if (!/^[0-9a-f]{1,4}$/.test(part)) return null
    value = (value << 16n) | BigInt(`0x${part}`)
  }
  return value
}

export function parseNetworkRange(cidr: string): NetworkRange | null {
  const trimmed = cidr.trim()
  const slash = trimmed.lastIndexOf('/')
  if (slash <= 0) return null
  const address = trimmed.slice(0, slash)
  const prefixLength = Number(trimmed.slice(slash + 1))
  const version = isIP(address)
  if ((version !== 4 && version !== 6) || !Number.isInteger(prefixLength)) return null
  const bits = version === 4 ? 32 : 128
  if (prefixLength < 0 || prefixLength > bits) return null
  const raw = version === 4 ? ipv4ToBigInt(address) : ipv6ToBigInt(address)
  if (raw === null) return null

  const hostBits = BigInt(bits - prefixLength)
  const hostMask = hostBits === 0n ? 0n : (1n << hostBits) - 1n
  const start = raw & ~hostMask
  return {
    version,
    prefixLength,
    start,
    end: start + hostMask
  }
}

export function networkRangesOverlap(leftCidr: string, rightCidr: string): boolean {
  const left = parseNetworkRange(leftCidr)
  const right = parseNetworkRange(rightCidr)
  if (!left || !right || left.version !== right.version) return false
  return left.start <= right.end && right.start <= left.end
}

function sameNetwork(leftCidr: string, rightCidr: string): boolean {
  const left = parseNetworkRange(leftCidr)
  const right = parseNetworkRange(rightCidr)
  return Boolean(
    left &&
    right &&
    left.version === right.version &&
    left.prefixLength === right.prefixLength &&
    left.start === right.start
  )
}

function ipv4FromBigInt(value: bigint): string {
  return [24n, 16n, 8n, 0n].map((shift) => Number((value >> shift) & 0xffn)).join('.')
}

function findFreeDefaultAddress(version: 4 | 6, occupied: string[]): string | null {
  if (version === 4) {
    const first = ipv4ToBigInt('198.18.0.0')
    const last = ipv4ToBigInt('198.19.255.252')
    if (first === null || last === null) return null
    for (let network = last; network >= first; network -= 4n) {
      const candidate = `${ipv4FromBigInt(network + 1n)}/30`
      if (!occupied.some((prefix) => networkRangesOverlap(candidate, prefix))) return candidate
    }
    return null
  }

  // Keep alternatives in the same private ULA hierarchy and deterministic so
  // restarts do not churn the interface address.
  for (let suffix = 0x9875; suffix >= 0x9776; suffix--) {
    const candidate = `fdfe:dcba:${suffix.toString(16)}::1/126`
    if (!occupied.some((prefix) => networkRangesOverlap(candidate, prefix))) return candidate
  }
  return null
}

export function chooseSafeTunAddresses(
  addresses: string[],
  occupiedPrefixes: string[],
  explicitAddresses: string[] = [],
  activeAddresses: string[] = []
): TunAddressDecision {
  const occupied = occupiedPrefixes.filter((prefix) => {
    const range = parseNetworkRange(prefix)
    return range !== null && range.prefixLength !== 0
  })
  const changes: TunAddressDecision['changes'] = []
  const selected: string[] = []

  for (const address of addresses) {
    const range = parseNetworkRange(address)
    if (!range) throw new Error(`Invalid TUN address: ${address}`)
    const isAlreadyActive = activeAddresses.some((active) => sameNetwork(address, active))
    const conflicts = occupied.some((prefix) => networkRangesOverlap(address, prefix))

    if (!conflicts || isAlreadyActive) {
      selected.push(address)
      continue
    }

    const isExplicit = explicitAddresses.some((explicit) => sameNetwork(address, explicit))
    const isDefault =
      sameNetwork(address, DEFAULT_TUN_IPV4_ADDRESS) ||
      sameNetwork(address, DEFAULT_TUN_IPV6_ADDRESS)
    if (isExplicit || !isDefault) {
      throw new Error(
        `TUN address ${address} overlaps an existing Windows route. Choose a different TUN address before enabling TUN.`
      )
    }

    const replacement = findFreeDefaultAddress(range.version, occupied)
    if (!replacement) {
      throw new Error(
        `No conflict-free ${range.version === 4 ? 'IPv4' : 'IPv6'} TUN address is available in AikoBox's reserved pool.`
      )
    }
    selected.push(replacement)
    occupied.push(replacement)
    changes.push({ from: address, to: replacement })
  }

  return { addresses: selected, changes }
}

function extractTunAddresses(config: unknown): string[] {
  if (!config || typeof config !== 'object') return []
  const inbounds = (config as { inbounds?: unknown }).inbounds
  if (!Array.isArray(inbounds)) return []
  const tun = inbounds.find(
    (inbound) =>
      inbound && typeof inbound === 'object' && (inbound as { type?: unknown }).type === 'tun'
  ) as { address?: unknown } | undefined
  if (!tun) return []
  return Array.isArray(tun.address)
    ? tun.address.filter((item): item is string => typeof item === 'string')
    : typeof tun.address === 'string'
      ? [tun.address]
      : []
}

function setTunAddresses(config: unknown, addresses: string[]): void {
  if (!config || typeof config !== 'object') return
  const inbounds = (config as { inbounds?: unknown }).inbounds
  if (!Array.isArray(inbounds)) return
  const tun = inbounds.find(
    (inbound) =>
      inbound && typeof inbound === 'object' && (inbound as { type?: unknown }).type === 'tun'
  ) as { address?: unknown } | undefined
  if (tun) tun.address = addresses
}

function toStringArray(value: unknown): string[] {
  if (typeof value === 'string') return value.trim() ? [value.trim()] : []
  if (!Array.isArray(value)) return []
  return value
    .filter((item): item is string => typeof item === 'string')
    .map((item) => item.trim())
    .filter(Boolean)
}

export function extractExplicitTunAddresses(tun: unknown): string[] {
  if (!tun || typeof tun !== 'object') return []
  const value = tun as Record<string, unknown>
  return [
    ...toStringArray(value.address),
    ...toStringArray(value['inet4-address']),
    ...toStringArray(value['inet6-address'])
  ]
}

export async function readWindowsRoutePrefixes(): Promise<string[]> {
  if (process.platform !== 'win32') return []
  const script = [
    '[Console]::OutputEncoding = [System.Text.Encoding]::UTF8',
    '$prefixes = @()',
    '$prefixes += Get-NetRoute -ErrorAction Stop | Where-Object { $_.DestinationPrefix } | ForEach-Object { $_.DestinationPrefix }',
    '$prefixes += Get-NetIPAddress -ErrorAction Stop | Where-Object { $_.IPAddress -and $null -ne $_.PrefixLength } | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" }',
    '$prefixes | Sort-Object -Unique | ConvertTo-Json -Compress'
  ].join('; ')
  const { stdout } = await execFilePromise(
    'powershell.exe',
    ['-NoProfile', '-NonInteractive', '-Command', script],
    { encoding: 'utf8', windowsHide: true, timeout: 10_000, maxBuffer: 4 * 1024 * 1024 }
  )
  if (!stdout.trim()) return []
  const parsed = JSON.parse(stdout) as unknown
  const prefixes = Array.isArray(parsed) ? parsed : [parsed]
  return prefixes.filter((item): item is string => typeof item === 'string')
}

export async function preflightWindowsTunCandidate(options: {
  candidatePath: string
  activeConfigPath: string
  runtimeTun: unknown
  hasRunningCore: boolean
}): Promise<TunAddressDecision> {
  const candidate = JSON.parse(await readFile(options.candidatePath, 'utf8')) as unknown
  const candidateAddresses = extractTunAddresses(candidate)
  if (process.platform !== 'win32' || candidateAddresses.length === 0) {
    return { addresses: candidateAddresses, changes: [] }
  }

  let activeAddresses: string[] = []
  if (options.hasRunningCore) {
    try {
      activeAddresses = extractTunAddresses(
        JSON.parse(await readFile(options.activeConfigPath, 'utf8')) as unknown
      )
    } catch {
      // A missing active config simply means no collision can be attributed to
      // our currently managed process.
    }
  }

  const decision = chooseSafeTunAddresses(
    candidateAddresses,
    await readWindowsRoutePrefixes(),
    extractExplicitTunAddresses(options.runtimeTun),
    activeAddresses
  )
  if (decision.changes.length > 0) {
    setTunAddresses(candidate, decision.addresses)
    await writeFile(options.candidatePath, JSON.stringify(candidate, null, 2))
  }
  return decision
}
