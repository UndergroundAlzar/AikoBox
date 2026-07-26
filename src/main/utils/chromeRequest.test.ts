import { EventEmitter } from 'events'
import { beforeEach, describe, expect, it, vi } from 'vitest'

interface FakeSession {
  partition: string
  proxyRules: string[]
  setProxy: (options: { proxyRules: string }) => Promise<void>
}

const mocks = vi.hoisted(() => ({
  requests: [] as Array<EventEmitter & { options: Record<string, unknown>; aborted: boolean }>,
  sessions: new Map<string, FakeSession>()
}))

vi.mock('electron', async () => {
  const { EventEmitter: Emitter } = await import('events')

  class FakeRequest extends Emitter {
    aborted = false

    constructor(readonly options: Record<string, unknown>) {
      super()
    }

    setHeader(): void {
      // 假请求不需要记录 header
    }
    write(): void {
      // 假请求不需要记录 body
    }
    end(): void {
      // 响应由测试手动驱动
    }
    abort(): void {
      this.aborted = true
      this.emit('abort')
    }
  }

  return {
    net: {
      request: (options: Record<string, unknown>) => {
        const req = new FakeRequest(options)
        mocks.requests.push(req as never)
        return req
      }
    },
    session: {
      defaultSession: { partition: 'default' },
      fromPartition: (partition: string): FakeSession => {
        const existing = mocks.sessions.get(partition)
        if (existing) return existing
        const created: FakeSession = {
          partition,
          proxyRules: [],
          setProxy: async ({ proxyRules }) => {
            created.proxyRules.push(proxyRules)
          }
        }
        mocks.sessions.set(partition, created)
        return created
      }
    }
  }
})

function respondHead(index: number, rawHeaders: string[] = []): EventEmitter {
  const res = new EventEmitter() as EventEmitter & Record<string, unknown>
  res.statusCode = 200
  res.statusMessage = 'OK'
  res.rawHeaders = rawHeaders
  mocks.requests[index].emit('response', res)
  return res
}

const flush = (): Promise<void> => new Promise((resolve) => setTimeout(resolve, 0))

describe('chromeRequest', () => {
  beforeEach(() => {
    vi.resetModules()
    mocks.requests.length = 0
    mocks.sessions.clear()
  })

  it('aborts mid-stream once the body passes the cap instead of buffering it all', async () => {
    const { request } = await import('./chromeRequest')
    const pending = request('https://example.com/big', { maxBodyBytes: 10, timeout: 0 })
    await flush()

    const res = respondHead(0)
    res.emit('data', Buffer.alloc(6))
    expect(mocks.requests[0].aborted).toBe(false)
    res.emit('data', Buffer.alloc(6))
    expect(mocks.requests[0].aborted).toBe(true)
    // 后续分片必须被丢弃，不能再进内存
    res.emit('data', Buffer.alloc(1024 * 1024))
    res.emit('end')

    await expect(pending).rejects.toThrow('Response body exceeds 10 bytes')
  })

  it('rejects an over-cap content-length before a single chunk arrives', async () => {
    const { request } = await import('./chromeRequest')
    const pending = request('https://example.com/big', { maxBodyBytes: 16, timeout: 0 })
    await flush()

    respondHead(0, ['Content-Length', '4096'])
    expect(mocks.requests[0].aborted).toBe(true)

    await expect(pending).rejects.toThrow('Response body exceeds 16 bytes')
  })

  it('caps the body by default', async () => {
    const { DEFAULT_MAX_BODY_BYTES } = await import('./chromeRequest')
    expect(DEFAULT_MAX_BODY_BYTES).toBe(32 * 1024 * 1024)
  })

  it('gives each proxy its own session so concurrent requests cannot swap proxies', async () => {
    const { request } = await import('./chromeRequest')
    const first = request('https://a.example/', {
      proxy: { protocol: 'http', host: '127.0.0.1', port: 1111 },
      timeout: 0
    })
    const second = request('https://b.example/', {
      proxy: { protocol: 'http', host: '127.0.0.1', port: 2222 },
      timeout: 0
    })
    await flush()

    expect(mocks.requests).toHaveLength(2)
    const sessionA = mocks.requests[0].options.session as FakeSession
    const sessionB = mocks.requests[1].options.session as FakeSession
    expect(sessionA).not.toBe(sessionB)
    expect(sessionA.proxyRules).toEqual(['http://127.0.0.1:1111'])
    expect(sessionB.proxyRules).toEqual(['http://127.0.0.1:2222'])

    respondHead(0).emit('end')
    respondHead(1).emit('end')
    await expect(first).resolves.toMatchObject({ status: 200 })
    await expect(second).resolves.toMatchObject({ status: 200 })
  })

  it('reuses one session per proxy url and configures it once', async () => {
    const { request } = await import('./chromeRequest')
    const proxy = { protocol: 'http', host: '127.0.0.1', port: 7890 } as const
    const first = request('https://a.example/', { proxy, timeout: 0 })
    const second = request('https://b.example/', { proxy, timeout: 0 })
    await flush()

    expect(mocks.sessions.size).toBe(1)
    const [only] = [...mocks.sessions.values()]
    expect(only.proxyRules).toEqual(['http://127.0.0.1:7890'])
    expect(only.partition.startsWith('proxy-requests-')).toBe(true)

    respondHead(0).emit('end')
    respondHead(1).emit('end')
    await Promise.all([first, second])
  })

  it('bounds the per-proxy session cache instead of growing forever', async () => {
    const { request } = await import('./chromeRequest')
    const pending: Promise<unknown>[] = []
    const fire = async (port: number): Promise<void> => {
      pending.push(
        request(`https://p${port}.example/`, {
          proxy: { protocol: 'http', host: '127.0.0.1', port },
          timeout: 0
        }).catch(() => undefined)
      )
      await flush()
    }

    // 混合端口每换一次就多一个代理地址，而 fromPartition 建出来的分区销毁不掉
    for (let port = 3000; port < 3012; port++) await fire(port)

    const sessionFor = (port: number): FakeSession =>
      [...mocks.sessions.values()].find((s) =>
        s.proxyRules.includes(`http://127.0.0.1:${port}`)
      ) as FakeSession

    // 最久未用的那个已经被淘汰：再用到它必须重新 setProxy
    expect(sessionFor(3000).proxyRules).toHaveLength(1)
    await fire(3000)
    expect(sessionFor(3000).proxyRules).toHaveLength(2)

    // 最近用过的仍在缓存里，不会重复配置
    await fire(3011)
    expect(sessionFor(3011).proxyRules).toHaveLength(1)

    for (const req of mocks.requests) req.emit('error', new Error('done'))
    await Promise.all(pending)
  })
})
