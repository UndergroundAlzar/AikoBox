import net from 'net'
import { afterEach, describe, expect, it, vi } from 'vitest'

vi.mock('../config', () => ({
  getAppConfig: async () => ({
    sysProxy: { mode: 'manual', pacScript: 'return "PROXY 127.0.0.1:%mixed-port%";' }
  }),
  getControledMihomoConfig: async () => ({ 'mixed-port': 17890 })
}))

vi.mock('../utils/logger', () => ({
  systemLogger: { error: vi.fn(async () => {}) }
}))

describe('PAC server crash recovery', () => {
  afterEach(async () => {
    const { stopPacServer } = await import('./server')
    await stopPacServer()
  })

  it('fails instead of selecting another port when the journaled port is occupied', async () => {
    const blocker = net.createServer()
    await new Promise<void>((resolve, reject) => {
      blocker.once('error', reject)
      blocker.listen(0, '127.0.0.1', resolve)
    })
    const address = blocker.address()
    if (!address || typeof address === 'string') {
      throw new Error('Expected a TCP address for the occupied PAC port')
    }

    try {
      const { startPacServer } = await import('./server')
      await expect(startPacServer(17890, address.port)).rejects.toMatchObject({
        code: 'EADDRINUSE'
      })
    } finally {
      await new Promise<void>((resolve, reject) => {
        blocker.close((error) => (error ? reject(error) : resolve()))
      })
    }
  })
})
