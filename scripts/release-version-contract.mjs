import { readFileSync } from 'node:fs'

const RELEASE_VERSION_PATTERN = /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/
const ANDROID_VERSION_PATTERN = /^([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?)\+([0-9]+)$/

export function readReleaseVersionContract({
  packagePath = 'package.json',
  pubspecPath = 'apps/android/pubspec.yaml',
  releaseTag
} = {}) {
  const packageJson = JSON.parse(readFileSync(packagePath, 'utf8'))
  const packageVersion = packageJson.version
  if (typeof packageVersion !== 'string' || !RELEASE_VERSION_PATTERN.test(packageVersion)) {
    throw new Error(`Unsupported package version: ${String(packageVersion)}`)
  }

  const pubspec = readFileSync(pubspecPath, 'utf8')
  const versionLines = pubspec.match(/^version:\s*(\S+)\s*$/gm) ?? []
  if (versionLines.length !== 1) {
    throw new Error(`Expected exactly one top-level version in ${pubspecPath}`)
  }

  const androidVersion = versionLines[0].replace(/^version:\s*/, '').trim()
  const androidMatch = ANDROID_VERSION_PATTERN.exec(androidVersion)
  if (!androidMatch) {
    throw new Error(`Android version must use versionName+versionCode: ${androidVersion}`)
  }

  const [, androidVersionName, androidVersionCodeText] = androidMatch
  if (androidVersionName !== packageVersion) {
    throw new Error(
      `Version mismatch: package.json is ${packageVersion}, Android versionName is ${androidVersionName}`
    )
  }

  const androidVersionCode = Number(androidVersionCodeText)
  if (!Number.isSafeInteger(androidVersionCode) || androidVersionCode <= 1) {
    throw new Error(
      `Android versionCode must be an integer greater than 1: ${androidVersionCodeText}`
    )
  }

  const expectedTag = `v${packageVersion}`
  if (releaseTag !== undefined && releaseTag !== expectedTag) {
    throw new Error(`Tag ${releaseTag} must exactly equal release version ${expectedTag}`)
  }

  return {
    version: packageVersion,
    versionCode: androidVersionCode,
    expectedTag,
    notesPath: `docs/releases/${expectedTag}.md`
  }
}

function parseArguments(arguments_) {
  const options = {}
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index]
    if (argument === '--package') options.packagePath = arguments_[++index]
    else if (argument === '--pubspec') options.pubspecPath = arguments_[++index]
    else if (argument === '--tag') options.releaseTag = arguments_[++index]
    else throw new Error(`Unknown or incomplete argument: ${argument}`)
  }
  return options
}

if (
  process.argv[1] &&
  import.meta.url === new URL(`file://${process.argv[1].replaceAll('\\', '/')}`).href
) {
  const contract = readReleaseVersionContract(parseArguments(process.argv.slice(2)))
  process.stdout.write(`${JSON.stringify(contract)}\n`)
}
