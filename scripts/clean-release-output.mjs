import fs from 'node:fs'
import path from 'node:path'

const repositoryRoot = path.resolve(import.meta.dirname, '..')
const distDirectory = path.join(repositoryRoot, 'dist')

function assertInsideDist(targetPath) {
  const target = path.resolve(targetPath)
  const relative = path.relative(distDirectory, target)
  if (
    !relative ||
    relative === '..' ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  ) {
    throw new Error(`Refusing to clean outside dist: ${target}`)
  }
  return target
}

if (!fs.existsSync(distDirectory)) {
  console.log('Release output is already clean.')
  process.exit(0)
}

// Allowlisted leftovers only: package artifacts, unpacked dir, and known electron-builder metadata.
const removableNames = new Set([
  'SHA256SUMS.txt',
  'win-unpacked',
  'latest.yml',
  'latest-mac.yml',
  'latest-linux.yml',
  'builder-debug.yml',
  'builder-effective-config.yaml'
])
let removed = 0
for (const entry of fs.readdirSync(distDirectory, { withFileTypes: true })) {
  if (!removableNames.has(entry.name) && !/^aikobox-windows-/i.test(entry.name)) continue
  const target = assertInsideDist(path.join(distDirectory, entry.name))
  if (entry.isSymbolicLink())
    throw new Error(`Refusing to clean a linked release output: ${target}`)
  if (entry.isDirectory() && entry.name !== 'win-unpacked') {
    throw new Error(`Refusing to recursively clean an unexpected directory: ${target}`)
  }
  if (!entry.isDirectory() && !entry.isFile()) {
    throw new Error(`Refusing to clean a special release output: ${target}`)
  }
  fs.rmSync(target, { force: true, recursive: entry.isDirectory() })
  removed += 1
}

console.log(`Cleaned ${removed} generated release output(s).`)
