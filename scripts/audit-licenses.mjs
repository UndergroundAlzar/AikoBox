import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDirectory = path.dirname(fileURLToPath(import.meta.url))
const repositoryRoot = path.resolve(scriptDirectory, '..')
const allowKnownBlockers = process.argv.includes('--allow-known-blockers')

function readJson(relativePath) {
  return JSON.parse(fs.readFileSync(path.join(repositoryRoot, relativePath), 'utf8'))
}

function invariant(condition, message) {
  if (!condition) throw new Error(message)
}

function inspectResourceReview() {
  const lock = readJson('scripts/resources-lock.json')
  const review = readJson('scripts/third-party-review.json')
  const notice = fs.readFileSync(path.join(repositoryRoot, 'THIRD_PARTY_NOTICES.md'), 'utf8')

  invariant(review.schemaVersion === 1, 'Unsupported third-party review schema')
  invariant(lock.schemaVersion === 1, 'Unsupported resource lock schema')

  const lockNames = Object.keys(lock.resources).sort()
  const reviewNames = Object.keys(review.resources).sort()
  invariant(
    JSON.stringify(reviewNames) === JSON.stringify(lockNames),
    'The third-party review must cover exactly every locked runtime resource'
  )

  const blockers = []
  for (const name of lockNames) {
    const resource = lock.resources[name]
    const item = review.resources[name]
    invariant(item.status === 'blocked' || item.status === 'verified', `${name}: invalid status`)
    invariant(/^https:\/\//.test(item.project), `${name}: project URL must use HTTPS`)
    invariant(notice.includes(`<!-- resource:${name} -->`), `${name}: notice marker is missing`)
    invariant(notice.includes(resource.version), `${name}: locked version is absent from notice`)
    invariant(notice.includes(item.project), `${name}: reviewed project URL is absent from notice`)

    const locator = resource.downloadUrl ?? resource.source
    invariant(notice.includes(locator), `${name}: locked source locator is absent from notice`)

    for (const hashField of ['sha256', 'archiveSha256', 'directorySha256']) {
      if (resource[hashField]) {
        invariant(
          notice.includes(resource[hashField]),
          `${name}: ${hashField} is absent from notice`
        )
      }
    }

    if (item.status === 'blocked') {
      invariant(item.blocker.length >= 40, `${name}: release blocker is not specific enough`)
      invariant(notice.includes(item.blocker), `${name}: release blocker is absent from notice`)
      blockers.push(name)
    }
  }

  invariant(notice.includes('LGPL'), '7-Zip LGPL terms are not called out')
  invariant(notice.includes('unRAR restriction'), '7-Zip unRAR restriction is not called out')
  invariant(notice.includes('RAR compressor'), '7-Zip RAR compressor restriction is not explained')

  return {
    blockers,
    reviewedLicenseExpressions: review.reviewedProductionLicenseExpressions,
    expectedPackagesWithoutLicenseFiles: review.productionPackagesWithoutLicenseFiles
  }
}

function inspectProductionDependencyMetadata(
  reviewedLicenseExpressions,
  expectedPackagesWithoutLicenseFiles
) {
  const command =
    process.platform === 'win32'
      ? {
          executable: process.env.ComSpec ?? 'C:\\Windows\\System32\\cmd.exe',
          arguments: ['/d', '/s', '/c', 'pnpm licenses list --prod --json']
        }
      : { executable: 'pnpm', arguments: ['licenses', 'list', '--prod', '--json'] }
  const result = spawnSync(command.executable, command.arguments, {
    cwd: repositoryRoot,
    encoding: 'utf8',
    shell: false,
    windowsHide: true
  })

  invariant(result.error === undefined, `Unable to run pnpm license inventory: ${result.error}`)
  invariant(result.status === 0, `pnpm license inventory failed: ${result.stderr.trim()}`)
  const inventory = JSON.parse(result.stdout)
  const expressions = Object.keys(inventory).sort()
  const reviewed = [...reviewedLicenseExpressions].sort()
  invariant(
    JSON.stringify(expressions) === JSON.stringify(reviewed),
    `Production license expressions changed; review required. Found: ${expressions.join(', ')}`
  )

  let packages = 0
  const packagesWithoutLicenseFiles = []
  for (const [expression, entries] of Object.entries(inventory)) {
    invariant(Array.isArray(entries) && entries.length > 0, `${expression}: empty inventory group`)
    for (const entry of entries) {
      invariant(entry.name && entry.license, `${expression}: dependency metadata is incomplete`)
      invariant(entry.license === expression, `${entry.name}: grouped under the wrong license`)
      invariant(
        Array.isArray(entry.versions) && entry.versions.length > 0,
        `${entry.name}: no version`
      )
      packages += entry.versions.length

      for (const packagePath of entry.paths) {
        const metadata = JSON.parse(fs.readFileSync(path.join(packagePath, 'package.json'), 'utf8'))
        const hasLicenseFile = fs
          .readdirSync(packagePath, { withFileTypes: true })
          .some(
            (item) => item.isFile() && /^(license|licence|copying|notice)(\.|$)/i.test(item.name)
          )
        if (!hasLicenseFile)
          packagesWithoutLicenseFiles.push(`${metadata.name}@${metadata.version}`)
      }
    }
  }

  packagesWithoutLicenseFiles.sort()
  const expectedMissing = [...expectedPackagesWithoutLicenseFiles].sort()
  invariant(
    JSON.stringify(packagesWithoutLicenseFiles) === JSON.stringify(expectedMissing),
    `Production packages without root license files changed; review required. Found: ${packagesWithoutLicenseFiles.join(', ')}`
  )

  return { expressions, packages, packagesWithoutLicenseFiles }
}

try {
  const resourceReview = inspectResourceReview()
  const production = inspectProductionDependencyMetadata(
    resourceReview.reviewedLicenseExpressions,
    resourceReview.expectedPackagesWithoutLicenseFiles
  )

  console.log(
    `[OK] ${production.packages} production dependency versions use reviewed license expressions: ${production.expressions.join(', ')}`
  )

  if (production.packagesWithoutLicenseFiles.length > 0) {
    console.error(
      `[BLOCKED] Production packages without a root license file: ${production.packagesWithoutLicenseFiles.join(', ')}`
    )
  }

  if (resourceReview.blockers.length > 0) {
    console.error(
      `[BLOCKED] Runtime resource licensing is unresolved for: ${resourceReview.blockers.join(', ')}`
    )
  } else {
    console.log('[OK] Every locked runtime resource has verified redistribution evidence')
  }

  if (
    !allowKnownBlockers &&
    (resourceReview.blockers.length > 0 || production.packagesWithoutLicenseFiles.length > 0)
  ) {
    process.exitCode = 1
  }
} catch (error) {
  console.error(`[FATAL] License audit failed: ${error instanceof Error ? error.message : error}`)
  process.exitCode = 1
}
