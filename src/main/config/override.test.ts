import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import { join } from 'path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const mocks = vi.hoisted(() => ({ root: '' }))

vi.mock('../utils/dirs', () => ({
  overrideConfigPath: () => join(mocks.root, 'override.yaml'),
  overridePath: (id: string, ext: string) => join(mocks.root, 'overrides', `${id}.${ext}`)
}))
vi.mock('../utils/chromeRequest', () => ({ get: vi.fn() }))
vi.mock('./controledMihomo', () => ({
  getControledMihomoConfig: vi.fn(async () => ({ 'mixed-port': 7890 }))
}))

describe('override path safety', () => {
  beforeEach(() => {
    vi.resetModules()
    mocks.root = mkdtempSync(join(tmpdir(), 'aikobox-override-'))
    mkdirSync(join(mocks.root, 'overrides'))
    writeFileSync(join(mocks.root, 'override.yaml'), 'items: []\n')
  })

  afterEach(() => rmSync(mocks.root, { recursive: true, force: true }))

  it('rejects traversal ids on every write entry point', async () => {
    const { createOverride, setOverride, setOverrideConfig } = await import('./override')
    await expect(setOverride('..\\escape', 'yaml', 'x')).rejects.toThrow(/Invalid override id/)
    await expect(
      createOverride({ id: '../escape', type: 'local', ext: 'yaml', file: 'x' })
    ).rejects.toThrow(/Invalid override id/)
    await expect(
      setOverrideConfig({ items: [{ id: '..', name: 'bad', ext: 'yaml' }] } as IOverrideConfig)
    ).rejects.toThrow(/Invalid override id/)
  })
})
