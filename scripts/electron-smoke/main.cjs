'use strict'

const path = require('node:path')
const { pathToFileURL } = require('node:url')

const SMOKE_TOKEN = 'aikobox-github-windows-electron-smoke-v1'

function assertSmokeGate() {
  const allowed =
    process.platform === 'win32' &&
    process.env.CI === 'true' &&
    process.env.GITHUB_ACTIONS === 'true' &&
    process.env.RUNNER_OS === 'Windows' &&
    process.env.RUNNER_ENVIRONMENT === 'github-hosted' &&
    process.env.AIKOBOX_ELECTRON_SMOKE_TOKEN === SMOKE_TOKEN
  if (!allowed) {
    throw new Error('The Electron smoke entrypoint is restricted to a GitHub-hosted Windows runner')
  }
}

assertSmokeGate()

// Install a process-creation tripwire before loading any app code. The smoke
// never imports the production main process, but this makes that boundary fail
// closed if a future edit accidentally adds a process-spawning dependency.
const childProcess = require('node:child_process')
for (const method of [
  'exec',
  'execFile',
  'execFileSync',
  'execSync',
  'fork',
  'spawn',
  'spawnSync'
]) {
  childProcess[method] = () => {
    throw new Error(`SYSTEM_SIDE_EFFECT_BLOCKED:${method}`)
  }
}

const { app, BrowserWindow, ipcMain, session } = require('electron')

const INVOKE_CHANNEL = 'aikobox-electron-smoke-invoke'
const SEND_CHANNEL = 'aikobox-electron-smoke-send'
const RENDERER_ERROR_CHANNEL = 'aikobox-electron-smoke-renderer-error'
const REQUIRED_RENDERER_CHANNELS = new Set([
  'platform',
  'getVersion',
  'getAppConfig',
  'getProfileConfig'
])
const FORBIDDEN_CHANNELS = new Set([
  'triggerSysProxy',
  'setTunEnabled',
  'grantTunPermissions',
  'requestTunPermissions',
  'restartAsAdmin',
  'setupFirewall',
  'restartCore',
  'quitWithoutCore',
  'installCoreUpdate',
  'rollbackCoreUpdate',
  'startSubStoreBackendServer',
  'startSubStoreFrontendServer'
])
const NOOP_CHANNELS = new Set([
  'applyTheme',
  'changeLanguage',
  'setNativeTheme',
  'setTitleBarOverlay'
])
const SAFE_SEND_CHANNELS = new Set(['trayIconUpdate', 'updateFloatingWindow', 'updateTrayMenu'])
const invokedChannels = new Set()
const unexpectedChannels = []
const forbiddenChannels = []
const rendererErrors = []
const blockedRequests = []
const RENDERER_STABILITY_WINDOW_MS = 1_000

const smokeResponses = new Map([
  ['platform', 'win32'],
  ['getVersion', '0.1.0-ci-smoke'],
  [
    'getAppConfig',
    {
      appTheme: 'dark',
      autoCheckUpdate: false,
      enableTrafficLogger: false,
      rememberSelectedSiderCard: false,
      sysProxy: { enable: false },
      useSubStore: false,
      useWindowFrame: true
    }
  ],
  ['getControledMihomoConfig', { mode: 'rule', 'mixed-port': 7890, tun: { enable: false } }],
  ['getProfileConfig', { current: undefined, items: [] }],
  ['getPluginConfig', { items: [] }],
  ['getOverrideConfig', { items: [] }],
  ['mihomoGroups', []],
  ['mihomoRules', { rules: [] }],
  ['mihomoVersion', { version: 'fake-core/ci-smoke' }],
  ['mihomoProxyProviders', { providers: {} }]
])

let smokeWindow
let finishing = false

function resolveSmokePaths() {
  const rendererPath = path.resolve(process.env.AIKOBOX_SMOKE_RENDERER_PATH || '')
  const expectedSuffix = path.join('out', 'renderer', 'index.html')
  if (!rendererPath.endsWith(expectedSuffix)) throw new Error('Unexpected renderer path')

  const userDataPath = path.resolve(process.env.AIKOBOX_SMOKE_USER_DATA || '')
  const runnerTemp = path.resolve(process.env.RUNNER_TEMP || '')
  const relativeUserData = path.relative(runnerTemp, userDataPath)
  if (!relativeUserData || relativeUserData.startsWith('..') || path.isAbsolute(relativeUserData)) {
    throw new Error('Smoke user-data must stay inside RUNNER_TEMP')
  }
  return { rendererPath, userDataPath }
}

const smokePaths = resolveSmokePaths()
const trustedRendererUrl = pathToFileURL(smokePaths.rendererPath)
// Set this before app readiness/session creation; the outer runner also passes
// --user-data-dir, and the duplicate assertion keeps both boundaries pinned.
app.setPath('userData', smokePaths.userDataPath)

function finish(code, payload) {
  if (finishing) return
  finishing = true
  const marker = code === 0 ? 'AIKOBOX_ELECTRON_SMOKE_OK' : 'AIKOBOX_ELECTRON_SMOKE_FAILED'
  const output = JSON.stringify(payload)
  ;(code === 0 ? console.log : console.error)(`${marker} ${output}`)
  if (smokeWindow && !smokeWindow.isDestroyed()) smokeWindow.destroy()
  setTimeout(() => app.exit(code), 50)
}

function safeResponse(channel) {
  invokedChannels.add(channel)
  if (FORBIDDEN_CHANNELS.has(channel)) {
    forbiddenChannels.push(channel)
    throw new Error(`SYSTEM_SIDE_EFFECT_BLOCKED:${channel}`)
  }
  if (smokeResponses.has(channel)) return smokeResponses.get(channel)
  if (NOOP_CHANNELS.has(channel)) return undefined
  unexpectedChannels.push(channel)
  throw new Error(`UNEXPECTED_SMOKE_IPC:${channel}`)
}

function isTrustedRendererNavigation(rawUrl) {
  try {
    const candidate = new URL(rawUrl)
    candidate.hash = ''
    const trusted = new URL(trustedRendererUrl.href)
    trusted.hash = ''
    return candidate.href === trusted.href
  } catch {
    return false
  }
}

async function captureRendererProof(window) {
  return await window.webContents.executeJavaScript(`(() => {
      const root = document.getElementById('root')
      return {
        appReady: document.querySelector('[data-aikobox-app-ready="true"]') !== null,
        bodyTextLength: (document.body?.innerText || '').trim().length,
        errorBoundaryPresent:
          document.querySelector('[data-aikobox-error-boundary="true"]') !== null,
        hash: location.hash,
        rootChildCount: root?.childElementCount || 0
      }
    })()`)
}

function hasRequiredRendererIpc() {
  return [...REQUIRED_RENDERER_CHANNELS].every((channel) => invokedChannels.has(channel))
}

function assertSmokeTelemetryClean() {
  if (blockedRequests.length > 0) throw new Error('Renderer attempted a blocked network request')
  if (forbiddenChannels.length > 0) throw new Error('Renderer attempted a system-control IPC')
  if (unexpectedChannels.length > 0) {
    throw new Error(`Renderer invoked unexpected IPC: ${unexpectedChannels.join(', ')}`)
  }
  if (rendererErrors.length > 0) throw new Error(`Renderer error: ${rendererErrors.join(', ')}`)
}

function assertHealthyRendererProof(proof) {
  if (proof.errorBoundaryPresent)
    throw new Error('Production renderer displayed its error boundary')
  if (!proof.appReady || proof.rootChildCount <= 0 || proof.bodyTextLength <= 0) {
    throw new Error('Production renderer lost its healthy application root')
  }
  if (!hasRequiredRendererIpc()) throw new Error('Production renderer lost required IPC readiness')
}

async function waitForRendererProof(window) {
  const deadline = Date.now() + 20_000
  while (Date.now() < deadline) {
    assertSmokeTelemetryClean()
    const proof = await captureRendererProof(window)
    if (proof.errorBoundaryPresent) {
      throw new Error('Production renderer displayed its error boundary')
    }
    if (
      proof.appReady &&
      proof.rootChildCount > 0 &&
      proof.bodyTextLength > 0 &&
      hasRequiredRendererIpc()
    ) {
      return proof
    }
    await new Promise((resolve) => setTimeout(resolve, 100))
  }
  throw new Error('Production renderer did not become ready before the smoke deadline')
}

async function observeRendererStability(window) {
  const deadline = Date.now() + RENDERER_STABILITY_WINDOW_MS
  let proof = await captureRendererProof(window)
  while (Date.now() < deadline) {
    assertSmokeTelemetryClean()
    assertHealthyRendererProof(proof)
    await new Promise((resolve) => setTimeout(resolve, 100))
    proof = await captureRendererProof(window)
  }
  assertSmokeTelemetryClean()
  assertHealthyRendererProof(proof)
  return proof
}

async function runSmoke() {
  session.defaultSession.setPermissionCheckHandler(() => false)
  session.defaultSession.setPermissionRequestHandler((_webContents, _permission, callback) => {
    callback(false)
  })
  session.defaultSession.webRequest.onBeforeRequest(
    { urls: ['http://*/*', 'https://*/*', 'ws://*/*', 'wss://*/*'] },
    (details, callback) => {
      blockedRequests.push(new URL(details.url).protocol)
      callback({ cancel: true })
    }
  )

  ipcMain.handle(INVOKE_CHANNEL, (_event, channel) => safeResponse(String(channel)))
  ipcMain.on(SEND_CHANNEL, (_event, channel) => {
    const name = String(channel)
    invokedChannels.add(`send:${name}`)
    if (FORBIDDEN_CHANNELS.has(name)) forbiddenChannels.push(`send:${name}`)
    else if (!SAFE_SEND_CHANNELS.has(name)) unexpectedChannels.push(`send:${name}`)
  })
  ipcMain.on(RENDERER_ERROR_CHANNEL, (_event, kind) => {
    rendererErrors.push(String(kind).slice(0, 80))
  })

  smokeWindow = new BrowserWindow({
    show: false,
    width: 1000,
    height: 760,
    webPreferences: {
      allowRunningInsecureContent: false,
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, 'preload.cjs'),
      sandbox: true,
      spellcheck: false,
      webSecurity: true
    }
  })
  smokeWindow.setMenuBarVisibility(false)
  smokeWindow.webContents.setWindowOpenHandler(() => ({ action: 'deny' }))
  smokeWindow.webContents.on('will-attach-webview', (event) => event.preventDefault())
  smokeWindow.webContents.on('will-navigate', (event, url) => {
    if (!isTrustedRendererNavigation(url)) event.preventDefault()
  })
  smokeWindow.webContents.on('will-redirect', (event, url) => {
    if (!isTrustedRendererNavigation(url)) event.preventDefault()
  })
  smokeWindow.webContents.on('did-fail-load', (_event, code, description) => {
    finish(1, { code, description: String(description).slice(0, 120), stage: 'load' })
  })
  smokeWindow.webContents.on('render-process-gone', (_event, details) => {
    finish(1, { reason: details.reason, stage: 'renderer-gone' })
  })

  await smokeWindow.loadFile(smokePaths.rendererPath)
  await waitForRendererProof(smokeWindow)
  const proof = await observeRendererStability(smokeWindow)

  finish(0, {
    blockedNetworkRequests: blockedRequests.length,
    forbiddenSystemCalls: forbiddenChannels.length,
    invokedChannels: [...invokedChannels].sort(),
    proof,
    renderer: 'production-out/renderer/index.html'
  })
}

app.commandLine.appendSwitch('disable-background-networking')
app.commandLine.appendSwitch('disable-component-update')
app.commandLine.appendSwitch('disable-domain-reliability')
app.commandLine.appendSwitch(
  'disable-features',
  'AsyncDns,DnsOverHttps,MediaRouter,OptimizationHints,Translate'
)
app.commandLine.appendSwitch('host-resolver-rules', 'MAP * ~NOTFOUND')
app.commandLine.appendSwitch('disable-sync')
app.commandLine.appendSwitch('no-proxy-server')
app.disableHardwareAcceleration()
app.on('window-all-closed', () => {})
app
  .whenReady()
  .then(runSmoke)
  .catch((error) => {
    finish(1, { message: error instanceof Error ? error.message : String(error), stage: 'main' })
  })

setTimeout(() => {
  finish(1, { message: 'Electron smoke internal timeout', stage: 'timeout' })
}, 25_000).unref()
