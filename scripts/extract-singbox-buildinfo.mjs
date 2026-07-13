/**
 * Offline helper: regenerate sing-box build-info inventory from the locked sidecar.
 * Never runs the proxy service (only `go version -m` on the binary).
 *
 * Usage:
 *   node scripts/extract-singbox-buildinfo.mjs
 *   node scripts/extract-singbox-buildinfo.mjs --write
 */
import { createHash } from 'node:crypto'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const repositoryRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const write = process.argv.includes('--write')
const binaryPath = path.join(repositoryRoot, 'extra', 'sidecar', 'sing-box.exe')
const outDir = path.join(repositoryRoot, 'licenses', 'sing-box-1.13.14')

if (!fs.existsSync(binaryPath)) {
  console.error('Locked sing-box sidecar is missing. Run prepare first.')
  process.exit(1)
}

const binarySha256 = createHash('sha256').update(fs.readFileSync(binaryPath)).digest('hex')
const probe = spawnSync('go', ['version', '-m', binaryPath], {
  cwd: repositoryRoot,
  encoding: 'utf8',
  windowsHide: true
})
if (probe.status !== 0) {
  console.error(probe.stderr || probe.error || 'go version -m failed')
  process.exit(1)
}

const lines = String(probe.stdout).replace(/\r\n?/g, '\n').split('\n')
const normalized = lines.join('\n').replace(/\n+$/, '\n')
const deps = lines.filter((line) => /^\t?dep\t/.test(line)).map((line) => line.replace(/^\t/, ''))
const header =
  [
    '# Extracted from go version -m extra/sidecar/sing-box.exe',
    `# Binary SHA-256 (resources-lock): ${binarySha256}`,
    `# Go toolchain: ${(normalized.match(/: (go\d+\.\d+(?:\.\d+)?)/) || [])[1] || 'unknown'}`,
    '# Module: github.com/sagernet/sing-box@v1.13.14',
    '# Format: path\\tversion\\tsum',
    ...deps
  ].join('\n') + '\n'

const buildinfoPath = path.join(outDir, 'buildinfo-modules.txt')
const tsvPath = path.join(outDir, 'static-modules.tsv')

if (write) {
  fs.writeFileSync(buildinfoPath, normalized)
  fs.writeFileSync(tsvPath, header)
}

const report = {
  binarySha256,
  buildinfo: {
    path: 'licenses/sing-box-1.13.14/buildinfo-modules.txt',
    size: Buffer.byteLength(normalized),
    sha256: createHash('sha256').update(normalized).digest('hex'),
    depCount: deps.length
  },
  tsv: {
    path: 'licenses/sing-box-1.13.14/static-modules.tsv',
    size: Buffer.byteLength(header),
    sha256: createHash('sha256').update(header).digest('hex')
  },
  wrote: write
}
console.log(JSON.stringify(report, null, 2))
