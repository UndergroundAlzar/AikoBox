import path from 'path'

type PortableEnvironment = Record<string, string | undefined>

function hasPortableEnvironmentMarker(env: PortableEnvironment): boolean {
  return Boolean(env.PORTABLE_EXECUTABLE_DIR?.trim() || env.PORTABLE_EXECUTABLE_FILE?.trim())
}

function trustedProgramFilesRoots(env: PortableEnvironment): string[] {
  return [env.ProgramW6432, env.ProgramFiles]
    .map((value) => value?.trim())
    .filter(
      (value): value is string =>
        typeof value === 'string' && value.length > 0 && path.win32.isAbsolute(value)
    )
    .map((value) => path.win32.resolve(value))
    .filter((value) => {
      const parsed = path.win32.parse(value)
      return (
        path.win32.dirname(value).toLowerCase() === parsed.root.toLowerCase() &&
        path.win32.basename(value).toLowerCase() === 'program files'
      )
    })
}

export function isExecutableWithinWindowsProgramFiles(
  executablePath: string,
  programFilesRoot: string
): boolean {
  if (!path.win32.isAbsolute(executablePath) || !path.win32.isAbsolute(programFilesRoot)) {
    return false
  }

  const resolvedExecutable = path.win32.resolve(executablePath)
  const resolvedRoot = path.win32.resolve(programFilesRoot)
  if (path.win32.basename(resolvedExecutable).toLowerCase() !== 'aikobox.exe') {
    return false
  }

  const relative = path.win32.relative(resolvedRoot, resolvedExecutable)
  return (
    relative.length > 0 &&
    !relative.startsWith(`..${path.win32.sep}`) &&
    relative !== '..' &&
    !path.win32.isAbsolute(relative)
  )
}

/**
 * Decide whether this executable may request a Windows UAC restart for TUN.
 *
 * The elevated Electron process loads application code from its installation
 * directory, so a user-writable development or portable build must never be
 * elevated by AikoBox. The per-machine installer is intentionally constrained
 * to the 64-bit Program Files directory.
 */
export function isWindowsTunElevationAllowed(
  executablePath: string,
  env: PortableEnvironment,
  isPackaged: boolean
): boolean {
  if (!isPackaged || hasPortableEnvironmentMarker(env)) {
    return false
  }

  return trustedProgramFilesRoots(env).some((root) =>
    isExecutableWithinWindowsProgramFiles(executablePath, root)
  )
}

/** Resolve the original electron-builder portable executable directory. */
export function portableRootFromEnvironment(env: PortableEnvironment): string | null {
  const directory = env.PORTABLE_EXECUTABLE_DIR?.trim()
  const executable = env.PORTABLE_EXECUTABLE_FILE?.trim()

  const resolvedDirectory =
    directory && path.isAbsolute(directory) ? path.resolve(directory) : undefined
  const resolvedExecutable =
    executable && path.isAbsolute(executable) ? path.resolve(executable) : undefined

  if (resolvedDirectory && resolvedExecutable) {
    const executableDirectory = path.dirname(resolvedExecutable)
    const equal =
      process.platform === 'win32'
        ? executableDirectory.toLowerCase() === resolvedDirectory.toLowerCase()
        : executableDirectory === resolvedDirectory
    return equal ? resolvedDirectory : null
  }

  if (resolvedDirectory) return resolvedDirectory
  if (resolvedExecutable) return path.dirname(resolvedExecutable)
  return null
}
