import http from 'http'
import net from 'net'
import { getAppConfig, getControledMihomoConfig } from '../config'
import { systemLogger } from '../utils/logger'
import { DEFAULT_MIHOMO_PORTS } from '../../shared/appConfig'

export let pacPort: number

const defaultPacScript = `
function FindProxyForURL(url, host) {
  return "PROXY 127.0.0.1:%mixed-port%; SOCKS5 127.0.0.1:%mixed-port%; DIRECT;";
}
`

export function findAvailablePort(startPort: number): Promise<number> {
  return new Promise((resolve, reject) => {
    const server = net.createServer()
    server.on('error', (err) => {
      if (startPort <= 65535) {
        resolve(findAvailablePort(startPort + 1))
      } else {
        reject(err)
      }
    })
    server.on('listening', () => {
      server.close(() => {
        resolve(startPort)
      })
    })
    server.listen(startPort, '127.0.0.1')
  })
}

let pacServer: http.Server | null = null

export async function startPacServer(
  verifiedProxyPort?: number,
  requiredPacPort?: number
): Promise<void> {
  await stopPacServer()
  const { sysProxy } = await getAppConfig()
  const { mode = 'manual', pacScript } = sysProxy
  if (mode !== 'auto' && requiredPacPort === undefined) {
    return
  }
  let script = pacScript || defaultPacScript
  const { 'mixed-port': configuredPort = DEFAULT_MIHOMO_PORTS.mixed } =
    await getControledMihomoConfig()
  const port =
    typeof verifiedProxyPort === 'number' &&
    Number.isInteger(verifiedProxyPort) &&
    verifiedProxyPort > 0 &&
    verifiedProxyPort <= 65535
      ? verifiedProxyPort
      : configuredPort
  script = script.replaceAll('%mixed-port%', port.toString())
  if (
    requiredPacPort !== undefined &&
    (!Number.isInteger(requiredPacPort) || requiredPacPort <= 0 || requiredPacPort > 65535)
  ) {
    throw new Error(`Invalid required PAC port: ${requiredPacPort}`)
  }
  const listenPort = requiredPacPort ?? (await findAvailablePort(10000))
  const server = http.createServer(async (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/x-ns-proxy-autoconfig' })
    res.end(script)
  })

  await new Promise<void>((resolve, reject) => {
    const onError = (error: Error): void => {
      server.removeListener('listening', onListening)
      reject(error)
    }
    const onListening = (): void => {
      server.removeListener('error', onError)
      resolve()
    }
    server.once('error', onError)
    server.once('listening', onListening)
    // PAC is a local control endpoint, never a LAN service. The proxy target
    // itself may be customized independently in sysproxy.ts.
    server.listen(listenPort, '127.0.0.1')
  })
  pacPort = listenPort
  server.on('error', (error) => {
    void systemLogger.error('PAC server error', error)
  })
  pacServer = server
}

export async function stopPacServer(): Promise<void> {
  const server = pacServer
  pacServer = null
  if (!server?.listening) return
  await new Promise<void>((resolve, reject) => {
    server.close((error) => (error ? reject(error) : resolve()))
  })
}
