import { readdir, readFile, stat } from 'fs/promises'
import path from 'path'
import { existsSync } from 'fs'
import AdmZip from 'adm-zip'
import { t } from 'i18next'
import { themesDir } from '../utils/dirs'
import * as chromeRequest from '../utils/chromeRequest'
import { getControledMihomoConfig } from '../config'
import { DEFAULT_MIHOMO_PORTS } from '../../shared/appConfig'
import { mainWindow } from '../window'
import { consumeSelectedFileCapability } from '../sys/misc'
import { writeFileAtomically } from '../config/remoteResource'
import { floatingWindow } from './floatingWindow'

let insertedCSSKeyMain: string | undefined = undefined
let insertedCSSKeyFloating: string | undefined = undefined

function themePath(theme: string): string {
  if (path.basename(theme) !== theme || !/^[A-Za-z0-9][A-Za-z0-9._-]*\.css$/.test(theme)) {
    throw new Error('Invalid theme filename')
  }
  return path.join(themesDir(), theme)
}

export async function resolveThemes(): Promise<{ key: string; label: string }[]> {
  const files = await readdir(themesDir())
  const themes = await Promise.all(
    files
      .filter((file) => file.endsWith('.css'))
      .map(async (file) => {
        const css = (await readFile(path.join(themesDir(), file), 'utf-8')) || ''
        let name = file
        if (css.startsWith('/*')) {
          name = css.split('\n')[0].replace('/*', '').replace('*/', '').trim() || file
        }
        return { key: file, label: name }
      })
  )
  if (themes.find((theme) => theme.key === 'default.css')) {
    return themes
  } else {
    return [{ key: 'default.css', label: t('common.default') }, ...themes]
  }
}

export async function fetchThemes(): Promise<void> {
  const zipUrl = 'https://github.com/mihomo-party-org/theme-hub/releases/download/latest/themes.zip'
  const { 'mixed-port': mixedPort = DEFAULT_MIHOMO_PORTS.mixed } = await getControledMihomoConfig()
  const zipData = await chromeRequest.get(zipUrl, {
    responseType: 'arraybuffer',
    headers: { 'Content-Type': 'application/octet-stream' },
    proxy: {
      protocol: 'http',
      host: '127.0.0.1',
      port: mixedPort
    }
  })
  const bytes = Buffer.from(zipData.data as Buffer)
  if (bytes.length > 16 * 1024 * 1024) throw new Error('Theme archive exceeds 16 MiB')
  const zip = new AdmZip(bytes)
  const entries = zip.getEntries().filter((entry) => !entry.isDirectory)
  let total = 0
  for (const entry of entries) {
    const name = path.posix.basename(entry.entryName)
    if (entry.entryName !== name || !/^[A-Za-z0-9][A-Za-z0-9._-]*\.css$/.test(name)) {
      throw new Error(`Unsafe theme archive entry: ${entry.entryName}`)
    }
    total += entry.header.size
    if (total > 32 * 1024 * 1024) throw new Error('Expanded themes exceed 32 MiB')
    await writeFileAtomically(themePath(name), entry.getData().toString('utf8'))
  }
}

export async function importThemes(files: string[]): Promise<void> {
  for (const file of files) {
    const selected = consumeSelectedFileCapability(file)
    if (path.extname(selected).toLowerCase() !== '.css') throw new Error('Theme must be a CSS file')
    if ((await stat(selected)).size > 2 * 1024 * 1024) throw new Error('Theme exceeds 2 MiB')
    await writeFileAtomically(
      themePath(`${new Date().getTime().toString(16)}-${path.basename(selected)}`),
      await readFile(selected, 'utf8')
    )
  }
}

export async function readTheme(theme: string): Promise<string> {
  const target = themePath(theme)
  if (!existsSync(target)) return ''
  return await readFile(target, 'utf-8')
}

export async function writeTheme(theme: string, css: string): Promise<void> {
  if (Buffer.byteLength(css, 'utf8') > 2 * 1024 * 1024) throw new Error('Theme exceeds 2 MiB')
  await writeFileAtomically(themePath(theme), css)
}

export async function applyTheme(theme: string): Promise<void> {
  const css = await readTheme(theme)
  await mainWindow?.webContents.removeInsertedCSS(insertedCSSKeyMain || '')
  insertedCSSKeyMain = await mainWindow?.webContents.insertCSS(css)
  try {
    await floatingWindow?.webContents.removeInsertedCSS(insertedCSSKeyFloating || '')
    insertedCSSKeyFloating = await floatingWindow?.webContents.insertCSS(css)
  } catch {
    // ignore
  }
}
