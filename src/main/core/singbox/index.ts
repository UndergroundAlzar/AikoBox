import path from 'path'
import { mihomoCoreDir } from '../../utils/dirs'
import type { ISingboxController } from './convert'

export const SINGBOX_CONFIG_NAME = 'sing-box.json'

export function singboxCorePath(): string {
  const isWin = process.platform === 'win32'
  return path.join(mihomoCoreDir(), `sing-box${isWin ? '.exe' : ''}`)
}

export function singboxWorkConfigPath(workDir: string): string {
  return path.join(workDir, SINGBOX_CONFIG_NAME)
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
