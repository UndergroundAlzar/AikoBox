export interface ExactEndpoint {
  host: string
  port: number
}

export interface ExactEndpointGuardianRequest {
  endpoint: ExactEndpoint
  isHealthy: () => boolean | Promise<boolean>
  attempt: () => Promise<void>
  onAttemptError?: (error: unknown, attempt: number) => void | Promise<void>
  delay?: (milliseconds: number) => Promise<void>
}

interface ActiveGuardian {
  key: string
  requests: ExactEndpointGuardianRequest[]
  promise: Promise<void>
}

function endpointKey(endpoint: ExactEndpoint): string {
  return `${endpoint.host}:${endpoint.port}`
}

let guardianShutdown = false

/**
 * Quitting must win any in-flight recovery. An attempt started after shutdown
 * begins spawns a core the app will never own again: it keeps the TUN adapter
 * and the user's traffic long after the process is gone.
 */
export function beginExactEndpointGuardianShutdown(): void {
  guardianShutdown = true
}

export function cancelExactEndpointGuardianShutdown(): void {
  guardianShutdown = false
}

export function isExactEndpointGuardianShutdown(): boolean {
  return guardianShutdown
}

function shutdownError(): Error {
  return new Error('Exact endpoint recovery aborted because AikoBox is shutting down')
}

/**
 * Serializes endpoint recovery and lets every concurrent caller await the same
 * proof of health. A running process alone is never success; isHealthy must
 * attest that the exact listener is ready.
 */
export class ExactEndpointGuardian {
  private active: ActiveGuardian | null = null

  ensure(request: ExactEndpointGuardianRequest): Promise<void> {
    if (guardianShutdown) return Promise.reject(shutdownError())
    const key = endpointKey(request.endpoint)
    if (this.active) {
      if (this.active.key !== key) {
        return Promise.reject(
          new Error(`A proxy guardian is already recovering ${this.active.key}, not ${key}`)
        )
      }
      this.active.requests.push(request)
      return this.active.promise
    }

    const active: ActiveGuardian = {
      key,
      requests: [request],
      promise: Promise.resolve()
    }
    const promise = this.run(active).finally(() => {
      if (this.active?.promise === promise) this.active = null
    })
    active.promise = promise
    this.active = active
    return promise
  }

  private async run(active: ActiveGuardian): Promise<void> {
    let attempt = 0
    let cursor = 0

    while (true) {
      for (const candidate of active.requests) {
        if (await candidate.isHealthy()) return
      }
      if (guardianShutdown) throw shutdownError()
      attempt += 1
      const request = active.requests[cursor % active.requests.length]
      cursor += 1
      if (attempt > 1) {
        const delay =
          request.delay ??
          ((milliseconds: number) => new Promise((resolve) => setTimeout(resolve, milliseconds)))
        await delay(Math.min(30_000, 1_000 * 2 ** Math.min(attempt - 2, 5)))
      }
      for (const candidate of active.requests) {
        if (await candidate.isHealthy()) return
      }
      // Shutdown may have begun during the backoff or the health sweep; a spawn
      // from here would outlive the app.
      if (guardianShutdown) throw shutdownError()

      try {
        await request.attempt()
      } catch (error) {
        await request.onAttemptError?.(error, attempt)
      }
    }
  }
}
