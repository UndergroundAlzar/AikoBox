import { join } from 'path'
import { readFileSync, writeFileSync } from 'fs'
import { BrowserWindow, Menu, screen, shell } from 'electron'
import { is } from '@electron-toolkit/utils'
import icon from '../../resources/icon.png?asset'
import { getAppConfig } from './config'
import { quitWithoutCore } from './core/manager'
import {
  handleWindowsQuerySessionEnd,
  handleWindowsSessionEnd,
  setLifecycleWindowStateSaver
} from './lifecycle'
import { hideDockIcon, showDockIcon } from './resolve/tray'
import { isCiIsolatedSmokeMode } from './utils/ciIsolatedSmoke'
import { dataDir } from './utils/dirs'
import { mainWindowLogger } from './utils/logger'
import { isTrustedRendererUrl, normalizeExternalHttpUrl } from './utils/electronSecurity'

interface WindowState {
  width: number
  height: number
  x?: number
  y?: number
  isMaximized?: boolean
}

// 内存态，最大化期间保留上次普通尺寸（#1954）。
let windowState: WindowState = { width: 800, height: 600 }
const rendererRoot = join(__dirname, '../renderer')

function openExternalBrowserUrl(value: string): void {
  const url = normalizeExternalHttpUrl(value)
  if (!url) {
    mainWindowLogger.warn('Blocked unsafe external URL').catch(() => {})
    return
  }

  void shell.openExternal(url).catch((error) => {
    mainWindowLogger.warn('Failed to open external URL', error).catch(() => {})
  })
}

function windowStateFile(): string {
  return join(dataDir(), 'window-state.json')
}

// 拒绝 NaN/Infinity/0/负/小数；坐标副屏可为负。
function isValidSize(n: unknown): n is number {
  return typeof n === 'number' && Number.isInteger(n) && n > 0
}

function isValidCoord(n: unknown): n is number {
  return typeof n === 'number' && Number.isInteger(n)
}

function loadWindowState(): WindowState {
  try {
    const parsed = JSON.parse(readFileSync(windowStateFile(), 'utf-8')) as Partial<WindowState>
    if (isValidSize(parsed.width) && isValidSize(parsed.height)) {
      return {
        width: parsed.width,
        height: parsed.height,
        x: isValidCoord(parsed.x) ? parsed.x : undefined,
        y: isValidCoord(parsed.y) ? parsed.y : undefined,
        isMaximized: parsed.isMaximized === true
      }
    }
  } catch {
    // 缺失/损坏，回退默认
  }
  return { width: 800, height: 600 }
}

function isNormalWindow(window: BrowserWindow): boolean {
  return !window.isMaximized() && !window.isMinimized() && !window.isFullScreen()
}

// 仅可见时采集（隐藏态 bounds 脏）。getContentBounds 防 Win DPI 逐次变大（#1857）；
// trackBounds=false 只记最大化标志（unmaximize 尺寸未稳定）（#1954）。
function updateWindowState(window: BrowserWindow, trackBounds = true): void {
  if (window.isDestroyed() || !window.isVisible()) return
  try {
    if (trackBounds && isNormalWindow(window)) {
      const bounds = window.getContentBounds()
      windowState.width = bounds.width
      windowState.height = bounds.height
      windowState.x = bounds.x
      windowState.y = bounds.y
    }
    windowState.isMaximized = window.isMaximized()
  } catch {
    // 窗口销毁中
  }
}

function persistWindowState(): void {
  try {
    writeFileSync(windowStateFile(), JSON.stringify(windowState))
  } catch {
    // 忽略
  }
}

// 采集 + 落盘。仅关窗/退出/会话结束调用（resize 只入内存）。
function saveWindowState(window: BrowserWindow): void {
  updateWindowState(window)
  persistWindowState()
}

function ensureVisibleOnScreen(state: WindowState): WindowState {
  const { x, y } = state
  if (x === undefined || y === undefined) return state
  const visible = screen.getAllDisplays().some((d) => {
    const b = d.bounds
    return x >= b.x && y >= b.y && x < b.x + b.width && y < b.y + b.height
  })
  if (visible) return state
  // 屏外：丢坐标居中，留尺寸/最大化。
  return { width: state.width, height: state.height, isMaximized: state.isMaximized }
}

export let mainWindow: BrowserWindow | null = null
let quitTimeout: NodeJS.Timeout | null = null
let createWindowPromise: Promise<void> | null = null

// 主窗口 renderer 崩溃自动恢复的防抖，避免崩溃循环时无限重建
const MAIN_WINDOW_CRASH_WINDOW = 60 * 1000
const MAIN_WINDOW_MAX_CRASH_RECOVERIES = 3
let mainWindowCrashTimestamps: number[] = []
type AutoQuitWithoutCoreMode = NonNullable<IAppConfig['autoQuitWithoutCoreMode']>

export async function createWindow(): Promise<void> {
  if (mainWindow && !mainWindow.isDestroyed()) return
  if (createWindowPromise) return createWindowPromise

  createWindowPromise = createWindowInternal().finally(() => {
    createWindowPromise = null
  })
  return createWindowPromise
}

async function createWindowInternal(): Promise<void> {
  const {
    useWindowFrame = false,
    silentStart = false,
    autoQuitWithoutCore = false,
    autoQuitWithoutCoreDelay = 60,
    autoQuitWithoutCoreMode = 'core'
  } = await getAppConfig()

  // Isolated CI smoke must stay fully headless even when silentStart is off or is.dev.
  const isolatedSmoke = isCiIsolatedSmokeMode()
  const effectiveSilentStart = isolatedSmoke || silentStart

  windowState = ensureVisibleOnScreen(loadWindowState())
  const savedState = windowState

  Menu.setApplicationMenu(null)
  mainWindow = new BrowserWindow({
    minWidth: 800,
    minHeight: 600,
    width: savedState.width,
    height: savedState.height,
    x: savedState.x,
    y: savedState.y,
    show: false,
    frame: useWindowFrame,
    fullscreenable: false,
    titleBarStyle: useWindowFrame ? 'default' : 'hidden',
    titleBarOverlay: useWindowFrame
      ? false
      : {
          height: 49
        },
    autoHideMenuBar: true,
    // Win 显式指定 icon，避免异常/恢复路径下任务栏与窗口图标依赖默认 exe
    ...(process.platform === 'linux' || process.platform === 'win32' ? { icon: icon } : {}),
    webPreferences: {
      preload: join(__dirname, '../preload/index.cjs'),
      spellcheck: false,
      sandbox: true,
      nodeIntegration: false,
      contextIsolation: true,
      devTools: is.dev,
      webSecurity: true,
      webviewTag: false,
      navigateOnDragDrop: false
    }
  })

  if (savedState.isMaximized && !effectiveSilentStart) {
    mainWindow.maximize()
  }

  setupWindowEvents(mainWindow, {
    silentStart: effectiveSilentStart,
    forceHidden: isolatedSmoke,
    autoQuitWithoutCore,
    autoQuitWithoutCoreDelay,
    autoQuitWithoutCoreMode
  })

  if (is.dev) {
    mainWindow.webContents.openDevTools()
  }

  if (is.dev && process.env['ELECTRON_RENDERER_URL']) {
    mainWindow.loadURL(process.env['ELECTRON_RENDERER_URL'])
  } else {
    mainWindow.loadFile(join(__dirname, '../renderer/index.html'))
  }
}

interface WindowConfig {
  silentStart: boolean
  /** Isolated CI smoke: never auto-show, even in is.dev. */
  forceHidden: boolean
  autoQuitWithoutCore: boolean
  autoQuitWithoutCoreDelay: number
  autoQuitWithoutCoreMode: AutoQuitWithoutCoreMode
}

function setupWindowEvents(window: BrowserWindow, config: WindowConfig): void {
  const {
    silentStart,
    forceHidden,
    autoQuitWithoutCore,
    autoQuitWithoutCoreDelay,
    autoQuitWithoutCoreMode
  } = config

  window.on('ready-to-show', () => {
    if (autoQuitWithoutCore && !window.isVisible()) {
      scheduleQuitWithoutCore(autoQuitWithoutCoreDelay, autoQuitWithoutCoreMode)
    }

    // Isolated CI smoke stays hidden. Otherwise silentStart hides; is.dev always shows.
    if (forceHidden) return
    if (!silentStart || is.dev) {
      clearQuitTimeout()
      window.show()
      window.focusOnWebView()
    }
  })

  window.webContents.on('did-fail-load', () => {
    window.webContents.reload()
  })

  // renderer 崩溃时外壳仍在（isDestroyed() 为 false）、did-fail-load 不触发，会白屏；销毁并按需重建
  window.webContents.on('render-process-gone', (_event, details) => {
    mainWindowLogger.error('Main window render process gone', details.reason).catch(() => {})

    if (mainWindow !== window || window.isDestroyed()) return

    const wasVisible = window.isVisible()

    mainWindow = null
    window.destroy()

    const now = Date.now()
    mainWindowCrashTimestamps = mainWindowCrashTimestamps.filter(
      (timestamp) => now - timestamp < MAIN_WINDOW_CRASH_WINDOW
    )
    mainWindowCrashTimestamps.push(now)

    if (mainWindowCrashTimestamps.length > MAIN_WINDOW_MAX_CRASH_RECOVERIES) {
      mainWindowLogger
        .error(
          `Main window renderer crashed ${mainWindowCrashTimestamps.length} times within ${MAIN_WINDOW_CRASH_WINDOW}ms, stop auto-recovery`
        )
        .catch(() => {})
      return
    }

    // 可见时立即重建，否则留待下次 showMainWindow()，避免后台崩溃突然弹窗
    if (wasVisible) {
      void createWindow().then(() => {
        clearQuitTimeout()
        mainWindow?.show()
        mainWindow?.focusOnWebView()
      })
    }
  })

  window.webContents.on('unresponsive', () => {
    mainWindowLogger.error('Main window unresponsive').catch(() => {})
  })

  window.on('show', () => {
    showDockIcon()
  })

  window.on('close', async (event) => {
    saveWindowState(window) // 关窗前兜底（#1954）

    event.preventDefault()
    window.hide()

    const {
      autoQuitWithoutCore = false,
      autoQuitWithoutCoreDelay = 60,
      autoQuitWithoutCoreMode = 'core',
      useDockIcon = true
    } = await getAppConfig()

    if (!useDockIcon) {
      hideDockIcon()
    }

    if (autoQuitWithoutCore) {
      scheduleQuitWithoutCore(autoQuitWithoutCoreDelay, autoQuitWithoutCoreMode)
    }
  })

  window.on('closed', () => {
    if (mainWindow === window) {
      mainWindow = null
    }
  })

  // 用 resize/move（Wayland 常不触发 resized/moved），只入内存，落盘留给关窗/退出（#1954）
  window.on('resize', () => updateWindowState(window))
  window.on('move', () => updateWindowState(window))
  window.on('maximize', () => updateWindowState(window, false))
  window.on('unmaximize', () => updateWindowState(window, false))

  window.on('session-end', () => {
    saveWindowState(window)
    handleWindowsSessionEnd()
  })

  window.on('query-session-end', (event) => {
    saveWindowState(window)
    handleWindowsQuerySessionEnd(event)
  })

  window.webContents.setWindowOpenHandler((details) => {
    openExternalBrowserUrl(details.url)
    return { action: 'deny' }
  })

  // Never let application content navigate the privileged top-level renderer
  // to an external origin. Browser URLs are delegated to the system browser.
  window.webContents.on('will-navigate', (event, url) => {
    if (isTrustedRendererUrl(url, rendererRoot, undefined, is.dev)) return
    event.preventDefault()
    openExternalBrowserUrl(url)
  })
  window.webContents.on('will-redirect', (event, url) => {
    if (isTrustedRendererUrl(url, rendererRoot, undefined, is.dev)) return
    event.preventDefault()
    openExternalBrowserUrl(url)
  })
}

function scheduleQuitWithoutCore(
  delaySeconds: number,
  mode: AutoQuitWithoutCoreMode = 'core'
): void {
  clearQuitTimeout()
  quitTimeout = setTimeout(async () => {
    if (mode === 'tray') {
      if (mainWindow && !mainWindow.isVisible()) {
        mainWindow.destroy()
        hideDockIcon()
      }
      return
    }

    await quitWithoutCore()
  }, delaySeconds * 1000)
}

export function clearQuitTimeout(): void {
  if (quitTimeout) {
    clearTimeout(quitTimeout)
    quitTimeout = null
  }
}

export function triggerMainWindow(force?: boolean): void {
  if (!mainWindow || mainWindow.isDestroyed()) {
    showMainWindow()
    return
  }

  getAppConfig()
    .then(({ triggerMainWindowBehavior = 'toggle' }) => {
      if (force === true || triggerMainWindowBehavior === 'toggle') {
        if (mainWindow?.isVisible()) {
          closeMainWindow()
        } else {
          showMainWindow()
        }
      } else {
        showMainWindow()
      }
    })
    .catch(showMainWindow)
}

export function showMainWindow(): void {
  clearQuitTimeout()

  if (mainWindow && !mainWindow.isDestroyed()) {
    clearQuitTimeout()
    // 兜底：renderer 已崩溃但 render-process-gone 尚未触发时，先 reload 再显示，避免白屏
    if (mainWindow.webContents.isCrashed()) {
      mainWindow.webContents.reload()
    }
    mainWindow.show()
    mainWindow.focusOnWebView()
    return
  }

  void createWindow().then(() => {
    clearQuitTimeout()
    mainWindow?.show()
    mainWindow?.focusOnWebView()
  })
}

export function closeMainWindow(): void {
  mainWindow?.close()
}

// 退出兜底：硬退出（app.exit）不触发窗口 close（#1954）。
export function saveMainWindowState(): void {
  if (mainWindow && !mainWindow.isDestroyed()) {
    saveWindowState(mainWindow)
  }
}

setLifecycleWindowStateSaver(saveMainWindowState)
