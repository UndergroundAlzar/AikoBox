import path from 'node:path'

const windowsDeviceNamePattern = /^(?:con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\..*)?$/i

export function assertAbsoluteChild(basePath, targetPath, label = 'path') {
  if (!path.isAbsolute(basePath) || !path.isAbsolute(targetPath)) {
    throw new Error(`${label} and its base must be absolute`)
  }
  const base = path.resolve(basePath)
  const target = path.resolve(targetPath)
  const relative = path.relative(base, target)
  if (
    !relative ||
    relative === '..' ||
    relative.startsWith(`..${path.sep}`) ||
    path.isAbsolute(relative)
  ) {
    throw new Error(`${label} must stay inside ${base}`)
  }
  return target
}

export function normalizeArchiveEntry(rawPath) {
  if (typeof rawPath !== 'string' || rawPath.length === 0 || rawPath.includes('\0')) {
    throw new Error('Archive contains an empty or invalid path')
  }
  const normalized = rawPath.replaceAll('\\', '/')
  if (
    normalized.startsWith('/') ||
    path.posix.isAbsolute(normalized) ||
    /^[a-z]:/i.test(normalized) ||
    normalized.includes(':')
  ) {
    throw new Error(`Archive path is absolute or contains a drive/stream: ${rawPath}`)
  }
  const segments = normalized.split('/')
  if (
    segments.some(
      (segment) =>
        !segment ||
        segment === '.' ||
        segment === '..' ||
        segment.endsWith('.') ||
        segment.endsWith(' ') ||
        windowsDeviceNamePattern.test(segment)
    )
  ) {
    throw new Error(`Archive path is unsafe on Windows: ${rawPath}`)
  }
  return segments.join('/')
}

export function validateArchiveEntries(entries) {
  if (!Array.isArray(entries) || entries.length === 0) {
    throw new Error('Archive contains no entries')
  }
  const seen = new Set()
  return entries.map((entry) => {
    const normalized = normalizeArchiveEntry(entry)
    const identity = normalized.toLocaleLowerCase('en-US')
    if (seen.has(identity))
      throw new Error(`Archive contains a case-insensitive collision: ${entry}`)
    seen.add(identity)
    return normalized
  })
}

export function parseSevenZipTechnicalListing(output) {
  const lines = String(output).split(/\r?\n/)
  const separatorIndex = lines.findIndex((line) => line.trim() === '----------')
  if (separatorIndex === -1) throw new Error('7-Zip listing has no entry section')

  const entries = []
  let currentPath
  let hasLink = false
  const finishEntry = () => {
    if (currentPath !== undefined) {
      if (hasLink) throw new Error(`Archive contains a link: ${currentPath}`)
      entries.push(currentPath)
    }
    currentPath = undefined
    hasLink = false
  }

  for (const line of lines.slice(separatorIndex + 1)) {
    if (!line) {
      finishEntry()
      continue
    }
    const delimiter = line.indexOf(' = ')
    if (delimiter === -1) continue
    const key = line.slice(0, delimiter)
    const value = line.slice(delimiter + 3)
    if (key === 'Path') currentPath = value
    if ((key === 'Symbolic Link' || key === 'Hard Link') && value) hasLink = true
  }
  finishEntry()
  return validateArchiveEntries(entries)
}

export function selectPackagedApplication(entries) {
  const normalized = validateArchiveEntries(entries)
  const lowerEntries = new Set(normalized.map((entry) => entry.toLocaleLowerCase('en-US')))
  const appAsars = normalized.filter((entry) => {
    const lowerEntry = entry.toLocaleLowerCase('en-US')
    return lowerEntry === 'resources/app.asar' || lowerEntry.endsWith('/resources/app.asar')
  })
  if (appAsars.length !== 1) {
    throw new Error(`Expected exactly one resources/app.asar, found ${appAsars.length}`)
  }

  const appAsar = appAsars[0]
  const resourcesDirectory = path.posix.dirname(appAsar)
  const appRoot = path.posix.dirname(resourcesDirectory)
  const appExecutable = appRoot === '.' ? 'AikoBox.exe' : `${appRoot}/AikoBox.exe`
  if (!lowerEntries.has(appExecutable.toLocaleLowerCase('en-US'))) {
    throw new Error(`Packaged app.asar has no sibling application executable: ${appExecutable}`)
  }
  return { appAsar, appRoot: appRoot === '.' ? '' : appRoot, appExecutable }
}
