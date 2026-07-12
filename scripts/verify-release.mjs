import { createHash } from 'node:crypto'
import { createReadStream, existsSync, lstatSync, readFileSync, readdirSync } from 'node:fs'
import { basename, relative, resolve, sep } from 'node:path'
import { extractFile, listPackage } from '@electron/asar'

const projectRoot = resolve(import.meta.dirname, '..')
const distDir = resolve(projectRoot, 'dist')
const packageJson = JSON.parse(readFileSync(resolve(projectRoot, 'package.json'), 'utf8'))
const resourceLock = JSON.parse(
  readFileSync(resolve(projectRoot, 'scripts', 'resources-lock.json'), 'utf8')
)
const releaseTag = process.env.AIKOBOX_RELEASE_TAG || process.env.GITHUB_REF_NAME
const expectedTag = `v${packageJson.version}`

if (releaseTag && releaseTag !== expectedTag) {
  throw new Error(`Release tag ${releaseTag} does not match package version ${expectedTag}`)
}

const artifacts = [
  `aikobox-windows-${packageJson.version}-x64-setup.exe`,
  `aikobox-windows-${packageJson.version}-x64-portable.exe`
]
const expectedFiles = new Set([
  ...artifacts,
  ...artifacts.map((name) => `${name}.sha256`),
  'SHA256SUMS.txt'
])

for (const name of expectedFiles) {
  if (!existsSync(resolve(distDir, name))) {
    throw new Error(`Missing release file: ${name}`)
  }
}

const releaseExecutables = readdirSync(distDir).filter((name) =>
  /^aikobox-windows-.*-(setup|portable)\.exe$/i.test(name)
)
if (
  releaseExecutables.length !== artifacts.length ||
  releaseExecutables.some((name) => !artifacts.includes(name))
) {
  throw new Error(`Unexpected Windows release executables: ${releaseExecutables.join(', ')}`)
}

async function sha256(filePath) {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(filePath)) hash.update(chunk)
  return hash.digest('hex')
}

function sha256Buffer(buffer) {
  return createHash('sha256').update(buffer).digest('hex')
}

function assertFile(filePath, expectedSize, expectedSha256, label) {
  if (!existsSync(filePath) || !lstatSync(filePath).isFile()) {
    throw new Error(`Missing packaged ${label}: ${filePath}`)
  }
  const contents = readFileSync(filePath)
  if (contents.length !== expectedSize || sha256Buffer(contents) !== expectedSha256) {
    throw new Error(`Packaged ${label} does not match the locked size and SHA-256`)
  }
}

function collectDirectoryFiles(root, directory = root) {
  const files = []
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const absolute = resolve(directory, entry.name)
    const stat = lstatSync(absolute)
    if (stat.isSymbolicLink()) throw new Error(`Packaged directory contains a link: ${absolute}`)
    if (entry.isDirectory()) files.push(...collectDirectoryFiles(root, absolute))
    else if (entry.isFile()) files.push(relative(root, absolute).split(sep).join('/'))
    else throw new Error(`Packaged directory contains a special file: ${absolute}`)
  }
  return files
}

function digestDirectory(directory) {
  const files = collectDirectoryFiles(directory).sort()
  const hash = createHash('sha256')
  hash.update('AIKOBOX-DIR-SHA256-v1\0')
  for (const name of files) {
    const nameBuffer = Buffer.from(name, 'utf8')
    const contents = readFileSync(resolve(directory, ...name.split('/')))
    const lengths = Buffer.alloc(16)
    lengths.writeBigUInt64BE(BigInt(nameBuffer.length), 0)
    lengths.writeBigUInt64BE(BigInt(contents.length), 8)
    hash.update(lengths)
    hash.update(nameBuffer)
    hash.update(contents)
  }
  return { fileCount: files.length, sha256: hash.digest('hex') }
}

function assertAmd64Pe(filePath) {
  const contents = readFileSync(filePath)
  if (contents.length < 64 || contents.readUInt16LE(0) !== 0x5a4d) {
    throw new Error(`${basename(filePath)} is not a Windows PE executable`)
  }
  const peOffset = contents.readUInt32LE(0x3c)
  if (
    peOffset + 6 > contents.length ||
    contents.toString('ascii', peOffset, peOffset + 4) !== 'PE\0\0' ||
    contents.readUInt16LE(peOffset + 4) !== 0x8664
  ) {
    throw new Error(`${basename(filePath)} is not an AMD64 Windows executable`)
  }
}

function verifyPackagedApplication() {
  const unpacked = resolve(distDir, 'win-unpacked')
  const resources = resolve(unpacked, 'resources')
  const appExecutable = resolve(unpacked, 'AikoBox.exe')
  const appAsar = resolve(resources, 'app.asar')
  assertAmd64Pe(appExecutable)
  if (!existsSync(appAsar)) throw new Error('Missing packaged app.asar')

  const asarEntries = listPackage(appAsar).map((entry) => entry.replaceAll('\\', '/'))
  for (const required of ['/LICENSE', '/THIRD_PARTY_NOTICES.md']) {
    if (!asarEntries.includes(required)) throw new Error(`app.asar is missing ${required}`)
  }

  for (const [name, resource] of Object.entries(resourceLock.resources)) {
    if (resource.output.startsWith('extra/')) {
      const packaged = resolve(resources, ...resource.output.slice('extra/'.length).split('/'))
      if (resource.type === 'zip-directory') {
        if (!existsSync(packaged) || !lstatSync(packaged).isDirectory()) {
          throw new Error(`Missing packaged ${name} directory`)
        }
        const digest = digestDirectory(packaged)
        if (digest.fileCount !== resource.fileCount || digest.sha256 !== resource.directorySha256) {
          throw new Error(`Packaged ${name} directory does not match its resource lock`)
        }
      } else {
        assertFile(packaged, resource.size, resource.sha256, name)
      }
      continue
    }

    if (name === 'notoColorEmoji') {
      const matches = asarEntries.filter(
        (entry) =>
          entry.startsWith('/out/renderer/assets/NotoColorEmoji-') && entry.endsWith('.ttf')
      )
      if (matches.length !== 1) {
        throw new Error(
          `Expected exactly one packaged Noto Color Emoji font, found ${matches.length}`
        )
      }
      const archivePath = matches[0].slice(1).replaceAll('/', sep)
      const contents = extractFile(appAsar, archivePath)
      if (contents.length !== resource.size || sha256Buffer(contents) !== resource.sha256) {
        throw new Error('Packaged Noto Color Emoji does not match its resource lock')
      }
      continue
    }

    throw new Error(`Release verifier does not map locked resource ${name}`)
  }
}

const expectedLines = []
for (const artifact of artifacts) {
  const digest = await sha256(resolve(distDir, artifact))
  const line = `${digest}  ${artifact}`
  const sidecar = readFileSync(resolve(distDir, `${artifact}.sha256`), 'utf8').trim()
  if (sidecar !== line) {
    throw new Error(`Checksum sidecar does not match ${artifact}`)
  }
  expectedLines.push(line)
}

const aggregate = readFileSync(resolve(distDir, 'SHA256SUMS.txt'), 'utf8').trim().split(/\r?\n/)
if (
  aggregate.length !== expectedLines.length ||
  aggregate.some((line, i) => line !== expectedLines[i])
) {
  throw new Error('SHA256SUMS.txt does not exactly match the two release artifacts')
}

verifyPackagedApplication()

console.log(
  `Verified ${artifacts.length} immutable Windows artifacts, the inner AMD64 app, and all locked packaged resources for ${expectedTag}.`
)
