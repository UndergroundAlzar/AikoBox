import fs from 'node:fs'
import path from 'node:path'

const repositoryRoot = path.resolve(import.meta.dirname, '..')
const outputRoot = path.join(repositoryRoot, 'out')
const textExtensions = new Set(['.cjs', '.css', '.html', '.js', '.json', '.mjs'])
const retiredIdentifier =
  /\b(?:enableLoopback|openUWPTool|showTraffic|startMonitor|TrafficMonitor)\b/

if (!fs.existsSync(outputRoot) || !fs.lstatSync(outputRoot).isDirectory()) {
  throw new Error('Production output is missing; run the production build first')
}

const pending = [outputRoot]
const violations = []
while (pending.length > 0) {
  const directory = pending.pop()
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const absolutePath = path.join(directory, entry.name)
    if (entry.isSymbolicLink())
      throw new Error(`Production output contains a link: ${absolutePath}`)
    if (entry.isDirectory()) {
      pending.push(absolutePath)
      continue
    }
    if (!entry.isFile() || !textExtensions.has(path.extname(entry.name).toLowerCase())) continue
    if (retiredIdentifier.test(fs.readFileSync(absolutePath, 'utf8'))) {
      violations.push(path.relative(repositoryRoot, absolutePath).replaceAll('\\', '/'))
    }
  }
}

if (violations.length > 0) {
  throw new Error(`Retired optional tool identifiers remain in: ${violations.join(', ')}`)
}

console.log('Production output contains no retired optional tool identifiers.')
