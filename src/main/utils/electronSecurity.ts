import { fileURLToPath } from 'url'
import { relative, resolve } from 'path'

const ALLOWED_RENDERER_DOCUMENTS = new Set(['index.html', 'floating.html'])

interface SenderFrameLike {
  url: string
  processId?: number
  routingId?: number
}

interface IpcSenderLike {
  mainFrame: SenderFrameLike
  getURL(): string
}

export interface IpcEventLike {
  sender: IpcSenderLike
  senderFrame: SenderFrameLike | null
}

/**
 * Normalize a URL before handing it to the operating system. Electron's
 * shell.openExternal can dispatch non-web schemes to arbitrary protocol
 * handlers, so AikoBox deliberately supports browser URLs only.
 */
export function normalizeExternalHttpUrl(value: unknown): string | null {
  if (typeof value !== 'string' || value.length === 0 || value !== value.trim()) return null

  try {
    const parsed = new URL(value)
    if (parsed.protocol !== 'https:' && parsed.protocol !== 'http:') return null
    if (!parsed.hostname || parsed.username || parsed.password) return null
    return parsed.toString()
  } catch {
    return null
  }
}

function isWithinRendererRoot(filePath: string, rendererRoot: string): boolean {
  const relativePath = relative(resolve(rendererRoot), resolve(filePath))
  return ALLOWED_RENDERER_DOCUMENTS.has(relativePath)
}

/** Allow only AikoBox's two top-level renderer documents (or its dev-server origin). */
export function isTrustedRendererUrl(
  value: unknown,
  rendererRoot: string,
  devServerUrl = process.env['ELECTRON_RENDERER_URL'],
  allowDevelopmentOrigin = false
): boolean {
  if (typeof value !== 'string' || value.length === 0) return false

  try {
    const parsed = new URL(value)
    if (parsed.protocol === 'file:') {
      return isWithinRendererRoot(fileURLToPath(parsed), rendererRoot)
    }

    if (!allowDevelopmentOrigin || !devServerUrl) return false
    const developmentOrigin = new URL(devServerUrl)
    return (
      (developmentOrigin.protocol === 'http:' || developmentOrigin.protocol === 'https:') &&
      parsed.origin === developmentOrigin.origin
    )
  } catch {
    return false
  }
}

/**
 * Reject IPC originating in an iframe or after a renderer navigated away from
 * AikoBox. This is important because the Sub-Store view can embed remote pages.
 */
export function isTrustedIpcSender(
  event: IpcEventLike | null | undefined,
  rendererRoot: string,
  devServerUrl = process.env['ELECTRON_RENDERER_URL'],
  allowDevelopmentOrigin = false
): boolean {
  if (!event?.senderFrame) return false
  const mainFrame = event.sender.mainFrame
  const isMainFrame =
    event.senderFrame === mainFrame ||
    (typeof event.senderFrame.processId === 'number' &&
      typeof event.senderFrame.routingId === 'number' &&
      event.senderFrame.processId === mainFrame.processId &&
      event.senderFrame.routingId === mainFrame.routingId)
  if (!isMainFrame) return false
  const frameUrl = event.senderFrame.url || event.sender.getURL()
  return isTrustedRendererUrl(frameUrl, rendererRoot, devServerUrl, allowDevelopmentOrigin)
}

export function assertTrustedIpcSender(
  event: IpcEventLike,
  rendererRoot: string,
  devServerUrl = process.env['ELECTRON_RENDERER_URL'],
  allowDevelopmentOrigin = false
): void {
  if (!isTrustedIpcSender(event, rendererRoot, devServerUrl, allowDevelopmentOrigin)) {
    throw new Error('Blocked IPC request from an untrusted renderer')
  }
}
