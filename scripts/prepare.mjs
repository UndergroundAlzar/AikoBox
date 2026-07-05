import fs from 'fs'
import AdmZip from 'adm-zip'
import path from 'path'
import { extract } from 'tar'
import { execSync } from 'child_process'

const cwd = process.cwd()
const TEMP_DIR = path.join(cwd, 'node_modules/.temp')
let arch = process.arch
const platform = process.platform
if (process.argv.slice(2).length !== 0) {
  arch = process.argv.slice(2)[0].replace('--', '')
}

/* ======= sing-box (stable) ======= */
// Release assets look like:
//   sing-box-1.13.14-windows-amd64.zip
//   sing-box-1.13.14-darwin-arm64.tar.gz
//   sing-box-1.13.14-linux-amd64.tar.gz
const SINGBOX_RELEASE_API = 'https://api.github.com/repos/SagerNet/sing-box/releases/latest'

const SINGBOX_PLATFORM_MAP = {
  'win32-x64': 'windows-amd64',
  'win32-ia32': 'windows-386',
  'win32-arm64': 'windows-arm64',
  'darwin-x64': 'darwin-amd64',
  'darwin-arm64': 'darwin-arm64',
  'linux-x64': 'linux-amd64',
  'linux-arm64': 'linux-arm64'
}

/*
 * check available
 */
if (!SINGBOX_PLATFORM_MAP[`${platform}-${arch}`]) {
  throw new Error(`unsupported platform "${platform}-${arch}"`)
}

async function fetchLatestSingboxRelease() {
  const headers = {
    Accept: 'application/vnd.github+json',
    'User-Agent': 'aikobox-prepare'
  }
  if (process.env.GITHUB_TOKEN) {
    headers.Authorization = `Bearer ${process.env.GITHUB_TOKEN}`
  }
  const response = await fetch(SINGBOX_RELEASE_API, { headers })
  if (!response.ok) {
    throw new Error(`GitHub API request failed: ${response.status} ${response.statusText}`)
  }
  const release = await response.json()
  if (!release || !Array.isArray(release.assets)) {
    throw new Error('Unexpected GitHub API response for sing-box latest release')
  }
  return release
}

function pickSingboxAsset(release, platformKey) {
  // Match `sing-box-<version>-<platform>.zip|.tar.gz` exactly, which excludes
  // `-legacy-*` / `-musl` / `-glibc` and Android variants.
  const exact = new RegExp(`^sing-box-\\d[\\w.+]*-${platformKey}(\\.zip|\\.tar\\.gz)$`)
  const asset = release.assets.find((a) => exact.test(a.name))
  if (!asset) {
    throw new Error(
      `No sing-box asset found for "${platformKey}" in release ${release.tag_name || '?'}`
    )
  }
  return asset
}

async function findFileRecursive(dir, fileName) {
  const entries = fs.readdirSync(dir, { withFileTypes: true })
  for (const entry of entries) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      const found = await findFileRecursive(full, fileName)
      if (found) return found
    } else if (entry.name === fileName) {
      return full
    }
  }
  return null
}

const resolveSingbox = async () => {
  const platformKey = SINGBOX_PLATFORM_MAP[`${platform}-${arch}`]
  const isWin = platform === 'win32'
  const binName = isWin ? 'sing-box.exe' : 'sing-box'
  const targetFile = binName

  const release = await fetchLatestSingboxRelease()
  console.log(`[INFO]: sing-box latest stable release: ${release.tag_name}`)
  const asset = pickSingboxAsset(release, platformKey)
  console.log(`[INFO]: sing-box asset selected: ${asset.name}`)

  const sidecarDir = path.join(cwd, 'extra', 'sidecar')
  const sidecarPath = path.join(sidecarDir, targetFile)
  fs.mkdirSync(sidecarDir, { recursive: true })

  const tempDir = path.join(TEMP_DIR, 'sing-box')
  const tempArchive = path.join(tempDir, asset.name)
  fs.mkdirSync(tempDir, { recursive: true })

  try {
    if (!fs.existsSync(tempArchive)) {
      await downloadFile(asset.browser_download_url, tempArchive)
    }

    const extractDir = path.join(tempDir, 'extracted')
    fs.rmSync(extractDir, { recursive: true, force: true })
    fs.mkdirSync(extractDir, { recursive: true })

    if (asset.name.endsWith('.zip')) {
      const zip = new AdmZip(tempArchive)
      zip.extractAllTo(extractDir, true)
    } else {
      await extract({ cwd: extractDir, file: tempArchive })
    }

    const extractedBin = await findFileRecursive(extractDir, binName)
    if (!extractedBin) {
      throw new Error(`"${binName}" not found in extracted archive ${asset.name}`)
    }

    if (fs.existsSync(sidecarPath)) {
      fs.rmSync(sidecarPath)
    }
    fs.copyFileSync(extractedBin, sidecarPath)
    if (!isWin) {
      execSync(`chmod 755 "${sidecarPath}"`)
    }
    console.log(`[INFO]: sing-box installed to "${sidecarPath}"`)
  } catch (err) {
    if (fs.existsSync(sidecarPath)) {
      fs.rmSync(sidecarPath)
    }
    throw err
  } finally {
    fs.rmSync(tempDir, { recursive: true, force: true })
  }
}

/**
 * download the file to the extra dir
 */
async function resolveResource(binInfo) {
  const { file, downloadURL } = binInfo

  const resDir = path.join(cwd, 'extra', 'files')
  const targetPath = path.join(resDir, file)

  if (fs.existsSync(targetPath)) {
    fs.rmSync(targetPath)
  }

  fs.mkdirSync(resDir, { recursive: true })
  await downloadFile(downloadURL, targetPath)

  console.log(`[INFO]: ${file} finished`)
}

/**
 * download file and save to `path`
 */
async function downloadFile(url, path) {
  const response = await fetch(url, {
    method: 'GET',
    headers: { 'Content-Type': 'application/octet-stream' }
  })
  const buffer = await response.arrayBuffer()
  fs.writeFileSync(path, new Uint8Array(buffer))

  console.log(`[INFO]: download finished "${url}"`)
}

const resolveEnableLoopback = () =>
  resolveResource({
    file: 'enableLoopback.exe',
    downloadURL: `https://github.com/Kuingsmile/uwp-tool/releases/download/latest/enableLoopback.exe`
  })
/* ======= sysproxy-rs ======= */
const SYSPROXY_RS_URL_PREFIX =
  'https://github.com/mihomo-party-org/sysproxy-rs-opti/releases/latest/download'

function getSysproxyNodeName() {
  // 检测是否为 musl 系统（与 src/native/sysproxy/index.js 保持一致）
  const isMusl = (() => {
    if (platform !== 'linux') return false
    try {
      const output = execSync('ldd --version 2>&1 || true').toString()
      return output.includes('musl')
    } catch {
      return false
    }
  })()

  const isWin7Build = process.env.LEGACY_BUILD === 'true'

  switch (platform) {
    case 'win32':
      if (arch === 'x64')
        return isWin7Build ? 'sysproxy.win32-x64-msvc-win7.node' : 'sysproxy.win32-x64-msvc.node'
      if (arch === 'arm64') return 'sysproxy.win32-arm64-msvc.node'
      if (arch === 'ia32')
        return isWin7Build ? 'sysproxy.win32-ia32-msvc-win7.node' : 'sysproxy.win32-ia32-msvc.node'
      break
    case 'darwin':
      if (arch === 'x64') return 'sysproxy.darwin-x64.node'
      if (arch === 'arm64') return 'sysproxy.darwin-arm64.node'
      break
    case 'linux':
      if (isMusl) {
        if (arch === 'x64') return 'sysproxy.linux-x64-musl.node'
        if (arch === 'arm64') return 'sysproxy.linux-arm64-musl.node'
      } else {
        if (arch === 'x64') return 'sysproxy.linux-x64-gnu.node'
        if (arch === 'arm64') return 'sysproxy.linux-arm64-gnu.node'
      }
      break
  }
  throw new Error(`Unsupported platform for sysproxy-rs: ${platform}-${arch}`)
}

const resolveSysproxy = async () => {
  const nodeName = getSysproxyNodeName()
  const sidecarDir = path.join(cwd, 'extra', 'sidecar')
  const targetPath = path.join(sidecarDir, nodeName)

  fs.mkdirSync(sidecarDir, { recursive: true })

  // 清理其他平台的 .node 文件
  const files = fs.readdirSync(sidecarDir)
  for (const file of files) {
    if (file.endsWith('.node') && file !== nodeName) {
      fs.rmSync(path.join(sidecarDir, file))
      console.log(`[INFO]: removed ${file}`)
    }
  }

  if (fs.existsSync(targetPath)) {
    fs.rmSync(targetPath)
  }

  await downloadFile(`${SYSPROXY_RS_URL_PREFIX}/${nodeName}`, targetPath)
  console.log(`[INFO]: ${nodeName} finished`)
}

const resolveMonitor = async () => {
  const tempDir = path.join(TEMP_DIR, 'TrafficMonitor')
  const tempZip = path.join(tempDir, `${arch}.zip`)
  if (!fs.existsSync(tempDir)) {
    fs.mkdirSync(tempDir, { recursive: true })
  }
  await downloadFile(
    `https://github.com/mihomo-party-org/mihomo-party-run/releases/download/monitor/${arch}.zip`,
    tempZip
  )
  const zip = new AdmZip(tempZip)
  const resDir = path.join(cwd, 'extra', 'files')
  const targetPath = path.join(resDir, 'TrafficMonitor')
  if (fs.existsSync(targetPath)) {
    fs.rmSync(targetPath, { recursive: true })
  }
  zip.extractAllTo(targetPath, true)

  console.log(`[INFO]: TrafficMonitor finished`)
}

const resolve7zip = () =>
  resolveResource({
    file: '7za.exe',
    downloadURL: `https://github.com/develar/7zip-bin/raw/master/win/${arch}/7za.exe`
  })
const resolveSubstore = () =>
  resolveResource({
    file: 'sub-store.bundle.cjs',
    downloadURL:
      'https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js'
  })
const resolveHelper = () =>
  resolveResource({
    file: 'party.mihomo.helper',
    downloadURL: `https://github.com/mihomo-party-org/mihomo-party-helper/releases/download/${arch}/party.mihomo.helper`
  })
const resolveSubstoreFrontend = async () => {
  const tempDir = path.join(TEMP_DIR, 'substore-frontend')
  const tempZip = path.join(tempDir, 'dist.zip')
  if (!fs.existsSync(tempDir)) {
    fs.mkdirSync(tempDir, { recursive: true })
  }
  await downloadFile(
    'https://github.com/sub-store-org/Sub-Store-Front-End/releases/latest/download/dist.zip',
    tempZip
  )
  const zip = new AdmZip(tempZip)
  const resDir = path.join(cwd, 'extra', 'files')
  const targetPath = path.join(resDir, 'sub-store-frontend')
  if (fs.existsSync(targetPath)) {
    fs.rmSync(targetPath, { recursive: true })
  }
  zip.extractAllTo(resDir, true)
  fs.renameSync(path.join(resDir, 'dist'), targetPath)

  console.log(`[INFO]: sub-store-frontend finished`)
}
const resolveFont = async () => {
  const targetPath = path.join(cwd, 'src', 'renderer', 'src', 'assets', 'NotoColorEmoji.ttf')

  if (fs.existsSync(targetPath)) {
    return
  }
  await downloadFile(
    'https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf',
    targetPath
  )

  console.log(`[INFO]: NotoColorEmoji.ttf finished`)
}

const tasks = [
  {
    name: 'sing-box',
    func: resolveSingbox,
    retry: 5
  },
  {
    name: 'font',
    func: resolveFont,
    retry: 5
  },
  {
    name: 'enableLoopback',
    func: resolveEnableLoopback,
    retry: 5,
    winOnly: true
  },
  {
    name: 'sysproxy',
    func: resolveSysproxy,
    retry: 5
  },
  {
    name: 'monitor',
    func: resolveMonitor,
    retry: 5,
    winOnly: true
  },
  {
    name: 'substore',
    func: resolveSubstore,
    retry: 5
  },
  {
    name: 'substorefrontend',
    func: resolveSubstoreFrontend,
    retry: 5
  },
  {
    name: '7zip',
    func: resolve7zip,
    retry: 5,
    winOnly: true
  },
  {
    name: 'helper',
    func: resolveHelper,
    retry: 5,
    darwinOnly: true
  }
]

async function runTask() {
  const task = tasks.shift()
  if (!task) return
  if (task.winOnly && platform !== 'win32') return runTask()
  if (task.linuxOnly && platform !== 'linux') return runTask()
  if (task.unixOnly && platform === 'win32') return runTask()
  if (task.darwinOnly && platform !== 'darwin') return runTask()

  for (let i = 0; i < task.retry; i++) {
    try {
      await task.func()
      break
    } catch (err) {
      console.error(`[ERROR]: task::${task.name} try ${i} ==`, err.message)
      if (i === task.retry - 1) {
        if (task.optional) {
          console.log(`[WARN]: Optional task::${task.name} failed, skipping...`)
          break
        } else {
          throw err
        }
      }
    }
  }
  return runTask()
}

runTask()
runTask()
