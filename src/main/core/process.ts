import net from 'net'
import { managerLogger } from '../utils/logger'
import { getAxios } from './mihomoApi'

// 常量
const CORE_READY_MAX_RETRIES = 150
const CORE_READY_RETRY_INTERVAL_MS = 100

export async function waitForCoreReady(): Promise<void> {
  for (let i = 0; i < CORE_READY_MAX_RETRIES; i++) {
    try {
      const axios = await getAxios(true)
      await axios.get('/')
      managerLogger.info(
        `Core ready after ${i + 1} attempts (${(i + 1) * CORE_READY_RETRY_INTERVAL_MS}ms)`
      )
      return
    } catch {
      if (i === 0) {
        managerLogger.info('Waiting for core to be ready...')
      }

      if (i === CORE_READY_MAX_RETRIES - 1) {
        throw new Error(
          `sing-box Clash API was not ready after ${CORE_READY_MAX_RETRIES * CORE_READY_RETRY_INTERVAL_MS}ms`
        )
      }

      await new Promise((resolve) => setTimeout(resolve, CORE_READY_RETRY_INTERVAL_MS))
    }
  }
}

export async function waitForTcpPort(host: string, port: number, timeoutMs = 15000): Promise<void> {
  if (!Number.isInteger(port) || port <= 0 || port > 65535) {
    throw new Error(`Invalid proxy port: ${port}`)
  }

  const deadline = Date.now() + timeoutMs
  let lastError: unknown
  while (Date.now() < deadline) {
    try {
      await new Promise<void>((resolve, reject) => {
        const socket = net.createConnection({ host, port })
        const finish = (error?: Error): void => {
          socket.removeAllListeners()
          socket.destroy()
          error ? reject(error) : resolve()
        }
        socket.setTimeout(500)
        socket.once('connect', () => finish())
        socket.once('timeout', () => finish(new Error('connection timed out')))
        socket.once('error', (error) => finish(error))
      })
      return
    } catch (error) {
      lastError = error
      await new Promise((resolve) => setTimeout(resolve, CORE_READY_RETRY_INTERVAL_MS))
    }
  }

  throw new Error(
    `sing-box proxy port ${host}:${port} was not ready after ${timeoutMs}ms: ${String(lastError)}`
  )
}
