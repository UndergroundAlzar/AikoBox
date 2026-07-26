import { readFileSync } from 'fs'
import { parse } from './yaml'

/**
 * app.disableHardwareAcceleration() is ignored once the ready event fires, and
 * the full config pipeline (initBasic + getAppConfig) always loses that race.
 * Read this one boolean synchronously instead; a missing or corrupt config.yaml
 * must not block startup, so it falls back to the default (acceleration on).
 */
export function readDisableHardwareAccelerationSync(configPath: string): boolean {
  try {
    const config = parse<Partial<IAppConfig>>(readFileSync(configPath, 'utf-8'))
    return config?.disableHardwareAcceleration === true
  } catch {
    return false
  }
}
