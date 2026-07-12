import { describe, expect, it } from 'vitest'
import {
  matchesProcessIdentity,
  parseProcessIdentityRecord,
  type ProcessIdentity
} from './processIdentity'

describe('process identity journal', () => {
  it('parses only fully versioned ownership records', () => {
    expect(parseProcessIdentityRecord('123')).toBeNull()
    expect(
      parseProcessIdentityRecord(
        JSON.stringify({
          version: 2,
          pid: 456,
          executablePath: 'C:\\AikoBox\\TrafficMonitor.exe',
          startTimeMs: 10_000,
          commandLine: 'TrafficMonitor.exe --aikobox'
        })
      )
    ).toEqual({
      pid: 456,
      executablePath: 'C:\\AikoBox\\TrafficMonitor.exe',
      startTimeMs: 10_000,
      commandLine: 'TrafficMonitor.exe --aikobox'
    })
    expect(parseProcessIdentityRecord('0')).toBeNull()
    expect(parseProcessIdentityRecord('{"version":1,"pid":2}')).toBeNull()
  })

  it('requires the expected executable and rejects PID reuse', () => {
    const actual: ProcessIdentity = {
      pid: 42,
      executablePath: 'C:\\AikoBox\\TrafficMonitor.exe',
      startTimeMs: 20_000,
      commandLine: 'TrafficMonitor.exe --aikobox'
    }

    expect(
      matchesProcessIdentity(
        {
          pid: 42,
          executablePath: 'C:\\AikoBox\\TrafficMonitor.exe',
          startTimeMs: 20_500,
          commandLine: actual.commandLine
        },
        actual,
        'C:\\AikoBox\\TrafficMonitor.exe'
      )
    ).toBe(true)
    expect(
      matchesProcessIdentity(
        {
          pid: 42,
          executablePath: actual.executablePath,
          startTimeMs: 30_000,
          commandLine: actual.commandLine
        },
        actual,
        actual.executablePath
      )
    ).toBe(false)
    expect(
      matchesProcessIdentity(
        { pid: 42, commandLine: actual.commandLine },
        { ...actual, executablePath: 'C:\\Other.exe' },
        actual.executablePath
      )
    ).toBe(false)
    expect(
      matchesProcessIdentity(
        { ...actual, commandLine: 'TrafficMonitor.exe --different' },
        actual,
        actual.executablePath
      )
    ).toBe(false)
  })
})
