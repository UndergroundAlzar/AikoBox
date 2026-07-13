import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
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

function sha256(contents) {
  return createHash('sha256').update(contents).digest('hex')
}

function resolveEvidenceFile(relativePath, label) {
  invariant(typeof relativePath === 'string' && relativePath.length > 0, `${label}: empty path`)
  invariant(!relativePath.includes('\\'), `${label}: path must use forward slashes`)
  invariant(!path.posix.isAbsolute(relativePath), `${label}: path must be repository-relative`)
  invariant(!relativePath.split('/').includes('..'), `${label}: path escapes the repository`)
  const absolutePath = path.resolve(repositoryRoot, ...relativePath.split('/'))
  const relative = path.relative(repositoryRoot, absolutePath)
  invariant(
    relative && !relative.startsWith('..') && !path.isAbsolute(relative),
    `${label}: path escapes the repository`
  )
  return absolutePath
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
    } else {
      invariant(
        typeof item.license === 'string' && item.license.length > 0,
        `${name}: verified license expression is missing`
      )
      invariant(
        typeof item.copyright === 'string' && item.copyright.length > 0,
        `${name}: verified copyright notice is missing`
      )
      invariant(item.blocker === undefined, `${name}: verified item still declares a blocker`)
      invariant(item.source && typeof item.source === 'object', `${name}: source is missing`)
      invariant(/^https:\/\//.test(item.source.url), `${name}: source URL must use HTTPS`)
      invariant(/^v?\d/.test(item.source.tag), `${name}: source tag is invalid`)
      invariant(/^[a-f0-9]{40}$/.test(item.source.commit), `${name}: source commit is invalid`)
      invariant(resource.sourceTag === item.source.tag, `${name}: source tag differs from lock`)
      invariant(
        resource.sourceCommit === item.source.commit,
        `${name}: source commit differs from lock`
      )

      invariant(notice.includes(item.license), `${name}: license is absent from notice`)
      invariant(notice.includes(item.copyright), `${name}: copyright is absent from notice`)
      invariant(notice.includes(item.source.url), `${name}: source URL is absent from notice`)
      invariant(notice.includes(item.source.tag), `${name}: source tag is absent from notice`)
      invariant(notice.includes(item.source.commit), `${name}: source commit is absent from notice`)

      invariant(
        Array.isArray(item.evidence) && item.evidence.length > 0,
        `${name}: verified evidence is missing`
      )
      const evidenceTypes = new Set()
      const evidenceUrls = new Set()
      for (const evidence of item.evidence) {
        invariant(
          evidence && typeof evidence.type === 'string' && evidence.type.length > 0,
          `${name}: evidence type is missing`
        )
        invariant(/^https:\/\//.test(evidence.url), `${name}: evidence URL must use HTTPS`)
        invariant(!evidenceTypes.has(evidence.type), `${name}: duplicate evidence type`)
        invariant(!evidenceUrls.has(evidence.url), `${name}: duplicate evidence URL`)
        evidenceTypes.add(evidence.type)
        evidenceUrls.add(evidence.url)
        invariant(notice.includes(evidence.url), `${name}: evidence URL is absent from notice`)
      }

      invariant(
        Array.isArray(item.licenseFiles) && item.licenseFiles.length > 0,
        `${name}: verified license files are missing`
      )
      const licensePaths = new Set()
      for (const licenseFile of item.licenseFiles) {
        invariant(
          licenseFile && /^[a-f0-9]{64}$/.test(licenseFile.sha256),
          `${name}: license file SHA-256 is invalid`
        )
        invariant(!licensePaths.has(licenseFile.path), `${name}: duplicate license file`)
        licensePaths.add(licenseFile.path)
        const absolutePath = resolveEvidenceFile(licenseFile.path, `${name}: license file`)
        invariant(fs.existsSync(absolutePath), `${name}: license file is missing`)
        const stat = fs.lstatSync(absolutePath)
        invariant(stat.isFile() && !stat.isSymbolicLink(), `${name}: license path is not a file`)
        const contents = fs.readFileSync(absolutePath)
        invariant(
          sha256(contents) === licenseFile.sha256,
          `${name}: license file does not match its reviewed SHA-256`
        )
        invariant(
          contents.toString('utf8').includes(item.copyright),
          `${name}: license file omits the reviewed copyright`
        )
        invariant(notice.includes(licenseFile.path), `${name}: license path is absent from notice`)
        invariant(
          notice.includes(licenseFile.sha256),
          `${name}: license file SHA-256 is absent from notice`
        )
      }
    }
  }

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
