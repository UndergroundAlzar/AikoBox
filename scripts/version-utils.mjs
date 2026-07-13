import { execSync } from 'child_process'
import { readFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'

const repositoryRoot = join(dirname(fileURLToPath(import.meta.url)), '..')

// 获取Git commit hash
export function getGitCommitHash(short = true) {
  try {
    const command = short ? 'git rev-parse --short HEAD' : 'git rev-parse HEAD'
    return execSync(command, { encoding: 'utf-8' }).trim()
  } catch (error) {
    console.warn('Failed to get git commit hash:', error.message)
    return 'unknown'
  }
}

// 获取当前月份日期
export function getCurrentMonthDate() {
  const now = new Date()
  const month = String(now.getMonth() + 1).padStart(2, '0')
  const day = String(now.getDate()).padStart(2, '0')
  return `${month}${day}`
}

// 从仓库根目录 package.json 读取基础版本号（失败时抛错，不回退默认值）
export function getBaseVersion() {
  const packageJsonPath = join(repositoryRoot, 'package.json')
  let raw
  try {
    raw = readFileSync(packageJsonPath, 'utf-8')
  } catch (error) {
    throw new Error(`Failed to read package.json at ${packageJsonPath}: ${error.message}`)
  }

  let parsed
  try {
    parsed = JSON.parse(raw)
  } catch (error) {
    throw new Error(`Failed to parse package.json at ${packageJsonPath}: ${error.message}`)
  }

  const { version } = parsed
  if (typeof version !== 'string' || version.trim() === '') {
    throw new Error(`package.json at ${packageJsonPath} is missing a valid version field`)
  }

  // 移除dev版本格式后缀
  return version.replace(/-d\d{2,4}\.[a-f0-9]{7}$/, '')
}

// 生成dev版本号
export function getDevVersion() {
  const baseVersion = getBaseVersion()
  const monthDate = getCurrentMonthDate()
  const commitHash = getGitCommitHash(true)

  return `${baseVersion}-d${monthDate}.${commitHash}`
}

// 检查当前环境是否为dev构建
export function isDevBuild() {
  return (
    process.env.NODE_ENV === 'development' ||
    process.argv.includes('--dev') ||
    process.env.GITHUB_EVENT_NAME === 'workflow_dispatch'
  )
}

// 获取处理后的版本号
export function getProcessedVersion() {
  if (isDevBuild()) {
    return getDevVersion()
  } else {
    return getBaseVersion()
  }
}
