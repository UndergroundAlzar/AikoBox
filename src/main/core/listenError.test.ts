import { describe, expect, it } from 'vitest'
import {
  formatPortConflictUserMessage,
  isPortInUseListenError,
  mapCoreListenError
} from './listenError'

describe('listenError', () => {
  it('detects Windows, POSIX, and Node-style port-in-use errors', () => {
    expect(
      isPortInUseListenError(
        'listen tcp 127.0.0.1:7890: bind: Only one usage of each socket address (protocol/network address/port) is normally permitted.'
      )
    ).toBe(true)
    expect(isPortInUseListenError('listen tcp 127.0.0.1:7890: bind: address already in use')).toBe(
      true
    )
    expect(isPortInUseListenError('Error: listen EADDRINUSE: address already in use :::7890')).toBe(
      true
    )
    expect(
      isPortInUseListenError('FATAL[0000] configure tun interface: operation not permitted')
    ).toBe(false)
  })

  it('maps port-in-use errors to bilingual guidance mentioning Bettbox and 17890+', () => {
    const mapped = mapCoreListenError(
      'listen tcp 127.0.0.1:7890: bind: Only one usage of each socket address is normally permitted.',
      7890
    )
    expect(mapped).toBeTruthy()
    expect(mapped).toContain('混合端口 7890被占用')
    expect(mapped).toContain('Bettbox')
    expect(mapped).toContain('17890')
    expect(mapped).toContain('Mixed-port 7890 is already in use')
    expect(mapped).toContain('Settings')
  })

  it('returns null for unrelated core output', () => {
    expect(mapCoreListenError('INFO start service')).toBeNull()
    expect(mapCoreListenError('FATAL router: dial failed')).toBeNull()
  })

  it('formats a message without a concrete port when unknown', () => {
    const message = formatPortConflictUserMessage()
    expect(message).toContain('混合端口被占用')
    expect(message).toContain('Mixed-port is already in use')
    expect(message).not.toMatch(/混合端口 \d+被占用/)
  })
})
