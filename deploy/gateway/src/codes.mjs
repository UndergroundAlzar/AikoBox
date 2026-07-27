// In-memory one-time authorization-code pool. Codes are short-lived (TTL <= 60s),
// consumed exactly once, and bound to the redirect_uri/client_id/code_challenge they
// were issued with. Not persisted: a restart simply invalidates in-flight logins.
import { randomBytes } from 'node:crypto'

export function createCodeStore({
  ttlMs = 60000,
  maxSize = 10000,
  sweepIntervalMs = Math.min(ttlMs, 1000),
  now = Date.now,
  setIntervalFn = setInterval,
  clearIntervalFn = clearInterval
} = {}) {
  if (!Number.isFinite(ttlMs) || ttlMs <= 0) throw new RangeError('ttlMs must be positive')
  if (!Number.isSafeInteger(maxSize) || maxSize <= 0)
    throw new RangeError('maxSize must be a positive safe integer')
  if (!Number.isFinite(sweepIntervalMs) || sweepIntervalMs <= 0)
    throw new RangeError('sweepIntervalMs must be positive')

  const codes = new Map() // code -> { ...payload, exp }

  function sweep() {
    const t = now()
    for (const [code, entry] of codes) if (t > entry.exp) codes.delete(code)
  }

  function issue(payload) {
    if (codes.size >= maxSize) {
      sweep()
      if (codes.size >= maxSize) return undefined
    }
    const code = randomBytes(32).toString('base64url')
    codes.set(code, { ...payload, exp: now() + ttlMs })
    return code
  }

  function consume(code) {
    const entry = codes.get(code)
    if (!entry) return undefined
    codes.delete(code) // one-time, even if expired
    if (now() > entry.exp) return undefined
    const { exp, ...payload } = entry
    void exp
    return payload
  }

  const sweepTimer = setIntervalFn(sweep, sweepIntervalMs)
  sweepTimer?.unref?.()

  function close() {
    clearIntervalFn(sweepTimer)
  }

  return { issue, consume, sweep, close, size: () => codes.size }
}
