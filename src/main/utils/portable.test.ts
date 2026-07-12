import path from 'path'
import { describe, expect, it } from 'vitest'
import {
  isExecutableWithinWindowsProgramFiles,
  isWindowsTunElevationAllowed,
  portableRootFromEnvironment
} from './portable'

describe('portableRootFromEnvironment', () => {
  it('uses the original portable executable directory instead of the temp unpack directory', () => {
    const root = path.resolve('C:\\Users\\Alice\\Tools')
    expect(
      portableRootFromEnvironment({
        PORTABLE_EXECUTABLE_DIR: root,
        PORTABLE_EXECUTABLE_FILE: path.join(root, 'aikobox-portable.exe')
      })
    ).toBe(root)
  })

  it('supports either electron-builder portable variable independently', () => {
    const root = path.resolve('D:\\Portable')
    expect(portableRootFromEnvironment({ PORTABLE_EXECUTABLE_DIR: root })).toBe(root)
    expect(
      portableRootFromEnvironment({
        PORTABLE_EXECUTABLE_FILE: path.join(root, 'AikoBox.exe')
      })
    ).toBe(root)
  })

  it('rejects relative or inconsistent environment paths', () => {
    expect(portableRootFromEnvironment({ PORTABLE_EXECUTABLE_DIR: '..\\redirect' })).toBeNull()
    expect(
      portableRootFromEnvironment({
        PORTABLE_EXECUTABLE_DIR: path.resolve('C:\\Safe'),
        PORTABLE_EXECUTABLE_FILE: path.resolve('D:\\Other\\AikoBox.exe')
      })
    ).toBeNull()
  })
})

describe('isWindowsTunElevationAllowed', () => {
  const installedEnvironment = {
    ProgramFiles: 'C:\\Program Files',
    ProgramW6432: 'C:\\Program Files'
  }

  it('allows only a packaged AikoBox installation below 64-bit Program Files', () => {
    expect(
      isWindowsTunElevationAllowed(
        'C:\\Program Files\\AikoBox\\AikoBox.exe',
        installedEnvironment,
        true
      )
    ).toBe(true)
    expect(
      isWindowsTunElevationAllowed(
        'c:\\PROGRAM FILES\\AIKOBOX\\AIKOBOX.EXE',
        installedEnvironment,
        true
      )
    ).toBe(true)
  })

  it('rejects development and user-writable installations', () => {
    expect(
      isWindowsTunElevationAllowed(
        'C:\\Program Files\\AikoBox\\AikoBox.exe',
        installedEnvironment,
        false
      )
    ).toBe(false)
    expect(
      isWindowsTunElevationAllowed(
        'C:\\Users\\Alice\\Apps\\AikoBox.exe',
        installedEnvironment,
        true
      )
    ).toBe(false)
  })

  it('rejects portable builds even when their extraction path is trusted', () => {
    expect(
      isWindowsTunElevationAllowed(
        'C:\\Program Files\\AikoBox\\AikoBox.exe',
        {
          ...installedEnvironment,
          PORTABLE_EXECUTABLE_FILE: 'D:\\Downloads\\aikobox-portable.exe'
        },
        true
      )
    ).toBe(false)
    expect(
      isWindowsTunElevationAllowed(
        'C:\\Program Files\\AikoBox\\AikoBox.exe',
        {
          ...installedEnvironment,
          PORTABLE_EXECUTABLE_DIR: '..\\malformed-portable-marker'
        },
        true
      )
    ).toBe(false)
  })

  it('does not trust a nested lookalike or a renamed executable', () => {
    expect(
      isWindowsTunElevationAllowed(
        'C:\\Users\\Alice\\Program Files\\AikoBox\\AikoBox.exe',
        {
          ProgramFiles: 'C:\\Users\\Alice\\Program Files',
          ProgramW6432: 'C:\\Users\\Alice\\Program Files'
        },
        true
      )
    ).toBe(false)
    expect(
      isWindowsTunElevationAllowed(
        'C:\\Program Files\\AikoBox\\renamed.exe',
        installedEnvironment,
        true
      )
    ).toBe(false)
  })
})

describe('isExecutableWithinWindowsProgramFiles', () => {
  it('uses the OS-resolved Program Files root instead of trusting a lookalike environment path', () => {
    expect(
      isExecutableWithinWindowsProgramFiles(
        'C:\\Program Files\\AikoBox\\AikoBox.exe',
        'C:\\Program Files'
      )
    ).toBe(true)
    expect(
      isExecutableWithinWindowsProgramFiles(
        'D:\\Program Files\\AikoBox\\AikoBox.exe',
        'C:\\Program Files'
      )
    ).toBe(false)
  })
})
