// Fixed-window in-memory rate limiter. hit(key) returns true if allowed, false if over
// the cap for the current window. Good enough for one-instance login throttling.
export function createRateLimiter({
  max = 10,
  windowMs = 60000,
  maxKeys = 50000,
  now = Date.now
} = {}) {
  const windows = new Map() // key -> { count, resetAt }
  let nextSweepAt = 0

  function hit(key) {
    const t = now()
    if (t >= nextSweepAt) {
      sweep(t)
      nextSweepAt = t + windowMs
    }
    let w = windows.get(key)
    if (!w || t >= w.resetAt) {
      // Fail closed instead of allowing rotating keys to exhaust process memory.
      if (!windows.has(key) && windows.size >= maxKeys) return false
      w = { count: 0, resetAt: t + windowMs }
      windows.set(key, w)
    }
    w.count++
    return w.count <= max
  }

  function sweep(t = now()) {
    for (const [k, w] of windows) if (t >= w.resetAt) windows.delete(k)
  }

  return { hit, sweep, size: () => windows.size }
}
