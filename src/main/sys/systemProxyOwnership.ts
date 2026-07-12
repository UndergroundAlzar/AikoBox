export interface ManualProxyState {
  enable: boolean
  host: string
  port: number
  bypass: string
}

export interface AutoProxyState {
  enable: boolean
  url: string
}

export interface SystemProxyState {
  manual: ManualProxyState
  auto: AutoProxyState
}

export interface OwnedSystemProxyRecord {
  version: 2
  revision?: number
  ownerPid: number
  createdAt: string
  phase: 'prepared' | 'applied' | 'restoring'
  previous: SystemProxyState
  applied: SystemProxyState
  ownedStates: SystemProxyState[]
  previousRegistry?: WindowsProxyRegistrySnapshot
  appliedRegistry?: WindowsProxyRegistrySnapshot
  coreEndpoint?: { host: string; port: number }
}

function normalizeText(value: unknown): string {
  return typeof value === 'string' ? value : ''
}

export function normalizeSystemProxyState(state: SystemProxyState): SystemProxyState {
  return {
    manual: {
      enable: state.manual.enable === true,
      host: normalizeText(state.manual.host),
      port:
        typeof state.manual.port === 'number' && Number.isFinite(state.manual.port)
          ? state.manual.port
          : 0,
      bypass: normalizeText(state.manual.bypass)
    },
    auto: {
      enable: state.auto.enable === true,
      url: normalizeText(state.auto.url)
    }
  }
}

export function sameSystemProxyState(a: SystemProxyState, b: SystemProxyState): boolean {
  const left = normalizeSystemProxyState(a)
  const right = normalizeSystemProxyState(b)
  return (
    left.manual.enable === right.manual.enable &&
    left.manual.host === right.manual.host &&
    left.manual.port === right.manual.port &&
    left.manual.bypass === right.manual.bypass &&
    left.auto.enable === right.auto.enable &&
    left.auto.url === right.auto.url
  )
}

export function isOwnedSystemProxyRecord(value: unknown): value is OwnedSystemProxyRecord {
  if (!value || typeof value !== 'object') return false
  const record = value as Partial<OwnedSystemProxyRecord>
  if (
    record.version !== 2 ||
    (record.revision !== undefined &&
      (!Number.isSafeInteger(record.revision) || record.revision < 0)) ||
    typeof record.ownerPid !== 'number' ||
    typeof record.createdAt !== 'string' ||
    !['prepared', 'applied', 'restoring'].includes(record.phase || '') ||
    !record.previous ||
    !record.applied ||
    !Array.isArray(record.ownedStates) ||
    (record.previousRegistry !== undefined &&
      !isWindowsProxyRegistrySnapshot(record.previousRegistry)) ||
    (record.appliedRegistry !== undefined &&
      !isWindowsProxyRegistrySnapshot(record.appliedRegistry)) ||
    (record.coreEndpoint !== undefined &&
      ((record.coreEndpoint.host !== '127.0.0.1' && record.coreEndpoint.host !== '::1') ||
        !Number.isInteger(record.coreEndpoint.port) ||
        record.coreEndpoint.port <= 0 ||
        record.coreEndpoint.port > 65535))
  ) {
    return false
  }

  try {
    normalizeSystemProxyState(record.previous)
    normalizeSystemProxyState(record.applied)
    record.ownedStates.forEach(normalizeSystemProxyState)
    return true
  } catch {
    return false
  }
}

export function createOwnedSystemProxyRecord(
  previous: SystemProxyState,
  applied: SystemProxyState,
  ownedStates: SystemProxyState[] = [],
  ownerPid = process.pid,
  previousRegistry?: WindowsProxyRegistrySnapshot,
  coreEndpoint?: { host: string; port: number }
): OwnedSystemProxyRecord {
  return {
    version: 2,
    revision: 0,
    ownerPid,
    createdAt: new Date().toISOString(),
    phase: 'prepared',
    previous: normalizeSystemProxyState(previous),
    applied: normalizeSystemProxyState(applied),
    ownedStates: [previous, ...ownedStates, applied].map(normalizeSystemProxyState),
    previousRegistry,
    coreEndpoint
  }
}
import {
  isWindowsProxyRegistrySnapshot,
  type WindowsProxyRegistrySnapshot
} from './windowsProxyRegistry'
