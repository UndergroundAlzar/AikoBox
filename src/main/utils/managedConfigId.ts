const MANAGED_CONFIG_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/

export function assertSafeManagedConfigId(id: unknown, label = 'config'): asserts id is string {
  if (typeof id !== 'string' || !MANAGED_CONFIG_ID_PATTERN.test(id) || id === '.' || id === '..') {
    throw new Error(`Invalid ${label} id`)
  }
}

export function assertManagedOverrideExtension(
  extension: unknown
): asserts extension is 'js' | 'yaml' | 'log' {
  if (extension !== 'js' && extension !== 'yaml' && extension !== 'log') {
    throw new Error('Invalid override file extension')
  }
}
