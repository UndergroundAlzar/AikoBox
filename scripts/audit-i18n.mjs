import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(scriptDirectory, '..')
const baseLocale = 'en-US'
const sourceExtensions = new Set(['.ts', '.tsx'])
// t('a.b') / t("a.b") / t(`a.b`); \b keeps this off it(), split() and friends
const translationCall = /\bt\(\s*(['"`])((?:\\.|(?!\1)[^\\])*)\1/g

function invariant(condition, message) {
  if (!condition) throw new Error(message)
}

function comparableFsPath(filePath) {
  const normalized = path.normalize(filePath).replace(/^\\\\\?\\/, '')
  return process.platform === 'win32' ? normalized.toLowerCase() : normalized
}

export function flattenLocaleKeys(value, prefix = '', keys = new Set()) {
  invariant(value !== null && typeof value === 'object', 'locale resource must be an object')
  for (const [name, child] of Object.entries(value)) {
    const key = prefix ? `${prefix}.${name}` : name
    if (child !== null && typeof child === 'object' && !Array.isArray(child)) {
      flattenLocaleKeys(child, key, keys)
    } else {
      keys.add(key)
    }
  }
  return keys
}

/** the key i18next sees at runtime, not the raw source text: t('it\'s.here') is "it's.here" */
function decodeStringLiteral(literal) {
  return literal.replace(/\\(.)/g, '$1')
}

/**
 * Known blind spot: only `t('literal')` is visible here. A key reached through a
 * variable — `safeShowErrorBox(titleKey)` in src/main/utils/init.ts, the
 * titleMap/sizeMap tables in sider-config.tsx — is invisible to this gate, and
 * so is an individual `plugins.status.<value>` once one sibling exists. Those
 * still have to be reviewed by hand.
 */
export function extractTranslationKeys(source) {
  const keys = new Set()
  const dynamicPrefixes = new Set()
  for (const [, quote, literal] of source.matchAll(translationCall)) {
    if (quote === '`' && literal.includes('${')) {
      // t(`plugins.status.${x}`) is only checkable through its static prefix
      const prefix = decodeStringLiteral(literal.slice(0, literal.indexOf('${')))
      if (prefix.endsWith('.')) dynamicPrefixes.add(prefix)
      continue
    }
    if (literal.length > 0) keys.add(decodeStringLiteral(literal))
  }
  return { keys, dynamicPrefixes }
}

export function collectSourceFiles(directory, files = []) {
  for (const entry of fs
    .readdirSync(directory, { withFileTypes: true })
    .sort((a, b) => a.name.localeCompare(b.name))) {
    const entryPath = path.join(directory, entry.name)
    if (entry.isDirectory()) {
      if (entry.name !== 'node_modules') collectSourceFiles(entryPath, files)
    } else if (sourceExtensions.has(path.extname(entry.name))) {
      files.push(entryPath)
    }
  }
  return files
}

export function findUnresolvedKeys(usedKeys, dynamicPrefixes, baseKeys) {
  const unresolved = [...usedKeys].filter((key) => !baseKeys.has(key))
  for (const prefix of dynamicPrefixes) {
    if (![...baseKeys].some((key) => key.startsWith(prefix))) unresolved.push(`${prefix}*`)
  }
  return unresolved.sort()
}

export function findMissingLocaleKeys(baseKeys, localeKeys) {
  return [...baseKeys].filter((key) => !localeKeys.has(key)).sort()
}

export function inspectLocales(root = repositoryRoot) {
  const localeDirectory = path.join(root, 'src', 'renderer', 'src', 'locales')
  const sourceDirectory = path.join(root, 'src')
  invariant(fs.existsSync(localeDirectory), 'Locale directory is missing')
  invariant(fs.existsSync(sourceDirectory), 'Source directory is missing')

  const localeFiles = fs
    .readdirSync(localeDirectory)
    .filter((name) => name.endsWith('.json'))
    .sort()
  invariant(localeFiles.includes(`${baseLocale}.json`), `Base locale ${baseLocale}.json is missing`)

  const keysByLocale = new Map()
  for (const file of localeFiles) {
    const locale = path.basename(file, '.json')
    const contents = fs.readFileSync(path.join(localeDirectory, file), 'utf8')
    let resource
    try {
      resource = JSON.parse(contents)
    } catch (error) {
      throw new Error(`${locale}: locale file is not valid JSON (${error.message})`)
    }
    keysByLocale.set(locale, flattenLocaleKeys(resource))
  }

  const baseKeys = keysByLocale.get(baseLocale)
  const usedKeys = new Set()
  const dynamicPrefixes = new Set()
  const sourceFiles = collectSourceFiles(sourceDirectory)
  for (const file of sourceFiles) {
    const extracted = extractTranslationKeys(fs.readFileSync(file, 'utf8'))
    for (const key of extracted.keys) usedKeys.add(key)
    for (const prefix of extracted.dynamicPrefixes) dynamicPrefixes.add(prefix)
  }

  const missingByLocale = new Map()
  for (const [locale, keys] of keysByLocale) {
    if (locale === baseLocale) continue
    const missing = findMissingLocaleKeys(baseKeys, keys)
    if (missing.length > 0) missingByLocale.set(locale, missing)
  }

  return {
    baseKeyCount: baseKeys.size,
    locales: [...keysByLocale.keys()],
    sourceFileCount: sourceFiles.length,
    usedKeyCount: usedKeys.size,
    unresolvedKeys: findUnresolvedKeys(usedKeys, dynamicPrefixes, baseKeys),
    missingByLocale
  }
}

export function runAudit(root = repositoryRoot) {
  try {
    const report = inspectLocales(root)

    if (report.unresolvedKeys.length > 0) {
      console.error(
        `[BLOCKED] Translation keys used in src/ but absent from ${baseLocale}: ${report.unresolvedKeys.join(', ')}`
      )
    } else {
      console.log(
        `[OK] ${report.usedKeyCount} translation keys used across ${report.sourceFileCount} source files resolve in ${baseLocale}`
      )
    }

    for (const [locale, missing] of report.missingByLocale) {
      console.error(
        `[BLOCKED] ${locale} is missing ${missing.length} keys present in ${baseLocale}: ${missing.join(', ')}`
      )
    }
    if (report.missingByLocale.size === 0) {
      console.log(
        `[OK] ${report.locales.length - 1} additional locales cover every ${baseLocale} key (${report.baseKeyCount} keys)`
      )
    }

    if (report.unresolvedKeys.length > 0 || report.missingByLocale.size > 0) {
      process.exitCode = 1
    }
  } catch (error) {
    console.error(`[FATAL] i18n audit failed: ${error instanceof Error ? error.message : error}`)
    process.exitCode = 1
  }
}

const entrypoint = process.argv[1] && path.resolve(process.argv[1])
if (
  entrypoint &&
  comparableFsPath(entrypoint) === comparableFsPath(fileURLToPath(import.meta.url))
) {
  runAudit()
}
