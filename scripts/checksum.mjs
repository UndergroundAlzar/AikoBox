import { createReadStream, existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs'
import { createHash } from 'crypto'
import { resolve } from 'path'

const projectRoot = resolve(import.meta.dirname, '..')
const distDir = resolve(projectRoot, 'dist')
const packageJson = JSON.parse(readFileSync(resolve(projectRoot, 'package.json'), 'utf8'))
const artifacts = [
  `aikobox-windows-${packageJson.version}-x64-setup.exe`,
  `aikobox-windows-${packageJson.version}-x64-portable.exe`
]

async function sha256(filePath) {
  const hash = createHash('sha256')
  for await (const chunk of createReadStream(filePath)) {
    hash.update(chunk)
  }
  return hash.digest('hex')
}

if (!existsSync(distDir)) mkdirSync(distDir, { recursive: true })

const missing = artifacts.filter((file) => !existsSync(resolve(distDir, file)))
if (missing.length > 0) {
  throw new Error(`Cannot create checksums; missing release artifact(s): ${missing.join(', ')}`)
}

const lines = []
for (const file of artifacts) {
  const digest = await sha256(resolve(distDir, file))
  const line = `${digest}  ${file}`
  writeFileSync(resolve(distDir, `${file}.sha256`), `${line}\n`, 'utf8')
  lines.push(line)
}

writeFileSync(resolve(distDir, 'SHA256SUMS.txt'), `${lines.join('\n')}\n`, 'utf8')
console.log(`Wrote SHA-256 checksums for ${artifacts.length} Windows artifacts.`)
