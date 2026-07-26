import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'fs'
import { tmpdir } from 'os'
import path from 'path'
import { afterAll, describe, expect, it } from 'vitest'
import { readDisableHardwareAccelerationSync } from './hardwareAcceleration'

const dir = mkdtempSync(path.join(tmpdir(), 'aikobox-hwaccel-'))

function writeConfig(name: string, content: string): string {
  const file = path.join(dir, name)
  writeFileSync(file, content, 'utf-8')
  return file
}

describe('readDisableHardwareAccelerationSync', () => {
  afterAll(() => {
    rmSync(dir, { recursive: true, force: true })
  })

  it('reads the flag without touching the async config pipeline', () => {
    const file = writeConfig('on.yaml', 'appTheme: dark\ndisableHardwareAcceleration: true\n')
    expect(readDisableHardwareAccelerationSync(file)).toBe(true)
  })

  it('defaults to enabled acceleration when the flag is false or absent', () => {
    expect(readDisableHardwareAccelerationSync(writeConfig('off.yaml', 'x: 1\n'))).toBe(false)
    expect(
      readDisableHardwareAccelerationSync(
        writeConfig('explicit.yaml', 'disableHardwareAcceleration: false\n')
      )
    ).toBe(false)
  })

  it('tolerates a missing, empty or corrupt config.yaml', () => {
    expect(readDisableHardwareAccelerationSync(path.join(dir, 'nope.yaml'))).toBe(false)
    expect(readDisableHardwareAccelerationSync(writeConfig('empty.yaml', ''))).toBe(false)
    expect(readDisableHardwareAccelerationSync(writeConfig('bad.yaml', 'a: [unclosed\n'))).toBe(
      false
    )
    expect(readDisableHardwareAccelerationSync(writeConfig('scalar.yaml', 'just-a-string\n'))).toBe(
      false
    )
  })
})

describe('main entry ordering', () => {
  // The defect was never the YAML read — it was that the call ran after the app
  // was ready, where Electron ignores it. index.ts has module-scope side effects
  // and cannot be imported here, so pin the ordering in the source itself.
  const source = readFileSync(path.join(__dirname, '..', 'index.ts'), 'utf-8')
    .split('\n')
    .map((line) => (line.trimStart().startsWith('//') ? '' : line))
    .join('\n')

  it('disables hardware acceleration before app.whenReady()', () => {
    const disableAt = source.indexOf('app.disableHardwareAcceleration()')
    const readyAt = source.indexOf('app.whenReady()')
    expect(disableAt).toBeGreaterThan(-1)
    expect(readyAt).toBeGreaterThan(-1)
    expect(disableAt).toBeLessThan(readyAt)
  })

  it('reads the flag only after the portable userData path is final', () => {
    const portableAt = source.indexOf('configurePortableUserData()')
    const readAt = source.indexOf('readDisableHardwareAccelerationSync(')
    expect(portableAt).toBeGreaterThan(-1)
    expect(readAt).toBeGreaterThan(portableAt)
  })
})
