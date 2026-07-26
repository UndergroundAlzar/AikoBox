import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import test from 'node:test'
import { fileURLToPath } from 'node:url'
import {
  collectSourceFiles,
  extractTranslationKeys,
  findMissingLocaleKeys,
  findUnresolvedKeys,
  flattenLocaleKeys,
  inspectLocales
} from './audit-i18n.mjs'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const auditScript = path.join(repositoryRoot, 'scripts', 'audit-i18n.mjs')

function runAudit(...arguments_) {
  return spawnSync(process.execPath, [auditScript, ...arguments_], {
    cwd: repositoryRoot,
    encoding: 'utf8',
    windowsHide: true
  })
}

function createFixture(locales, sources) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'aikobox-i18n-'))
  const localeDirectory = path.join(root, 'src', 'renderer', 'src', 'locales')
  fs.mkdirSync(localeDirectory, { recursive: true })
  for (const [locale, resource] of Object.entries(locales)) {
    fs.writeFileSync(path.join(localeDirectory, `${locale}.json`), JSON.stringify(resource))
  }
  for (const [name, contents] of Object.entries(sources)) {
    fs.writeFileSync(path.join(root, 'src', name), contents)
  }
  return root
}

test('every translation key used in src/ resolves and all locales match en-US', () => {
  const result = runAudit()
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  assert.match(result.stdout, /translation keys used across \d+ source files resolve in en-US/)
  assert.match(result.stdout, /4 additional locales cover every en-US key/)
  assert.doesNotMatch(result.stderr, /\[BLOCKED\]/)
  assert.doesNotMatch(result.stderr, /\[FATAL\]/)
})

test('the shipped locales all expose the same key set', () => {
  const report = inspectLocales(repositoryRoot)
  assert.deepEqual(report.locales.sort(), ['en-US', 'fa-IR', 'ru-RU', 'zh-CN', 'zh-TW'])
  assert.deepEqual([...report.missingByLocale.keys()], [])
  assert.deepEqual(report.unresolvedKeys, [])
})

test('the Plugins flow and the TUN permission failure are translated everywhere', () => {
  const localeDirectory = path.join(repositoryRoot, 'src', 'renderer', 'src', 'locales')
  for (const locale of ['en-US', 'zh-CN', 'zh-TW', 'ru-RU', 'fa-IR']) {
    const keys = flattenLocaleKeys(
      JSON.parse(fs.readFileSync(path.join(localeDirectory, `${locale}.json`), 'utf8'))
    )
    for (const key of [
      'plugins.install',
      'plugins.removeConfirm',
      'plugins.status.needs-login',
      'tun.error.tunPermissionDenied',
      'common.error.importFailed',
      'common.error.restartCoreFailed',
      'profiles.editRules.invalidPayload',
      'webdav.notification.cronUpdated',
      'webdav.notification.cronUpdateFailed'
    ]) {
      assert.ok(keys.has(key), `${locale} is missing ${key}`)
    }
  }
})

test('nested resources flatten into dotted keys', () => {
  const keys = flattenLocaleKeys({
    'common.ok': 'OK',
    plugins: { install: 'Install', status: { active: 'Active' } }
  })
  assert.deepEqual([...keys].sort(), ['common.ok', 'plugins.install', 'plugins.status.active'])
  assert.throws(() => flattenLocaleKeys('not-an-object'), /must be an object/)
})

test('translation calls are extracted, dynamic keys reduce to their static prefix', () => {
  const { keys, dynamicPrefixes } = extractTranslationKeys(
    [
      "t('plugins.install')",
      't("common.ok")',
      't(`profiles.title`)',
      't(`plugins.status.${item.status}`)',
      't(`${dynamic}`)',
      "t('an\\'escaped.quote')",
      "it('is not a translation call')",
      "somethingElse('nope')",
      't(variable)'
    ].join('\n')
  )
  // the escaped literal has to reduce to the key i18next resolves at runtime,
  // otherwise a legitimate t('it\'s.here') is reported as unresolved
  assert.deepEqual([...keys].sort(), [
    "an'escaped.quote",
    'common.ok',
    'plugins.install',
    'profiles.title'
  ])
  assert.deepEqual([...dynamicPrefixes], ['plugins.status.'])
})

test('unresolved keys cover both literal keys and dynamic prefixes', () => {
  const baseKeys = new Set(['plugins.install', 'plugins.status.active'])
  assert.deepEqual(
    findUnresolvedKeys(new Set(['plugins.install', 'plugins.remove']), new Set(), baseKeys),
    ['plugins.remove']
  )
  assert.deepEqual(
    findUnresolvedKeys(new Set(), new Set(['plugins.status.', 'tray.tooltip.']), baseKeys),
    ['tray.tooltip.*']
  )
})

test('a key used in code without an en-US entry blocks the audit', () => {
  const root = createFixture(
    { 'en-US': { 'common.ok': 'OK' }, 'zh-CN': { 'common.ok': '确定' } },
    { 'page.tsx': "const label = t('common.ok') + t('common.missing')" }
  )
  try {
    const report = inspectLocales(root)
    assert.deepEqual(report.unresolvedKeys, ['common.missing'])
    assert.deepEqual([...report.missingByLocale.keys()], [])
    assert.equal(report.sourceFileCount, 1)
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('a non-base locale missing an en-US key blocks the audit', () => {
  const root = createFixture(
    {
      'en-US': { 'common.ok': 'OK', plugins: { install: 'Install' } },
      'zh-CN': { 'common.ok': '确定', plugins: { install: '安装' } },
      'ru-RU': { 'common.ok': 'ОК' }
    },
    { 'page.tsx': "t('common.ok')" }
  )
  try {
    const report = inspectLocales(root)
    assert.deepEqual(report.unresolvedKeys, [])
    assert.deepEqual([...report.missingByLocale.keys()], ['ru-RU'])
    assert.deepEqual(report.missingByLocale.get('ru-RU'), ['plugins.install'])
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})

test('missing locale keys are diffed against the base locale only', () => {
  const baseKeys = new Set(['a', 'b'])
  assert.deepEqual(findMissingLocaleKeys(baseKeys, new Set(['b', 'c'])), ['a'])
  assert.deepEqual(findMissingLocaleKeys(baseKeys, new Set(['a', 'b', 'c'])), [])
})

test('only TypeScript sources are scanned', () => {
  const root = createFixture(
    { 'en-US': { 'common.ok': 'OK' } },
    { 'page.tsx': "t('common.ok')", 'helper.ts': "t('common.ok')", 'notes.md': "t('common.gone')" }
  )
  try {
    const files = collectSourceFiles(path.join(root, 'src')).map((file) => path.basename(file))
    assert.deepEqual(files.sort(), ['helper.ts', 'page.tsx'])
    assert.deepEqual(inspectLocales(root).unresolvedKeys, [])
  } finally {
    fs.rmSync(root, { recursive: true, force: true })
  }
})
