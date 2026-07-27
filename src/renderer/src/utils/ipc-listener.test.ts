import { readdirSync, readFileSync } from 'node:fs'
import { dirname, extname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { describe, expect, it, vi } from 'vitest'
import { addRendererIpcListener } from './ipc-listener'

type Listener = (event: unknown, ...args: unknown[]) => void

function rendererSourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = join(directory, entry.name)
    if (entry.isDirectory()) return rendererSourceFiles(path)
    if (!['.ts', '.tsx'].includes(extname(entry.name)) || entry.name.endsWith('.test.ts')) return []
    return [path]
  })
}

describe('renderer IPC listener cleanup', () => {
  it('removes only the subscribed handler and leaves another consumer active', () => {
    const listeners = new Map<string, Set<Listener>>()
    const ipcRenderer = {
      on: vi.fn((channel: string, listener: Listener) => {
        const channelListeners = listeners.get(channel) ?? new Set<Listener>()
        channelListeners.add(listener)
        listeners.set(channel, channelListeners)
      }),
      removeListener: vi.fn((channel: string, listener: Listener) => {
        listeners.get(channel)?.delete(listener)
      })
    }
    const topologyHandler = vi.fn()
    const connectionsPageHandler = vi.fn()
    const removeTopologyHandler = addRendererIpcListener(
      ipcRenderer,
      'mihomoConnections',
      topologyHandler
    )
    addRendererIpcListener(ipcRenderer, 'mihomoConnections', connectionsPageHandler)

    removeTopologyHandler()
    listeners.get('mihomoConnections')?.forEach((listener) => listener({}, { connections: [] }))

    expect(ipcRenderer.removeListener).toHaveBeenCalledWith('mihomoConnections', topologyHandler)
    expect(topologyHandler).not.toHaveBeenCalled()
    expect(connectionsPageHandler).toHaveBeenCalledOnce()
  })

  it('does not allow renderer consumers to clear every listener on a channel', () => {
    const rendererRoot = dirname(dirname(fileURLToPath(import.meta.url)))
    const offenders = rendererSourceFiles(rendererRoot).filter((path) =>
      readFileSync(path, 'utf8').includes('.removeAllListeners(')
    )

    expect(offenders).toEqual([])
  })
})
