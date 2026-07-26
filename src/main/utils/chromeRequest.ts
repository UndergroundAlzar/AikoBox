import { createHash } from 'crypto'
import { net, session } from 'electron'

export interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE' | 'PATCH'
  headers?: Record<string, string>
  body?: string | Buffer
  proxy?:
    | {
        protocol: 'http' | 'https' | 'socks5'
        host: string
        port: number
      }
    | false
  timeout?: number
  responseType?: 'text' | 'json' | 'arraybuffer'
  followRedirect?: boolean
  maxRedirects?: number
  maxBodyBytes?: number
  onProgress?: (loaded: number, total: number) => void
}

export const DEFAULT_MAX_BODY_BYTES = 32 * 1024 * 1024

export interface Response<T = unknown> {
  data: T
  status: number
  statusText: string
  headers: Record<string, string>
  url: string
}

// 每个代理地址独占一个 session。共享一个分区时，两个并发请求会互相覆盖 proxyRules，
// 先发起的那个会带着凭据走到后设置的端口上。
// session.fromPartition 建出来的内存分区不能销毁，所以这里做成有界 LRU：混合端口
// 每变一次就会多出一个永久分区，长期运行下去是无上限增长。
const MAX_PROXY_SESSIONS = 8
const proxySessions = new Map<string, Promise<Electron.Session>>()

function getProxySession(proxyUrl: string): Promise<Electron.Session> {
  const cached = proxySessions.get(proxyUrl)
  if (cached) {
    // 命中即刷新 LRU 次序
    proxySessions.delete(proxyUrl)
    proxySessions.set(proxyUrl, cached)
    return cached
  }
  const pending = (async () => {
    const id = createHash('sha256').update(proxyUrl).digest('hex').slice(0, 16)
    const proxySession = session.fromPartition(`proxy-requests-${id}`, { cache: false })
    await proxySession.setProxy({ proxyRules: proxyUrl })
    return proxySession
  })()
  pending.catch(() => proxySessions.delete(proxyUrl))
  proxySessions.set(proxyUrl, pending)
  while (proxySessions.size > MAX_PROXY_SESSIONS) {
    const oldest = proxySessions.keys().next()
    if (oldest.done) break
    proxySessions.delete(oldest.value)
  }
  return pending
}

/**
 * Make HTTP request using Chromium's network stack (via electron.net)
 * This provides better compatibility, HTTP/2 support, and system certificate integration
 */
export async function request<T = unknown>(
  url: string,
  options: RequestOptions = {}
): Promise<Response<T>> {
  const {
    method = 'GET',
    headers = {},
    body,
    proxy,
    timeout = 30000,
    responseType = 'text',
    followRedirect = true,
    maxRedirects = 20,
    maxBodyBytes = DEFAULT_MAX_BODY_BYTES,
    onProgress
  } = options

  return new Promise((resolve, reject) => {
    let sessionToUse: Electron.Session = session.defaultSession

    // Set up proxy if specified
    const setupProxy = async (): Promise<void> => {
      if (proxy) {
        const proxyUrl = `${proxy.protocol}://${proxy.host}:${proxy.port}`
        sessionToUse = await getProxySession(proxyUrl)
      }
    }

    setupProxy()
      .then(() => {
        const req = net.request({
          method,
          url,
          session: sessionToUse,
          redirect: followRedirect ? 'follow' : 'manual',
          useSessionCookies: true
        })

        // Set request headers
        Object.entries(headers).forEach(([key, value]) => {
          req.setHeader(key, value)
        })

        // Timeout handling
        let timeoutId: NodeJS.Timeout | undefined
        let settled = false
        const fail = (error: Error): void => {
          if (settled) return
          settled = true
          if (timeoutId) clearTimeout(timeoutId)
          reject(error)
        }

        if (timeout > 0) {
          timeoutId = setTimeout(() => {
            // 先 fail 再 abort：abort 会同步触发 'abort' 事件，否则具体原因会被覆盖成 "Request aborted"
            fail(new Error(`Request timeout after ${timeout}ms`))
            req.abort()
          }, timeout)
        }

        const chunks: Buffer[] = []
        let redirectCount = 0

        req.on('redirect', () => {
          redirectCount++
          if (redirectCount > maxRedirects) {
            fail(new Error(`Too many redirects (>${maxRedirects})`))
            req.abort()
          }
        })

        req.on('response', (res) => {
          const { statusCode, statusMessage } = res

          // Extract response headers
          const responseHeaders: Record<string, string> = {}
          const rawHeaders = res.rawHeaders || []
          for (let i = 0; i < rawHeaders.length; i += 2) {
            responseHeaders[rawHeaders[i].toLowerCase()] = rawHeaders[i + 1]
          }

          const totalSize = parseInt(responseHeaders['content-length'] || '0', 10)
          let loadedSize = 0

          if (totalSize > maxBodyBytes) {
            fail(new Error(`Response body exceeds ${maxBodyBytes} bytes`))
            req.abort()
            return
          }

          // 逐块计数：等到 Buffer.concat 之后再检查大小时，主进程已经把整个响应吃进内存了
          let receivedSize = 0
          res.on('data', (chunk: Buffer) => {
            if (settled) return
            receivedSize += chunk.length
            if (receivedSize > maxBodyBytes) {
              chunks.length = 0
              fail(new Error(`Response body exceeds ${maxBodyBytes} bytes`))
              req.abort()
              return
            }
            chunks.push(chunk)
            if (onProgress && totalSize > 0) {
              loadedSize += chunk.length
              onProgress(loadedSize, totalSize)
            }
          })

          res.on('end', () => {
            if (settled) return
            settled = true
            if (timeoutId) clearTimeout(timeoutId)

            const buffer = Buffer.concat(chunks)
            let data: unknown

            try {
              switch (responseType) {
                case 'json':
                  data = JSON.parse(buffer.toString('utf-8'))
                  break
                case 'arraybuffer':
                  data = buffer
                  break
                case 'text':
                default:
                  data = buffer.toString('utf-8')
              }

              resolve({
                data: data as T,
                status: statusCode,
                statusText: statusMessage,
                headers: responseHeaders,
                url: url
              })
            } catch (error: unknown) {
              reject(new Error(`Failed to parse response: ${String(error)}`))
            }
          })

          res.on('error', (error: unknown) => {
            fail(error instanceof Error ? error : new Error(String(error)))
          })
        })

        req.on('error', (error: unknown) => {
          fail(error instanceof Error ? error : new Error(String(error)))
        })

        req.on('abort', () => {
          fail(new Error('Request aborted'))
        })

        // Send request body
        if (body) {
          if (typeof body === 'string') {
            req.write(body, 'utf-8')
          } else {
            req.write(body)
          }
        }

        req.end()
      })
      .catch((error: unknown) => {
        reject(new Error(`Failed to setup proxy: ${String(error)}`))
      })
  })
}

/**
 * Convenience method for GET requests
 */
export const get = <T = unknown>(
  url: string,
  options?: Omit<RequestOptions, 'method' | 'body'>
): Promise<Response<T>> => request<T>(url, { ...options, method: 'GET' })

/**
 * Convenience method for POST requests
 */
export const post = <T = unknown>(
  url: string,
  data: unknown,
  options?: Omit<RequestOptions, 'method' | 'body'>
): Promise<Response<T>> => {
  const body = typeof data === 'string' ? data : JSON.stringify(data)
  const headers = options?.headers || {}
  if (typeof data !== 'string' && !headers['content-type']) {
    headers['content-type'] = 'application/json'
  }
  return request<T>(url, { ...options, method: 'POST', body, headers })
}

/**
 * Convenience method for PUT requests
 */
export const put = <T = unknown>(
  url: string,
  data: unknown,
  options?: Omit<RequestOptions, 'method' | 'body'>
): Promise<Response<T>> => {
  const body = typeof data === 'string' ? data : JSON.stringify(data)
  const headers = options?.headers || {}
  if (typeof data !== 'string' && !headers['content-type']) {
    headers['content-type'] = 'application/json'
  }
  return request<T>(url, { ...options, method: 'PUT', body, headers })
}

/**
 * Convenience method for DELETE requests
 */
export const del = <T = unknown>(
  url: string,
  options?: Omit<RequestOptions, 'method' | 'body'>
): Promise<Response<T>> => request<T>(url, { ...options, method: 'DELETE' })

/**
 * Convenience method for PATCH requests
 */
export const patch = <T = unknown>(
  url: string,
  data: unknown,
  options?: Omit<RequestOptions, 'method' | 'body'>
): Promise<Response<T>> => {
  const body = typeof data === 'string' ? data : JSON.stringify(data)
  const headers = options?.headers || {}
  if (typeof data !== 'string' && !headers['content-type']) {
    headers['content-type'] = 'application/json'
  }
  return request<T>(url, { ...options, method: 'PATCH', body, headers })
}
