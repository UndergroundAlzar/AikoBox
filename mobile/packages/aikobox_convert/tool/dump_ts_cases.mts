// TypeScript half of the converter parity check — the twin of dump_cases.dart.
//
// Runs the *desktop* converter (`src/main/core/singbox/convert.ts`) over the
// same cases file and writes the same JSON shape, so the two output trees can
// be diffed byte for byte. This is what produced `test/parity/expected/**`.
//
// From the repo root, with the desktop app's node_modules installed:
//
//     node node_modules/tsx/dist/cli.mjs \
//       mobile/packages/aikobox_convert/tool/dump_ts_cases.mts \
//       mobile/packages/aikobox_convert/test/parity/cases.json \
//       /tmp/ts-out
//     cd mobile/packages/aikobox_convert
//     dart run tool/dump_cases.dart test/parity/cases.json /tmp/dart-out
//     diff -r /tmp/ts-out /tmp/dart-out
//
// Three differences are expected and are enumerated in `test/parity_test.dart`:
// each is a case where the shared output is something sing-box 1.13 refuses to
// load. Anything else is a genuine divergence.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs'
import { dirname, isAbsolute, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
// tool/ -> aikobox_convert -> packages -> mobile -> <repo>
const repo = resolve(here, '..', '..', '..', '..')

const { convertClashToSingbox } = await import(
  pathToFileURL(resolve(repo, 'src/main/core/singbox/convert.ts')).href
)
const { parse } = await import(pathToFileURL(resolve(repo, 'src/main/utils/yaml.ts')).href)

const casesPath = resolve(process.argv[2])
const outDir = resolve(process.argv[3])
mkdirSync(outDir, { recursive: true })

for (const entry of JSON.parse(readFileSync(casesPath, 'utf8'))) {
  const clash =
    entry.clash ??
    parse(
      readFileSync(
        isAbsolute(entry.clashYamlFile)
          ? entry.clashYamlFile
          : join(dirname(casesPath), entry.clashYamlFile),
        'utf8'
      )
    )
  const options = entry.options ?? {}
  // `platform: ''` is how the Dart port spells the TypeScript "platform not
  // supplied" branch, and '' is falsy here too, so the two agree.
  const result = convertClashToSingbox(clash, {
    platform: options.platform,
    controllerSecret: options.controllerSecret
  })
  writeFileSync(
    join(outDir, `${entry.id}.json`),
    JSON.stringify(
      {
        config: result.config,
        warnings: result.warnings,
        errors: result.errors,
        controller: result.controller
      },
      null,
      2
    ) + '\n'
  )
  console.log(`${entry.id}: ${result.warnings.length} warning(s), ${result.errors.length} error(s)`)
}
