export interface LegacySubStoreMigrationResult {
  config: IProfileConfig
  changed: boolean
}

function isOriginRelativePath(url: unknown): url is string {
  return typeof url === 'string' && url.startsWith('/') && !url.startsWith('//')
}

/**
 * Convert profiles that depended on the retired loopback Sub-Store runtime to
 * local profiles. Their already-downloaded YAML remains the source of truth;
 * this transform never reads or writes profile content.
 */
export function migrateLegacySubStoreProfiles(
  config: IProfileConfig
): LegacySubStoreMigrationResult {
  let changed = false
  const items = (Array.isArray(config.items) ? config.items : []).map((item) => {
    if (item.type !== 'remote' || item.substore !== true || !isOriginRelativePath(item.url)) {
      return item
    }

    changed = true
    const { substore: _retired, ...preserved } = item
    return {
      ...preserved,
      type: 'local' as const,
      autoUpdate: false,
      interval: 0
    }
  })

  if (!changed) return { config, changed: false }
  return { config: { ...config, items }, changed: true }
}
