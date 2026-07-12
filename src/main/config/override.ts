import { readFile, writeFile, rm } from 'fs/promises'
import { existsSync } from 'fs'
import { overrideConfigPath, overridePath } from '../utils/dirs'
import * as chromeRequest from '../utils/chromeRequest'
import { parse, stringify } from '../utils/yaml'
import { DEFAULT_MIHOMO_PORTS } from '../../shared/appConfig'
import { getControledMihomoConfig } from './controledMihomo'

let overrideConfig: IOverrideConfig // override.yaml
let overrideConfigWriteQueue: Promise<void> = Promise.resolve()

function assertSafeOverrideId(id: string): void {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(id) || id === '.' || id === '..') {
    throw new Error('Invalid override id')
  }
}

export async function getOverrideConfig(force = false): Promise<IOverrideConfig> {
  if (force || !overrideConfig) {
    const data = await readFile(overrideConfigPath(), 'utf-8')
    overrideConfig = parse(data) || { items: [] }
  }
  if (typeof overrideConfig !== 'object') overrideConfig = { items: [] }
  if (!Array.isArray(overrideConfig.items)) overrideConfig.items = []
  return overrideConfig
}

export async function setOverrideConfig(config: IOverrideConfig): Promise<void> {
  for (const item of config.items || []) assertSafeOverrideId(item.id)
  overrideConfigWriteQueue = overrideConfigWriteQueue.then(async () => {
    overrideConfig = config
    await writeFile(overrideConfigPath(), stringify(overrideConfig), 'utf-8')
  })
  await overrideConfigWriteQueue
}

export async function getOverrideItem(id: string | undefined): Promise<IOverrideItem | undefined> {
  if (id !== undefined) assertSafeOverrideId(id)
  const { items } = await getOverrideConfig()
  return items.find((item) => item.id === id)
}

export async function updateOverrideItem(item: IOverrideItem): Promise<void> {
  assertSafeOverrideId(item.id)
  const config = await getOverrideConfig()
  const index = config.items.findIndex((i) => i.id === item.id)
  if (index === -1) {
    throw new Error('Override not found')
  }
  config.items[index] = item
  await setOverrideConfig(config)
}

export async function addOverrideItem(item: Partial<IOverrideItem>): Promise<void> {
  const config = await getOverrideConfig()
  const newItem = await createOverride(item)
  if (await getOverrideItem(item.id)) {
    await updateOverrideItem(newItem)
  } else {
    config.items.push(newItem)
    await setOverrideConfig(config)
  }
}

export async function removeOverrideItem(id: string): Promise<void> {
  assertSafeOverrideId(id)
  const config = await getOverrideConfig()
  const item = await getOverrideItem(id)
  if (!item) return
  config.items = config.items?.filter((i) => i.id !== id)
  await setOverrideConfig(config)
  if (existsSync(overridePath(id, item.ext))) {
    await rm(overridePath(id, item.ext))
  }
}

export async function createOverride(item: Partial<IOverrideItem>): Promise<IOverrideItem> {
  const id = item.id || new Date().getTime().toString(16)
  assertSafeOverrideId(id)
  const newItem = {
    id,
    name: item.name || (item.type === 'remote' ? 'Remote File' : 'Local File'),
    type: item.type,
    ext: item.ext || (process.platform === 'win32' ? 'yaml' : 'js'),
    url: item.url,
    global: item.global || false,
    updated: new Date().getTime()
  } as IOverrideItem
  if (process.platform === 'win32' && newItem.ext === 'js') {
    throw new Error('JavaScript overrides are disabled on Windows; use a YAML override')
  }
  switch (newItem.type) {
    case 'remote': {
      const { 'mixed-port': mixedPort = DEFAULT_MIHOMO_PORTS.mixed } =
        await getControledMihomoConfig()
      if (!item.url) throw new Error('Empty URL')
      const res = await chromeRequest.get(item.url, {
        proxy: {
          protocol: 'http',
          host: '127.0.0.1',
          port: mixedPort
        },
        responseType: 'text'
      })
      const data = res.data as string
      await setOverride(id, newItem.ext, data)
      break
    }
    case 'local': {
      const data = item.file || ''
      await setOverride(id, newItem.ext, data)
      break
    }
  }

  return newItem
}

export async function getOverride(id: string, ext: 'js' | 'yaml' | 'log'): Promise<string> {
  assertSafeOverrideId(id)
  if (!existsSync(overridePath(id, ext))) {
    return ''
  }
  return await readFile(overridePath(id, ext), 'utf-8')
}

export async function setOverride(id: string, ext: 'js' | 'yaml', content: string): Promise<void> {
  assertSafeOverrideId(id)
  if (process.platform === 'win32' && ext === 'js') {
    throw new Error('JavaScript overrides are disabled on Windows; use a YAML override')
  }
  await writeFile(overridePath(id, ext), content, 'utf-8')
}
