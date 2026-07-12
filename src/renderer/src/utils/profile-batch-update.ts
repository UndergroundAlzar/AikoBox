export interface ProfileBatchFailure {
  id: string
  name: string
  kind: ProfileBatchFailureKind
}

export type ProfileBatchFailureKind =
  | 'authentication'
  | 'backoff'
  | 'invalid-content'
  | 'network'
  | 'not-found'
  | 'unknown'

export interface ProfileBatchResult {
  total: number
  succeeded: number
  failed: number
  failures: ProfileBatchFailure[]
}

function classifyFailure(error: unknown): ProfileBatchFailureKind {
  const message = (error instanceof Error ? error.message : String(error)).toLowerCase()
  if (
    message.includes('plugin_update_login_required') ||
    message.includes('plugin_update_reauth_required') ||
    /\b(?:401|403|unauthori[sz]ed|forbidden|authentication)\b/.test(message)
  ) {
    return 'authentication'
  }
  if (message.includes('plugin_update_not_found') || /\bnot found\b/.test(message)) {
    return 'not-found'
  }
  if (message.includes('plugin_update_backoff')) return 'backoff'
  if (
    message.includes('plugin_update_network') ||
    /\b(?:network|timeout|timed out|econnrefused|enotfound|fetch failed)\b/.test(message)
  ) {
    return 'network'
  }
  if (/\b(?:yaml|parse|syntax|invalid content|html response)\b/.test(message)) {
    return 'invalid-content'
  }
  return 'unknown'
}

function isUpdatableProfile(item: IProfileItem): boolean {
  return item.type === 'remote' || (item.type === 'plugin' && Boolean(item.pluginId))
}

/**
 * Refresh profiles sequentially so that one failed subscription does not block
 * the others. The active profile is deliberately refreshed last because its
 * successful update may restart the managed core.
 */
export async function runProfileBatchUpdate(
  items: IProfileItem[],
  currentId: string | undefined,
  update: (item: IProfileItem) => Promise<void>
): Promise<ProfileBatchResult> {
  const targets = items.filter(isUpdatableProfile)
  const orderedTargets = [
    ...targets.filter((item) => item.id !== currentId),
    ...targets.filter((item) => item.id === currentId)
  ]
  const failures: ProfileBatchFailure[] = []

  for (const item of orderedTargets) {
    try {
      await update(item)
    } catch (error) {
      failures.push({
        id: item.id,
        name: item.name || item.id,
        kind: classifyFailure(error)
      })
    }
  }

  return {
    total: orderedTargets.length,
    succeeded: orderedTargets.length - failures.length,
    failed: failures.length,
    failures
  }
}
