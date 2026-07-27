import {
  cpSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync
} from 'node:fs'
import { tmpdir } from 'node:os'
import { basename, dirname, join, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

import {
  auditCoverage,
  collectLicenses,
  createTarGz,
  downloadModule,
  extractSource,
  findUnreferencedNativeFiles,
  parseJsonStream,
  parseVendorModules,
  requireSourceIdentity,
  run,
  writeText
} from './license-android-libbox-release.mjs'
import {
  LIBBOX_COMMIT as SING_BOX_COMMIT,
  LIBBOX_VERSION as SING_BOX_VERSION,
  parseGoBuildInfo,
  sha256
} from './license-android-libbox.mjs'

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
const moduleInventoryPath = join(
  repoRoot,
  'licenses',
  `sing-box-${SING_BOX_VERSION}`,
  'static-modules.tsv'
)
const targetStem = `aikobox-sing-box-${SING_BOX_VERSION}-windows-amd64`
const expectedBinaryHash = 'db0d779948214cf761011d154c3a5da36df20394fa01a9fc798f1dc39fe9d183'
const expectedGoVersion = 'go1.26.4'
const expectedTags =
  'with_gvisor,with_quic,with_dhcp,with_wireguard,with_utls,with_acme,' +
  'with_clash_api,with_tailscale,with_ccm,with_ocm,with_naive_outbound,' +
  'with_purego,badlinkname,tfogo_checklinkname0'

export function parseWindowsModuleInventory(text) {
  const rows = text
    .replaceAll('\r\n', '\n')
    .split('\n')
    .filter((line) => line.startsWith('dep\t'))
    .map((line) => {
      const [, module, version, sum] = line.split('\t')
      if (!module || !version || !/^h1:/.test(sum ?? '')) {
        throw new Error(`Invalid Windows static module inventory row: ${line}`)
      }
      return { module, version, sum }
    })
  const identities = new Set(rows.map((row) => `${row.module}@${row.version}`))
  if (rows.length !== 100 || identities.size !== rows.length) {
    throw new Error(`Expected 100 unique Windows static modules, got ${rows.length}`)
  }
  return rows
}

export function requireWindowsBuildIdentity(buildInfo) {
  const settings = new Set(buildInfo.settings)
  const required = [
    '-buildmode=exe',
    `-tags=${expectedTags}`,
    'CGO_ENABLED=0',
    'GOARCH=amd64',
    'GOOS=windows',
    `vcs.revision=${SING_BOX_COMMIT}`,
    'vcs.modified=false'
  ]
  const missing = required.filter((setting) => !settings.has(setting))
  if (
    buildInfo.goVersion !== expectedGoVersion ||
    buildInfo.mainModule !== `github.com/sagernet/sing-box\tv${SING_BOX_VERSION}` ||
    missing.length > 0
  ) {
    throw new Error(
      `Windows sing-box build identity differs: go=${buildInfo.goVersion}, ` +
        `main=${buildInfo.mainModule}, missing=${missing.join(',')}`
    )
  }
}

function copyMainLegalFiles(sourceRoot, licenseRoot) {
  const files = [
    ['sing-box-LICENSE.upstream.txt', join(sourceRoot, 'LICENSE')],
    ['GPL-3.0.txt', join(repoRoot, 'LICENSE')],
    ['THIRD_PARTY_NOTICES.md', join(repoRoot, 'THIRD_PARTY_NOTICES.md')]
  ]
  return files.map(([name, source]) => {
    const destination = join(licenseRoot, 'main', name)
    mkdirSync(dirname(destination), { recursive: true })
    writeFileSync(destination, readFileSync(source))
    const contents = readFileSync(destination)
    return { path: `main/${name}`, size: contents.length, sha256: sha256(contents) }
  })
}

function createBuildGuide({ binary }) {
  return `# Rebuilding sing-box ${SING_BOX_VERSION} for Windows amd64

This package corresponds to AikoBox's exact \`extra/sidecar/sing-box.exe\`:

- SHA-256: \`${binary.sha256}\`
- size: ${binary.size} bytes
- source commit: \`${SING_BOX_COMMIT}\`
- recorded toolchain: \`${expectedGoVersion}\`
- target: \`windows/amd64\`, \`CGO_ENABLED=0\`
- build tags: \`${expectedTags}\`

The \`sing-box-${SING_BOX_VERSION}/vendor\` tree contains all modules selected by
\`go mod vendor\`. The generator verified the 100 module identities embedded in the
shipped executable against that tree and downloaded module checksums.

Rebuild from the package root with Go ${expectedGoVersion.replace(/^go/, '')}:

\`\`\`powershell
$env:GOWORK = "off"
$env:CGO_ENABLED = "0"
$env:GOOS = "windows"
$env:GOARCH = "amd64"
Set-Location "sing-box-${SING_BOX_VERSION}"
go mod verify
go build -mod=vendor -trimpath -o sing-box.exe -tags "${expectedTags}" \`
  -ldflags "-X 'github.com/sagernet/sing-box/constant.Version=${SING_BOX_VERSION}' -s -w -buildid=" \`
  ./cmd/sing-box
\`\`\`

The exact upstream workflow and release build-tag files are included in the source tree.
The shipped binary records \`CGO_ENABLED=0\`; the selected Go package graph has no linked
native archive. Prebuilt native files present only as unreferenced module payloads are
removed from this corresponding-source package and counted in \`COVERAGE.json\`.

Only use these artifacts when \`COVERAGE.json\` has \`releaseReady: true\`, 100 covered
actual modules, all vendor modules licensed, no linked native inputs, and no blockers.
`
}

function clearReleaseArtifacts(distDir) {
  for (const suffix of [
    'corresponding-source.tar.gz',
    'licenses.tar.gz',
    'SHA256SUMS.txt',
    'COVERAGE.json',
    'BLOCKED.txt'
  ]) {
    rmSync(join(distDir, `${targetStem}-${suffix}`), { force: true })
  }
}

function writeChecksums(distDir, artifacts) {
  const lines = artifacts.map((path) => `${sha256(readFileSync(path))}  ${basename(path)}`).sort()
  const destination = join(distDir, `${targetStem}-SHA256SUMS.txt`)
  writeText(destination, `${lines.join('\n')}\n`)
  return destination
}

export function generateWindowsSingBoxRelease(options) {
  requireSourceIdentity(options.sourceDir)
  mkdirSync(options.distDir, { recursive: true })
  clearReleaseArtifacts(options.distDir)

  const temporaryRoot = mkdtempSync(join(tmpdir(), 'aikobox-windows-sing-box-source-'))
  const reportPath = join(options.distDir, `${targetStem}-COVERAGE.json`)
  try {
    const sourceRoot = extractSource(options.sourceDir, join(temporaryRoot, 'source-stage'))
    const binaryBytes = readFileSync(options.binaryPath)
    const binary = { size: binaryBytes.length, sha256: sha256(binaryBytes) }
    if (binary.sha256 !== expectedBinaryHash) {
      throw new Error(`Expected sing-box.exe ${expectedBinaryHash}, got ${binary.sha256}`)
    }

    const rawBuildInfo = run(options.goExe, ['version', '-m', options.binaryPath])
    const buildInfo = parseGoBuildInfo(rawBuildInfo)
    requireWindowsBuildIdentity(buildInfo)
    const actualModules = buildInfo.modules.map(([module, version, sum]) => ({
      module,
      version,
      sum
    }))
    if (actualModules.length !== 100) {
      throw new Error(`Expected 100 actual static modules, got ${actualModules.length}`)
    }
    const committedModules = parseWindowsModuleInventory(readFileSync(moduleInventoryPath, 'utf8'))
    if (JSON.stringify(actualModules) !== JSON.stringify(committedModules)) {
      throw new Error('Actual Windows module inventory differs from committed evidence')
    }
    const environment = {
      ...process.env,
      CGO_ENABLED: '0',
      GOARCH: 'amd64',
      GOOS: 'windows',
      GOWORK: 'off'
    }
    run(options.goExe, ['mod', 'verify'], { cwd: sourceRoot, env: environment })
    run(options.goExe, ['mod', 'vendor'], { cwd: sourceRoot, env: environment })
    const vendorModules = parseVendorModules(
      readFileSync(join(sourceRoot, 'vendor', 'modules.txt'), 'utf8')
    )
    const actualDownloads = actualModules.map((row) =>
      downloadModule(options.goExe, sourceRoot, row, environment)
    )
    const vendorDownloads = [...vendorModules.values()].map((row) =>
      downloadModule(options.goExe, sourceRoot, row, environment)
    )
    const packages = parseJsonStream(
      run(
        options.goExe,
        ['list', '-mod=vendor', '-deps', '-json', `-tags=${expectedTags}`, './cmd/sing-box'],
        { cwd: sourceRoot, env: environment }
      )
    )

    const licenseParent = join(temporaryRoot, 'license-stage')
    const licenseName = `${targetStem}-licenses`
    const licenseRoot = join(licenseParent, licenseName)
    mkdirSync(licenseRoot, { recursive: true })
    const mainLegalFiles = copyMainLegalFiles(sourceRoot, licenseRoot)
    const licenseResult = collectLicenses(vendorDownloads, licenseRoot)
    const coverage = auditCoverage({
      actualModules,
      vendorModules,
      packages,
      downloads: actualDownloads
    })
    const blockers = [...licenseResult.blockers, ...coverage.blockers]
    if (coverage.nativeInputs.length > 0) {
      blockers.push(
        `CGO-disabled Windows package graph unexpectedly selected ${coverage.nativeInputs.length} native inputs`
      )
    }
    const unreferencedNativeFiles = findUnreferencedNativeFiles(
      join(sourceRoot, 'vendor'),
      coverage.nativeInputs
    )
    const report = {
      schema: 1,
      component: 'sing-box',
      version: SING_BOX_VERSION,
      commit: SING_BOX_COMMIT,
      target: 'windows/amd64',
      generatedAt: new Date().toISOString(),
      releaseReady: blockers.length === 0,
      actualStaticModules: actualModules.length,
      coveredActualStaticModules: actualDownloads.length,
      vendorModules: vendorModules.size,
      licensedVendorModules: licenseResult.manifest.length,
      linkedNativeInputs: coverage.nativeInputs,
      prunedUnreferencedNativeFiles: unreferencedNativeFiles.length,
      binary,
      goVersion: buildInfo.goVersion,
      buildTags: expectedTags.split(','),
      blockers
    }
    writeText(reportPath, `${JSON.stringify(report, null, 2)}\n`)
    writeText(
      join(licenseRoot, 'MODULE-LICENSE-MANIFEST.json'),
      `${JSON.stringify(
        {
          actualStaticModules: actualModules,
          main: mainLegalFiles,
          vendoredGoModules: licenseResult.manifest
        },
        null,
        2
      )}\n`
    )
    writeFileSync(join(licenseRoot, 'COVERAGE.json'), readFileSync(reportPath))

    if (blockers.length > 0) {
      writeText(
        join(options.distDir, `${targetStem}-BLOCKED.txt`),
        `Release archives were not created because the audit is fail-closed.\n\n${blockers
          .map((blocker) => `- ${blocker}`)
          .join('\n')}\n`
      )
      throw new Error(
        `Windows sing-box corresponding-source audit blocked release:\n${blockers
          .map((blocker) => `- ${blocker}`)
          .join('\n')}`
      )
    }

    for (const path of unreferencedNativeFiles) rmSync(path, { force: true })
    const sourceName = `${targetStem}-corresponding-source`
    const releaseSourceRoot = join(temporaryRoot, sourceName)
    mkdirSync(join(releaseSourceRoot, 'EVIDENCE'), { recursive: true })
    cpSync(sourceRoot, join(releaseSourceRoot, `sing-box-${SING_BOX_VERSION}`), {
      recursive: true
    })
    writeFileSync(
      join(releaseSourceRoot, 'EVIDENCE', 'actual-modules.tsv'),
      readFileSync(moduleInventoryPath)
    )
    writeText(join(releaseSourceRoot, 'EVIDENCE', 'go-version-m.txt'), rawBuildInfo)
    writeFileSync(
      join(releaseSourceRoot, 'EVIDENCE', 'GPL-3.0.txt'),
      readFileSync(join(repoRoot, 'LICENSE'))
    )
    writeFileSync(
      join(releaseSourceRoot, 'EVIDENCE', 'THIRD_PARTY_NOTICES.md'),
      readFileSync(join(repoRoot, 'THIRD_PARTY_NOTICES.md'))
    )
    writeFileSync(join(releaseSourceRoot, 'COVERAGE.json'), readFileSync(reportPath))
    writeText(join(releaseSourceRoot, 'BUILDING.md'), createBuildGuide({ binary }))

    const sourceArchive = join(options.distDir, `${sourceName}.tar.gz`)
    const licenseArchive = join(options.distDir, `${licenseName}.tar.gz`)
    createTarGz(temporaryRoot, sourceName, sourceArchive)
    createTarGz(licenseParent, licenseName, licenseArchive)
    const checksums = writeChecksums(options.distDir, [sourceArchive, licenseArchive, reportPath])
    return { sourceArchive, licenseArchive, reportPath, checksums, report }
  } finally {
    rmSync(temporaryRoot, { recursive: true, force: true })
  }
}

function parseArguments(argv) {
  const values = new Map()
  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index]
    if (key.startsWith('--')) values.set(key, argv[++index])
  }
  for (const key of ['--source-dir', '--binary', '--go', '--dist-dir']) {
    if (!values.get(key)) throw new Error(`Missing required argument ${key}`)
  }
  return {
    sourceDir: resolve(values.get('--source-dir')),
    binaryPath: resolve(values.get('--binary')),
    goExe: resolve(values.get('--go')),
    distDir: resolve(values.get('--dist-dir'))
  }
}

function main() {
  const options = parseArguments(process.argv.slice(2))
  if (!existsSync(options.binaryPath)) throw new Error(`Missing binary: ${options.binaryPath}`)
  console.log(JSON.stringify(generateWindowsSingBoxRelease(options), null, 2))
}

if (process.argv[1] && pathToFileURL(resolve(process.argv[1])).href === import.meta.url) {
  main()
}
