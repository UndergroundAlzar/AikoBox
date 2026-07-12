import { describe, expect, it } from 'vitest'
import { assertManagedOverrideExtension, assertSafeManagedConfigId } from './managedConfigId'

describe('managed configuration path inputs', () => {
  it('accepts generated identifiers and the default profile id', () => {
    expect(() => assertSafeManagedConfigId('default', 'profile')).not.toThrow()
    expect(() => assertSafeManagedConfigId('profile_Aiko-01.2', 'profile')).not.toThrow()
  })

  it('rejects traversal, separators, empty values, and overlong identifiers', () => {
    for (const id of ['', '.', '..', '../outside', '..\\outside', 'a/b', 'a\\b', 'a'.repeat(129)]) {
      expect(() => assertSafeManagedConfigId(id, 'profile')).toThrow(/invalid profile id/i)
    }
  })

  it('allows only managed override file extensions', () => {
    expect(() => assertManagedOverrideExtension('js')).not.toThrow()
    expect(() => assertManagedOverrideExtension('yaml')).not.toThrow()
    expect(() => assertManagedOverrideExtension('exe')).toThrow(/extension/i)
    expect(() => assertManagedOverrideExtension('../cmd.exe')).toThrow(/extension/i)
  })
})
