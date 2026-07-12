import { Worker } from 'worker_threads'
import { randomBytes } from 'crypto'
import http from 'http'
import net from 'net'
import path from 'path'
import { nativeImage } from 'electron'
import express from 'express'
import subStoreIcon from '../../../resources/subStoreIcon.png?asset'
import { mihomoWorkDir, subStoreDir, substoreLogPath } from '../utils/dirs'
import { getAppConfig, getControledMihomoConfig } from '../config'
import { systemLogger } from '../utils/logger'
import { createCappedLogWritableStream } from '../utils/logFile'
import { DEFAULT_MIHOMO_PORTS, DEFAULT_USE_SUB_STORE } from '../../shared/appConfig'

export let pacPort: number
export let subStorePort: number
export let subStoreFrontendPort: number
export let subStoreBackendPrefix = ''
let subStoreFrontendServer: http.Server | null = null
let subStoreBackendWorker: Worker | null = null

async function waitForLoopbackPort(port: number, timeoutMs = 10_000): Promise<void> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      await new Promise<void>((resolve, reject) => {
        const socket = net.createConnection({ host: '127.0.0.1', port })
        const finish = (error?: Error): void => {
          socket.removeAllListeners()
          socket.destroy()
          error ? reject(error) : resolve()
        }
        socket.setTimeout(500)
        socket.once('connect', () => finish())
        socket.once('timeout', () => finish(new Error('timeout')))
        socket.once('error', (error) => finish(error))
      })
      return
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100))
    }
  }
  throw new Error('Sub-Store backend did not bind its loopback port in time')
}

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

export async function startPacServer(verifiedProxyPort?: number): Promise<void> {
  await stopPacServer()
  const { sysProxy } = await getAppConfig()
  const { mode = 'manual', pacScript } = sysProxy
  if (mode !== 'auto') {
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
  pacPort = await findAvailablePort(10000)
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
    server.listen(pacPort, '127.0.0.1')
  })
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

export async function startSubStoreFrontendServer(): Promise<void> {
  const { useSubStore = DEFAULT_USE_SUB_STORE } = await getAppConfig()
  if (!useSubStore) return
  await stopSubStoreFrontendServer()
  subStoreFrontendPort = await findAvailablePort(14122)
  const app = express()
  const frontendDir = path.join(mihomoWorkDir(), 'sub-store-frontend')
  app.use(express.static(frontendDir))
  app.use((_req, res) => {
    res.sendFile(path.join(frontendDir, 'index.html'))
  })
  const server = app.listen(subStoreFrontendPort, '127.0.0.1')
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
  })
  server.on('error', (error) => {
    void systemLogger.error('Sub-Store frontend server error', error)
  })
  subStoreFrontendServer = server
}

export async function stopSubStoreFrontendServer(): Promise<void> {
  const server = subStoreFrontendServer
  subStoreFrontendServer = null
  if (!server?.listening) return
  await new Promise<void>((resolve) => server.close(() => resolve()))
}

export async function startSubStoreBackendServer(): Promise<void> {
  const {
    useSubStore = DEFAULT_USE_SUB_STORE,
    useCustomSubStore = false,
    useProxyInSubStore = false,
    subStoreBackendSyncCron = '',
    subStoreBackendDownloadCron = '',
    subStoreBackendUploadCron = ''
  } = await getAppConfig()
  const { 'mixed-port': port = DEFAULT_MIHOMO_PORTS.mixed } = await getControledMihomoConfig()
  if (!useSubStore) return
  if (!useCustomSubStore) {
    await stopSubStoreBackendServer()
    subStorePort = await findAvailablePort(38324)
    subStoreBackendPrefix = `/aikobox-${randomBytes(24).toString('hex')}`
    const icon = nativeImage.createFromPath(subStoreIcon)
    icon.toDataURL()
    const stdout = createCappedLogWritableStream(substoreLogPath)
    const stderr = createCappedLogWritableStream(substoreLogPath)
    const env = {
      SUB_STORE_BACKEND_API_PORT: subStorePort.toString(),
      // The built-in backend contains subscription secrets and has no AikoBox
      // authentication layer. It is intentionally loopback-only.
      SUB_STORE_BACKEND_API_HOST: '127.0.0.1',
      // A random, per-run path capability prevents arbitrary web pages from
      // issuing blind requests to the unauthenticated loopback backend.
      SUB_STORE_BACKEND_PREFIX: '1',
      SUB_STORE_FRONTEND_BACKEND_PATH: subStoreBackendPrefix,
      SUB_STORE_CORS_ALLOWED_ORIGINS: `http://127.0.0.1:${subStoreFrontendPort}`,
      SUB_STORE_DATA_BASE_PATH: subStoreDir(),
      SUB_STORE_BACKEND_CUSTOM_ICON: icon.toDataURL(),
      SUB_STORE_BACKEND_CUSTOM_NAME: 'AikoBox',
      SUB_STORE_BACKEND_SYNC_CRON: subStoreBackendSyncCron,
      SUB_STORE_BACKEND_DOWNLOAD_CRON: subStoreBackendDownloadCron,
      SUB_STORE_BACKEND_UPLOAD_CRON: subStoreBackendUploadCron
    }
    const worker = new Worker(path.join(mihomoWorkDir(), 'sub-store.bundle.cjs'), {
      env: useProxyInSubStore
        ? {
            ...env,
            HTTP_PROXY: `http://127.0.0.1:${port}`,
            HTTPS_PROXY: `http://127.0.0.1:${port}`,
            ALL_PROXY: `http://127.0.0.1:${port}`
          }
        : env
    })
    worker.stdout.pipe(stdout)
    worker.stderr.pipe(stderr)
    try {
      await new Promise<void>((resolve, reject) => {
        let settled = false
        const finish = (callback: () => void): void => {
          if (settled) return
          settled = true
          clearTimeout(timer)
          worker.removeListener('online', onOnline)
          worker.removeListener('error', onError)
          callback()
        }
        const onOnline = (): void => {
          void waitForLoopbackPort(subStorePort).then(
            () => finish(resolve),
            (error) => finish(() => reject(error))
          )
        }
        const onError = (error: Error): void => finish(() => reject(error))
        const timer = setTimeout(
          () => finish(() => reject(new Error('Sub-Store worker startup timed out'))),
          16000
        )
        worker.once('online', onOnline)
        worker.once('error', onError)
      })
    } catch (error) {
      await worker.terminate().catch(() => {})
      throw error
    }
    worker.on('error', (error) => {
      void systemLogger.error('Sub-Store backend worker error', error)
    })
    worker.on('exit', (code) => {
      if (subStoreBackendWorker === worker) subStoreBackendWorker = null
      if (code !== 0) void systemLogger.error(`Sub-Store backend exited with code ${code}`)
    })
    subStoreBackendWorker = worker
  }
}

export async function stopSubStoreBackendServer(): Promise<void> {
  const worker = subStoreBackendWorker
  subStoreBackendWorker = null
  subStoreBackendPrefix = ''
  if (worker) await worker.terminate()
}
