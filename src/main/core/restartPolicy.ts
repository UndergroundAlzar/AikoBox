export interface RestartDecision {
  allowed: boolean
  crashCount: number
  delayMs: number
}

export interface CrashRestartPolicyOptions {
  windowMs?: number
  maxRestarts?: number
  baseDelayMs?: number
  maxDelayMs?: number
}

export interface RestartTransactionOptions {
  startCore: () => Promise<void>
  applySystemProxy: () => Promise<void>
  isTerminalStartError: (error: unknown) => boolean
  onTerminalStartError: (error: unknown) => Promise<void>
  onRetry: (error: unknown, attempt: number, maxAttempts: number) => void
  sleep: (delayMs: number) => Promise<void>
  maxAttempts?: number
}

/**
 * Retries only the core start transaction. Once a core is healthy, system
 * proxy application runs exactly once and its failure is surfaced directly.
 */
export async function runRestartTransaction(options: RestartTransactionOptions): Promise<void> {
  const maxAttempts = options.maxAttempts ?? 3
  if (!Number.isInteger(maxAttempts) || maxAttempts < 1) {
    throw new Error('maxAttempts must be a positive integer')
  }

  let attempt = 0
  while (attempt < maxAttempts) {
    try {
      await options.startCore()
      break
    } catch (error) {
      if (options.isTerminalStartError(error)) {
        await options.onTerminalStartError(error)
        throw error
      }

      attempt++
      options.onRetry(error, attempt, maxAttempts)
      if (attempt >= maxAttempts) throw error
      await options.sleep(1000 * attempt)
    }
  }

  await options.applySystemProxy()
}

/**
 * Time-windowed circuit breaker for unexpected core exits.
 *
 * A successful start deliberately does not reset the history: a core that
 * starts and dies repeatedly is still a crash loop. The history expires only
 * after the configured stable window has elapsed.
 */
export class CrashRestartPolicy {
  private readonly windowMs: number
  private readonly maxRestarts: number
  private readonly baseDelayMs: number
  private readonly maxDelayMs: number
  private crashTimestamps: number[] = []

  constructor(options: CrashRestartPolicyOptions = {}) {
    this.windowMs = options.windowMs ?? 2 * 60 * 1000
    this.maxRestarts = options.maxRestarts ?? 5
    this.baseDelayMs = options.baseDelayMs ?? 1000
    this.maxDelayMs = options.maxDelayMs ?? 30 * 1000

    if (
      this.windowMs <= 0 ||
      this.maxRestarts < 0 ||
      this.baseDelayMs < 0 ||
      this.maxDelayMs < this.baseDelayMs
    ) {
      throw new Error('Invalid crash restart policy options')
    }
  }

  recordCrash(now = Date.now()): RestartDecision {
    const cutoff = now - this.windowMs
    this.crashTimestamps = this.crashTimestamps.filter(
      (timestamp) => timestamp > cutoff && timestamp <= now
    )
    this.crashTimestamps.push(now)

    const crashCount = this.crashTimestamps.length
    if (crashCount > this.maxRestarts) {
      return { allowed: false, crashCount, delayMs: 0 }
    }

    const delayMs = Math.min(
      this.maxDelayMs,
      this.baseDelayMs * Math.pow(2, Math.max(0, crashCount - 1))
    )
    return { allowed: true, crashCount, delayMs }
  }
}
