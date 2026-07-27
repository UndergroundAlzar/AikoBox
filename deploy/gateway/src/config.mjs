// Load configuration from an environment object (injectable for tests). Pure: no I/O.
// The origin CA file, if configured, is read separately by server.mjs.
export function loadConfig(env = process.env) {
  const num = (v, d) => {
    const n = Number(v)
    return Number.isFinite(n) ? n : d
  }
  const domain = env.DOMAIN || 'localhost'
  return Object.freeze({
    port: num(env.PORT, 8080),
    dbPath: env.DB_PATH || '/data/gateway.db',
    publicOrigin: env.PUBLIC_ORIGIN || `https://${domain}`,
    deviceLimitDefault: num(env.DEVICE_LIMIT_DEFAULT, 3),
    codeTtlMs: num(env.CODE_TTL_MS, 60000),
    codePoolMax: num(env.CODE_POOL_MAX, 10000),
    nonceTtlMs: num(env.NONCE_TTL_MS, 60000),
    noncePoolMax: num(env.NONCE_POOL_MAX, 8),
    clockSkewMs: num(env.CLOCK_SKEW_MS, 300000),
    loginMax: num(env.LOGIN_MAX, 10),
    loginWindowMs: num(env.LOGIN_WINDOW_MS, 60000),
    loginAccountMax: num(env.LOGIN_ACCOUNT_MAX, 10),
    loginAccountWindowMs: num(env.LOGIN_ACCOUNT_WINDOW_MS, 60000),
    trustedProxyCidrs: (env.TRUSTED_PROXY_CIDRS || '')
      .split(',')
      .map((v) => v.trim())
      .filter(Boolean),
    subTimeoutMs: num(env.SUB_TIMEOUT_MS, 30000),
    subMaxBytes: num(env.SUB_MAX_BYTES, 10 * 1024 * 1024),
    retired: env.RETIRED === 'true',
    originCaFile: env.ORIGIN_CA_FILE || ''
  })
}
