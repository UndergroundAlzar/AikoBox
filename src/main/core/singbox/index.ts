import path from 'path'
import { mihomoCoreDir } from '../../utils/dirs'
import { deriveController, type ISingboxController } from './convert'
export { deriveProxyPortFromSingboxConfig } from './configIntrospection'
export * from './configPaths'

export function singboxCorePath(): string {
  // Synchronous/security-sensitive callers always receive the installation-owned
  // binary. The manager may opt into a managed core only through the asynchronous
  // hash/version/admin verification API in coreSelection.ts.
  return singboxBundledCorePath()
}

export function singboxBundledCorePath(): string {
  const isWin = process.platform === 'win32'
  return path.join(mihomoCoreDir(), `sing-box${isWin ? '.exe' : ''}`)
}

let activeController: ISingboxController = {
  listen: '127.0.0.1:9090',
  host: '127.0.0.1',
  port: 9090,
  secret: ''
}

export function setActiveController(controller: ISingboxController): void {
  activeController = controller
}

export function getActiveController(): ISingboxController {
  return activeController
}

export function setActiveControllerFromSingboxConfig(config: Record<string, unknown>): void {
  const experimental = (config.experimental || {}) as Record<string, unknown>
  const clashApi = (experimental.clash_api || {}) as Record<string, unknown>
  setActiveController(
    deriveController({
      'external-controller': clashApi.external_controller,
      secret: clashApi.secret
    })
  )
}
