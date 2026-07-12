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

/**
 * Serializes endpoint recovery and lets every concurrent caller await the same
 * proof of health. A running process alone is never success; isHealthy must
 * attest that the exact listener is ready.
 */
export class ExactEndpointGuardian {
  private active: ActiveGuardian | null = null

  ensure(request: ExactEndpointGuardianRequest): Promise<void> {
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

      try {
        await request.attempt()
      } catch (error) {
        await request.onAttemptError?.(error, attempt)
      }
    }
  }
}
