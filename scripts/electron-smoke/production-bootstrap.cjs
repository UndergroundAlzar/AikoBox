'use strict'

/**
 * Fail-closed bootstrap for a future production main/preload Electron smoke.
 *
 * Loaded only under the GitHub-hosted Windows production-smoke gate. It installs
 * process-creation tripwires before requiring production main and refuses to
 * continue unless isolated CI mode is explicitly enabled.
 */

const path = require('node:path')

const PROD_SMOKE_TOKEN = 'aikobox-github-windows-electron-prod-smoke-v1'

function assertProdSmokeGate() {
  const allowed =
    process.platform === 'win32' &&
    process.env.CI === 'true' &&
    process.env.GITHUB_ACTIONS === 'true' &&
    process.env.RUNNER_OS === 'Windows' &&
    process.env.RUNNER_ENVIRONMENT === 'github-hosted' &&
    process.env.AIKOBOX_ELECTRON_PROD_SMOKE_TOKEN === PROD_SMOKE_TOKEN &&
    process.env.AIKOBOX_CI_ISOLATED_SMOKE === '1'
  if (!allowed) {
    throw new Error(
      'The production Electron smoke bootstrap is restricted to an isolated GitHub-hosted Windows job'
    )
  }
}

assertProdSmokeGate()

const childProcess = require('node:child_process')
const blockedMethods = [
  'exec',
  'execFile',
  'execFileSync',
  'execSync',
  'fork',
  'spawn',
  'spawnSync'
]
for (const method of blockedMethods) {
  childProcess[method] = () => {
    throw new Error(`SYSTEM_SIDE_EFFECT_BLOCKED:${method}`)
  }
}

const mainPath = process.argv[2]
if (!mainPath || path.basename(mainPath) !== 'index.js') {
  throw new Error('Production main path is missing or unexpected')
}
if (!mainPath.replace(/\\/g, '/').endsWith('/out/main/index.js')) {
  throw new Error('Production main path must resolve to out/main/index.js')
}

// Production main now has isCiIsolatedSmokeMode() gates for core/sysproxy/admin
// recovery, but tray/window/init still need a full tripwire-compatible path.
// Refuse to load until that path is complete so a partial job cannot touch OS state.
throw new Error(
  'Production main isolation hooks exist; full bootstrap load remains fail-closed until tray/init are isolation-safe'
)
