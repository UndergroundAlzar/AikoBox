import { describe, expect, it } from 'vitest'
import { toIpcErrorEnvelope } from '../../../main/utils/ipcError'
import { IpcError, checkIpcError } from './ipc'

describe('ipc error round-trip', () => {
  it('passes a normal payload through untouched', () => {
    expect(checkIpcError<{ ok: boolean }>({ ok: true })).toEqual({ ok: true })
    expect(checkIpcError<null>(null)).toBeNull()
  })

  it('rehydrates a real Error so instanceof branches stop being dead', () => {
    const thrown = (() => {
      try {
        checkIpcError(toIpcErrorEnvelope(new Error('unsupported v1 plugin file')))
        return null
      } catch (e) {
        return e
      }
    })()

    expect(thrown).toBeInstanceOf(Error)
    expect(thrown).toBeInstanceOf(IpcError)
    expect((thrown as Error).message).toBe('unsupported v1 plugin file')
  })

  it('keeps String(e) equal to the bare message for toast.error call sites', () => {
    // 30+ renderer catch blocks do `toast.error(String(e))`; a default
    // Error.toString() would surface "IpcError: ..." to every one of them.
    try {
      checkIpcError(toIpcErrorEnvelope(new Error('WebDAV 401 Unauthorized')))
    } catch (e) {
      expect(String(e)).toBe('WebDAV 401 Unauthorized')
      expect(`${e}`).toBe('WebDAV 401 Unauthorized')
    }
  })

  it('carries a stable code so callers do not match message substrings', () => {
    const source = Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' })
    expect(() => checkIpcError(toIpcErrorEnvelope(source))).toThrow(IpcError)
    try {
      checkIpcError(toIpcErrorEnvelope(source))
    } catch (e) {
      expect((e as IpcError).code).toBe('ECONNREFUSED')
    }
  })

  it('leaves code undefined when the main process did not supply one', () => {
    try {
      checkIpcError(toIpcErrorEnvelope('plain string failure'))
    } catch (e) {
      expect(e).toBeInstanceOf(IpcError)
      expect((e as IpcError).message).toBe('plain string failure')
      expect((e as IpcError).code).toBeUndefined()
    }
  })
})
