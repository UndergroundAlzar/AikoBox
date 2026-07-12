export interface StoredRecoveryActions<TCandidate, TConfig> {
  prepare: (candidate: TCandidate) => Promise<TConfig>
  startOnce: (config: TConfig) => Promise<TConfig>
  publish: (runningConfig: TConfig, candidate: TCandidate) => Promise<void>
  resume: (runningConfig: TConfig) => Promise<void>
  onCandidateError?: (candidate: TCandidate, error: unknown) => void | Promise<void>
  onPublishError?: (candidate: TCandidate, error: unknown) => void | Promise<void>
}

/** Try each immutable stored config once. Only a proven-running config is
 * published, and stale WinINET ownership resumes strictly after publication. */
export async function recoverFromStoredCandidates<TCandidate, TConfig>(
  candidates: readonly TCandidate[],
  actions: StoredRecoveryActions<TCandidate, TConfig>
): Promise<TConfig> {
  const errors: unknown[] = []
  for (const candidate of candidates) {
    try {
      const config = await actions.prepare(candidate)
      const runningConfig = await actions.startOnce(config)
      try {
        await actions.publish(runningConfig, candidate)
      } catch (error) {
        await actions.onPublishError?.(candidate, error)
      }
      await actions.resume(runningConfig)
      return runningConfig
    } catch (error) {
      errors.push(error)
      await actions.onCandidateError?.(candidate, error)
    }
  }
  throw new AggregateError(errors, 'Every stored exact-endpoint recovery config failed')
}
