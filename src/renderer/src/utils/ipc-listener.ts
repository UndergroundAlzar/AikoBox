type RendererIpc = typeof window.electron.ipcRenderer
type RendererIpcChannel = Parameters<RendererIpc['on']>[0]
type RendererIpcListener = Parameters<RendererIpc['on']>[1]

export function addRendererIpcListener(
  ipcRenderer: Pick<RendererIpc, 'on' | 'removeListener'>,
  channel: RendererIpcChannel,
  listener: RendererIpcListener
): () => void {
  ipcRenderer.on(channel, listener)

  return (): void => {
    ipcRenderer.removeListener(channel, listener)
  }
}
