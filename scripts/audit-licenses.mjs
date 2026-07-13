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

export function isRecognizedRootLicenseFileName(name) {
  return (
    /^(?:license|licence|copying|notice)(?:\.|$)/i.test(name) || /^licen[cs]e-mit\.txt$/i.test(name)
  )
}

export function extractReviewedLicenseSection(contents, startMarker, endMarker, label) {
  invariant(Buffer.isBuffer(contents), `${label}: source contents must be a buffer`)
  invariant(
    typeof startMarker === 'string' && startMarker.length > 0,
    `${label}: section start marker is missing`
  )
  invariant(
    typeof endMarker === 'string' && endMarker.length > 0,
    `${label}: section end marker is missing`
  )
  const start = contents.indexOf(Buffer.from(startMarker, 'utf8'))
  invariant(start >= 0, `${label}: section start marker was not found`)
  invariant(
    contents.indexOf(Buffer.from(startMarker, 'utf8'), start + 1) === -1,
    `${label}: section start marker is ambiguous`
  )
  const endMarkerBuffer = Buffer.from(endMarker, 'utf8')
  const end = contents.indexOf(endMarkerBuffer, start)
  invariant(end >= 0, `${label}: section end marker was not found`)
  invariant(
    contents.indexOf(endMarkerBuffer, end + 1) === -1,
    `${label}: section end marker is ambiguous`
  )
  return contents.subarray(start, end + endMarkerBuffer.length)
}

function comparableFsPath(filePath) {
  const normalized = path.normalize(filePath).replace(/^\\\\\?\\/, '')
  return process.platform === 'win32' ? normalized.toLowerCase() : normalized
}

export function resolveEvidenceFile(
  relativePath,
  label,
  root = repositoryRoot,
  allowMissing = false
) {
  invariant(typeof relativePath === 'string' && relativePath.length > 0, `${label}: empty path`)
  invariant(!relativePath.includes('\0'), `${label}: path contains a NUL byte`)
  invariant(!relativePath.includes('\\'), `${label}: path must use forward slashes`)
  invariant(
    !path.posix.isAbsolute(relativePath) && !path.win32.isAbsolute(relativePath),
    `${label}: path must be repository-relative`
  )
  const segments = relativePath.split('/')
  invariant(
    segments.every(
      (segment) =>
        segment.length > 0 && segment !== '.' && segment !== '..' && !segment.includes(':')
    ),
    `${label}: path must be canonical and must not escape the repository`
  )

  const absoluteRoot = path.resolve(root)
  invariant(fs.existsSync(absoluteRoot), `${label}: repository root is missing`)
  const realRoot = fs.realpathSync.native(absoluteRoot)
  const absolutePath = path.resolve(absoluteRoot, ...segments)
  const relative = path.relative(absoluteRoot, absolutePath)
  invariant(
    relative && !relative.startsWith('..') && !path.isAbsolute(relative),
    `${label}: path escapes the repository`
  )

  let lexicalPath = absoluteRoot
  let expectedRealPath = realRoot
  for (const segment of segments) {
    lexicalPath = path.join(lexicalPath, segment)
    expectedRealPath = path.join(expectedRealPath, segment)
    let stat
    try {
      stat = fs.lstatSync(lexicalPath)
    } catch (error) {
      if (error?.code === 'ENOENT' && allowMissing) return absolutePath
      throw error
    }
    invariant(!stat.isSymbolicLink(), `${label}: path passes through a symbolic link or junction`)
    const actualRealPath = fs.realpathSync.native(lexicalPath)
    invariant(
      comparableFsPath(actualRealPath) === comparableFsPath(expectedRealPath),
      `${label}: path passes through a symbolic link or junction`
    )
  }

  const realPath = fs.realpathSync.native(absolutePath)
  const realRelative = path.relative(realRoot, realPath)
  invariant(
    realRelative && !realRelative.startsWith('..') && !path.isAbsolute(realRelative),
    `${label}: resolved path escapes the repository`
  )
  return absolutePath
}

export function getResourceNoticeSection(notice, name) {
  const marker = `<!-- resource:${name} -->`
  const start = notice.indexOf(marker)
  invariant(start >= 0, `${name}: notice marker is missing`)
  invariant(notice.lastIndexOf(marker) === start, `${name}: notice marker is duplicated`)
  const candidates = [
    notice.indexOf('<!-- resource:', start + marker.length),
    notice.indexOf('\n## ', start + marker.length)
  ].filter((offset) => offset >= 0)
  const end = candidates.length > 0 ? Math.min(...candidates) : notice.length
  return notice.slice(start, end)
}

function assertBufferRange(contents, offset, length, label) {
  invariant(
    Number.isSafeInteger(offset) &&
      Number.isSafeInteger(length) &&
      offset >= 0 &&
      length >= 0 &&
      offset + length <= contents.length,
    `${label}: invalid or truncated font table`
  )
}

function decodeSfntNameString(contents, platformId) {
  if (platformId !== 0 && platformId !== 3) return contents.toString('latin1')
  invariant(contents.length % 2 === 0, 'Font name record has invalid UTF-16BE length')
  let value = ''
  for (let offset = 0; offset < contents.length; offset += 2) {
    value += String.fromCharCode(contents.readUInt16BE(offset))
  }
  return value
}

export function readSfntNameMetadata(filePath) {
  const contents = fs.readFileSync(filePath)
  assertBufferRange(contents, 0, 12, 'SFNT header')
  const tableCount = contents.readUInt16BE(4)
  assertBufferRange(contents, 12, tableCount * 16, 'SFNT table directory')

  let nameTable
  for (let index = 0; index < tableCount; index += 1) {
    const recordOffset = 12 + index * 16
    if (contents.toString('ascii', recordOffset, recordOffset + 4) !== 'name') continue
    nameTable = {
      offset: contents.readUInt32BE(recordOffset + 8),
      length: contents.readUInt32BE(recordOffset + 12)
    }
    break
  }
  invariant(nameTable, 'Font has no SFNT name table')
  assertBufferRange(contents, nameTable.offset, nameTable.length, 'SFNT name table')
  invariant(nameTable.length >= 6, 'SFNT name table header is truncated')

  const recordCount = contents.readUInt16BE(nameTable.offset + 2)
  const stringOffset = contents.readUInt16BE(nameTable.offset + 4)
  invariant(6 + recordCount * 12 <= nameTable.length, 'SFNT name records are truncated')
  invariant(stringOffset <= nameTable.length, 'SFNT name string storage is invalid')

  const values = new Map()
  for (let index = 0; index < recordCount; index += 1) {
    const recordOffset = nameTable.offset + 6 + index * 12
    const platformId = contents.readUInt16BE(recordOffset)
    const nameId = contents.readUInt16BE(recordOffset + 6)
    if (nameId !== 0 && nameId !== 5) continue
    const length = contents.readUInt16BE(recordOffset + 8)
    const offset = contents.readUInt16BE(recordOffset + 10)
    const valueOffset = nameTable.offset + stringOffset + offset
    assertBufferRange(contents, valueOffset, length, 'SFNT name value')
    invariant(
      valueOffset + length <= nameTable.offset + nameTable.length,
      'SFNT name value escapes its table'
    )
    const value = decodeSfntNameString(
      contents.subarray(valueOffset, valueOffset + length),
      platformId
    )
    if (!values.has(nameId)) values.set(nameId, new Set())
    values.get(nameId).add(value)
  }

  const copyrightValues = [...(values.get(0) ?? [])]
  const versionValues = [...(values.get(5) ?? [])]
  invariant(copyrightValues.length === 1, 'Font must contain one unique copyright record')
  invariant(versionValues.length === 1, 'Font must contain one unique version record')
  const versionRecord = versionValues[0]
  const match = /^Version ([0-9]+\.[0-9]+);GOOG;noto-emoji:([0-9]{8}):([a-f0-9]{40})$/.exec(
    versionRecord
  )
  invariant(match, 'Font version record does not contain pinned noto-emoji build metadata')
  return {
    version: match[1],
    buildDate: match[2],
    buildRevision: match[3],
    copyright: copyrightValues[0],
    versionRecord
  }
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
  const noticeMarkerNames = [...notice.matchAll(/<!-- resource:([A-Za-z0-9_-]+) -->/g)].map(
    (match) => match[1]
  )
  invariant(
    new Set(noticeMarkerNames).size === noticeMarkerNames.length,
    'Third-party notice contains a duplicate resource marker'
  )
  invariant(
    JSON.stringify([...noticeMarkerNames].sort()) === JSON.stringify(lockNames),
    'The third-party notice must contain exactly one section for every locked runtime resource'
  )

  const blockers = []
  for (const name of lockNames) {
    const resource = lock.resources[name]
    const item = review.resources[name]
    const noticeSection = getResourceNoticeSection(notice, name)
    invariant(item.status === 'blocked' || item.status === 'verified', `${name}: invalid status`)
    invariant(/^https:\/\//.test(item.project), `${name}: project URL must use HTTPS`)
    invariant(
      noticeSection.includes(resource.version),
      `${name}: locked version is absent from notice`
    )
    invariant(
      noticeSection.includes(item.project),
      `${name}: reviewed project URL is absent from notice`
    )

    const locator = resource.downloadUrl ?? resource.source
    invariant(
      noticeSection.includes(locator),
      `${name}: locked source locator is absent from notice`
    )

    for (const hashField of ['sha256', 'archiveSha256', 'directorySha256']) {
      if (resource[hashField]) {
        invariant(
          noticeSection.includes(resource[hashField]),
          `${name}: ${hashField} is absent from notice`
        )
      }
    }

    if (item.status === 'blocked') {
      invariant(item.blocker.length >= 40, `${name}: release blocker is not specific enough`)
      invariant(
        noticeSection.includes(item.blocker),
        `${name}: release blocker is absent from notice`
      )
      blockers.push(name)
    } else {
      invariant(
        typeof item.license === 'string' && item.license.length > 0,
        `${name}: verified license expression is missing`
      )
      invariant(
        typeof item.licenseCopyright === 'string' && item.licenseCopyright.length > 0,
        `${name}: verified license copyright notice is missing`
      )
      invariant(item.blocker === undefined, `${name}: verified item still declares a blocker`)
      invariant(item.release && typeof item.release === 'object', `${name}: release is missing`)
      invariant(/^https:\/\//.test(item.release.url), `${name}: release URL must use HTTPS`)
      invariant(/^v?\d/.test(item.release.tag), `${name}: release tag is invalid`)
      invariant(
        /^[a-f0-9]{40}$/.test(item.release.tagCommit),
        `${name}: release tag commit is invalid`
      )
      invariant(resource.releaseTag === item.release.tag, `${name}: release tag differs from lock`)
      invariant(
        resource.releaseTagCommit === item.release.tagCommit,
        `${name}: release tag commit differs from lock`
      )

      invariant(noticeSection.includes(item.license), `${name}: license is absent from notice`)
      invariant(
        noticeSection.includes(item.licenseCopyright),
        `${name}: license copyright is absent from notice`
      )
      invariant(
        noticeSection.includes(item.release.url),
        `${name}: release URL is absent from notice`
      )
      invariant(
        noticeSection.includes(item.release.tag),
        `${name}: release tag is absent from notice`
      )
      invariant(
        noticeSection.includes(item.release.tagCommit),
        `${name}: release tag commit is absent from notice`
      )

      if (resource.fontMetadata !== undefined || item.fontMetadata !== undefined) {
        invariant(
          resource.fontMetadata && item.fontMetadata,
          `${name}: font metadata must be present in both lock and review`
        )
        invariant(
          JSON.stringify(resource.fontMetadata) === JSON.stringify(item.fontMetadata),
          `${name}: reviewed font metadata differs from lock`
        )
        invariant(
          resource.version === item.fontMetadata.version,
          `${name}: font metadata version differs from locked version`
        )
        invariant(/^[0-9]{8}$/.test(item.fontMetadata.buildDate), `${name}: build date is invalid`)
        invariant(
          /^[a-f0-9]{40}$/.test(item.fontMetadata.buildRevision),
          `${name}: embedded build revision is invalid`
        )
        invariant(
          typeof item.fontMetadata.copyright === 'string' && item.fontMetadata.copyright.length > 0,
          `${name}: embedded font copyright is missing`
        )

        const fontPath = resolveEvidenceFile(
          resource.output,
          `${name}: packaged font`,
          repositoryRoot,
          true
        )
        if (fs.existsSync(fontPath)) {
          const fontStat = fs.lstatSync(fontPath)
          invariant(
            fontStat.isFile() && !fontStat.isSymbolicLink(),
            `${name}: font path is not a file`
          )
          const fontContents = fs.readFileSync(fontPath)
          invariant(
            fontContents.length === resource.size && sha256(fontContents) === resource.sha256,
            `${name}: local font does not match its locked size and SHA-256`
          )
          const embedded = readSfntNameMetadata(fontPath)
          for (const field of ['version', 'buildDate', 'buildRevision', 'copyright']) {
            invariant(
              embedded[field] === item.fontMetadata[field],
              `${name}: embedded font ${field} differs from reviewed metadata`
            )
          }
        }
        for (const field of ['version', 'buildDate', 'buildRevision', 'copyright']) {
          invariant(
            noticeSection.includes(item.fontMetadata[field]),
            `${name}: embedded font ${field} is absent from notice`
          )
        }
      }

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
        invariant(
          noticeSection.includes(evidence.url),
          `${name}: evidence URL is absent from notice`
        )
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
        invariant(
          /^https:\/\//.test(licenseFile.sourceUrl),
          `${name}: license source URL must use HTTPS`
        )
        invariant(
          /^[a-f0-9]{64}$/.test(licenseFile.upstreamSha256),
          `${name}: upstream license SHA-256 is invalid`
        )
        invariant(
          typeof licenseFile.transformation === 'string' && licenseFile.transformation.length >= 40,
          `${name}: license normalization record is missing`
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
          contents.toString('utf8').includes(item.licenseCopyright),
          `${name}: license file omits the reviewed license copyright`
        )
        invariant(
          noticeSection.includes(licenseFile.path),
          `${name}: license path is absent from notice`
        )
        invariant(
          noticeSection.includes(licenseFile.sha256),
          `${name}: license file SHA-256 is absent from notice`
        )
        invariant(
          noticeSection.includes(licenseFile.sourceUrl),
          `${name}: license source URL is absent from notice`
        )
        invariant(
          noticeSection.includes(licenseFile.upstreamSha256),
          `${name}: upstream license SHA-256 is absent from notice`
        )
        invariant(
          noticeSection.includes(licenseFile.transformation),
          `${name}: license normalization record is absent from notice`
        )
      }
    }
  }

  return {
    blockers,
    reviewedLicenseExpressions: review.reviewedProductionLicenseExpressions,
    expectedPackagesWithoutLicenseFiles: review.productionPackagesWithoutLicenseFiles,
    productionPackageEvidence: review.productionPackageEvidence,
    thirdPartyNotice: notice
  }
}

function inspectProductionDependencyMetadata(
  reviewedLicenseExpressions,
  expectedPackagesWithoutLicenseFiles,
  productionPackageEvidence,
  thirdPartyNotice
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
  const reviewedEvidence = new Set()
  const reviewedLicensePaths = new Set()
  invariant(
    productionPackageEvidence && typeof productionPackageEvidence === 'object',
    'Production package evidence is missing'
  )
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
        const identity = `${metadata.name}@${metadata.version}`
        const evidence = productionPackageEvidence[identity]
        const hasLicenseFile = fs
          .readdirSync(packagePath, { withFileTypes: true })
          .some((item) => item.isFile() && isRecognizedRootLicenseFileName(item.name))

        if (evidence) {
          invariant(
            !reviewedEvidence.has(identity),
            `${identity}: duplicate installed evidence root`
          )
          reviewedEvidence.add(identity)
          invariant(
            evidence.license === expression,
            `${identity}: reviewed license differs from inventory`
          )
          invariant(
            [
              'packaged-license-file',
              'packaged-readme-section',
              'excluded-from-application'
            ].includes(evidence.disposition),
            `${identity}: invalid evidence disposition`
          )
          invariant(
            Number.isSafeInteger(evidence.sourceSize) && evidence.sourceSize > 0,
            `${identity}: source evidence size is invalid`
          )
          invariant(
            /^[a-f0-9]{64}$/.test(evidence.sourceSha256),
            `${identity}: source evidence SHA-256 is invalid`
          )
          const sourcePath = resolveEvidenceFile(
            evidence.sourceFile,
            `${identity}: installed source evidence`,
            packagePath
          )
          const sourceContents = fs.readFileSync(sourcePath)
          invariant(
            sourceContents.length === evidence.sourceSize &&
              sha256(sourceContents) === evidence.sourceSha256,
            `${identity}: installed source evidence differs from review`
          )
          for (const required of [identity, evidence.sourceSha256]) {
            invariant(
              thirdPartyNotice.includes(required),
              `${identity}: ${required} is absent from third-party notice`
            )
          }

          if (evidence.disposition === 'excluded-from-application') {
            invariant(
              evidence.licenseFile === undefined,
              `${identity}: excluded package has a license file`
            )
            invariant(
              typeof evidence.forbiddenAsarPath === 'string' &&
                /^\/node_modules\/(?:@[^/]+\/)?[^/]+$/.test(evidence.forbiddenAsarPath),
              `${identity}: forbidden app.asar path is invalid`
            )
            invariant(
              thirdPartyNotice.includes(evidence.forbiddenAsarPath),
              `${identity}: exclusion path is absent from third-party notice`
            )
          } else {
            const licenseFile = evidence.licenseFile
            invariant(
              licenseFile && typeof licenseFile === 'object',
              `${identity}: license file is missing`
            )
            invariant(
              !reviewedLicensePaths.has(licenseFile.path),
              `${identity}: duplicate reviewed license path`
            )
            reviewedLicensePaths.add(licenseFile.path)
            invariant(
              Number.isSafeInteger(licenseFile.size) && licenseFile.size > 0,
              `${identity}: packaged license size is invalid`
            )
            invariant(
              /^[a-f0-9]{64}$/.test(licenseFile.sha256),
              `${identity}: packaged license SHA-256 is invalid`
            )
            const packagedPath = resolveEvidenceFile(
              licenseFile.path,
              `${identity}: packaged license evidence`
            )
            const packagedContents = fs.readFileSync(packagedPath)
            invariant(
              packagedContents.length === licenseFile.size &&
                sha256(packagedContents) === licenseFile.sha256,
              `${identity}: packaged license differs from review`
            )
            const reviewedContents =
              evidence.disposition === 'packaged-readme-section'
                ? extractReviewedLicenseSection(
                    sourceContents,
                    evidence.sectionStart,
                    evidence.sectionEnd,
                    identity
                  )
                : sourceContents
            invariant(
              reviewedContents.equals(packagedContents),
              `${identity}: packaged license differs from installed source evidence`
            )
            for (const required of [licenseFile.path, licenseFile.sha256]) {
              invariant(
                thirdPartyNotice.includes(required),
                `${identity}: ${required} is absent from third-party notice`
              )
            }
          }
        } else if (!hasLicenseFile) {
          packagesWithoutLicenseFiles.push(identity)
        }
      }
    }
  }

  const expectedEvidence = Object.keys(productionPackageEvidence).sort()
  invariant(
    JSON.stringify([...reviewedEvidence].sort()) === JSON.stringify(expectedEvidence),
    `Reviewed production package evidence differs from the frozen install. Found: ${[...reviewedEvidence].sort().join(', ')}`
  )

  packagesWithoutLicenseFiles.sort()
  const expectedMissing = [...expectedPackagesWithoutLicenseFiles].sort()
  invariant(
    JSON.stringify(packagesWithoutLicenseFiles) === JSON.stringify(expectedMissing),
    `Production packages without reviewed license evidence changed; review required. Found: ${packagesWithoutLicenseFiles.join(', ')}`
  )

  return {
    expressions,
    packages,
    packagesWithoutLicenseFiles,
    reviewedEvidence: [...reviewedEvidence].sort()
  }
}

export function runAudit() {
  try {
    const resourceReview = inspectResourceReview()
    const production = inspectProductionDependencyMetadata(
      resourceReview.reviewedLicenseExpressions,
      resourceReview.expectedPackagesWithoutLicenseFiles,
      resourceReview.productionPackageEvidence,
      resourceReview.thirdPartyNotice
    )

    console.log(
      `[OK] ${production.packages} production dependency versions use reviewed license expressions: ${production.expressions.join(', ')}`
    )
    console.log(
      `[OK] ${production.reviewedEvidence.length} exact production package evidence records passed: ${production.reviewedEvidence.join(', ')}`
    )

    if (production.packagesWithoutLicenseFiles.length > 0) {
      console.error(
        `[BLOCKED] Production packages without reviewed license evidence: ${production.packagesWithoutLicenseFiles.join(', ')}`
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
}

const entrypoint = process.argv[1] && path.resolve(process.argv[1])
if (
  entrypoint &&
  comparableFsPath(entrypoint) === comparableFsPath(fileURLToPath(import.meta.url))
) {
  runAudit()
}
