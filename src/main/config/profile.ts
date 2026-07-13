import { access, readFile, realpath, rm, writeFile } from 'fs/promises'
import { constants, existsSync } from 'fs'
import { execFile } from 'child_process'
import { createHash } from 'crypto'
import { isAbsolute, join, relative, resolve } from 'path'
import { promisify } from 'util'
import { app } from 'electron'
import i18next from 'i18next'
import axios, { AxiosResponse } from 'axios'
import { parse, stringify } from '../utils/yaml'
import { defaultProfile } from '../utils/template'
import { decryptAgeContent } from '../utils/age'
import { mihomoCloseAllConnections, mihomoHotReloadConfig } from '../core/mihomoApi'
import { restartCore } from '../core/manager'
import { getHealthyProxyEndpoint } from '../core/healthyProxyEndpoint'
import { generateProfile } from '../core/factory'
import { addProfileUpdater, removeProfileUpdater } from '../core/profileUpdater'
import { mihomoProfileWorkDir, mihomoWorkDir, profileConfigPath, profilePath } from '../utils/dirs'
import { createLogger } from '../utils/logger'
import { getAppConfig } from './app'
import {
  assertHttpUrl,
  assertSafeHttpRedirect,
  assertRemoteText,
  conditionalRequestHeaders,
  readHttpCacheMetadata,
  writeFileAtomically,
  writeHttpCacheMetadata
} from './remoteResource'
import { normalizeSubscriptionPayload } from './subscriptionPayload'

const profileLogger = createLogger('Profile')
const execFilePromise = promisify(execFile)

let profileConfig: IProfileConfig
let profileConfigWriteQueue: Promise<void> = Promise.resolve()
let changeProfileQueue: Promise<void> = Promise.resolve()
// Complete request identities deduplicate equivalent updates; different credentials,
// headers or routing policies serialize so an older response cannot win a race.
const inflightRemoteFetches = new Map<
  string,
  { requestIdentity: string; promise: Promise<IProfileItem> }
>()
const profileContentWriteQueues = new Map<string, Promise<void>>()

function assertSafeProfileId(id: string): void {
  if (!/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(id) || id === '.' || id === '..') {
    throw new Error('Invalid profile id')
  }
}

function profileHttpMetadataPath(id: string): string {
  assertSafeProfileId(id)
  return `${profilePath(id)}.http.json`
}

function isPermissionError(error: unknown): boolean {
  const code = (error as NodeJS.ErrnoException)?.code
  return code === 'EACCES' || code === 'EPERM'
}

function assertInsideWorkDir(targetPath: string): void {
  const relativePath = relative(resolve(mihomoWorkDir()), resolve(targetPath))
  if (!relativePath || relativePath.startsWith('..') || isAbsolute(relativePath)) {
    throw new Error(`Refusing to delete outside work directory: ${targetPath}`)
  }
}

async function canRemoveProfileWorkDir(workDir: string): Promise<boolean> {
  try {
    await Promise.all([
      access(mihomoWorkDir(), constants.W_OK | constants.X_OK),
      access(workDir, constants.R_OK | constants.W_OK | constants.X_OK)
    ])
    return true
  } catch {
    return false
  }
}

async function removeProfileWorkDirWithPkexec(workDir: string): Promise<void> {
  assertInsideWorkDir(workDir)
  await execFilePromise('pkexec', ['rm', '-rf', '--', workDir])
}

async function removeProfileWorkDir(id: string): Promise<void> {
  assertSafeProfileId(id)
  const workDir = mihomoProfileWorkDir(id)
  if (!existsSync(workDir)) return
  assertInsideWorkDir(workDir)

  if (process.platform === 'linux' && !(await canRemoveProfileWorkDir(workDir))) {
    await removeProfileWorkDirWithPkexec(workDir)
    return
  }

  try {
    await rm(workDir, { recursive: true, force: true })
  } catch (error) {
    if (process.platform !== 'linux' || !isPermissionError(error)) {
      throw error
    }

    await removeProfileWorkDirWithPkexec(workDir)
  }
}

export async function getProfileConfig(force = false): Promise<IProfileConfig> {
  if (force || !profileConfig) {
    const data = await readFile(profileConfigPath(), 'utf-8')
    profileConfig = parse(data) || { items: [] }
  }
  if (typeof profileConfig !== 'object') profileConfig = { items: [] }
  if (!Array.isArray(profileConfig.items)) profileConfig.items = []
  return JSON.parse(JSON.stringify(profileConfig))
}

export async function setProfileConfig(config: IProfileConfig): Promise<void> {
  profileConfigWriteQueue = profileConfigWriteQueue
    .catch(() => {})
    .then(async () => {
      const next = JSON.parse(JSON.stringify(config)) as IProfileConfig
      await writeFileAtomically(profileConfigPath(), stringify(next))
      profileConfig = next
    })
  await profileConfigWriteQueue
}

export async function updateProfileConfig(
  updater: (config: IProfileConfig) => IProfileConfig | Promise<IProfileConfig>
): Promise<IProfileConfig> {
  let result: IProfileConfig | undefined
  profileConfigWriteQueue = profileConfigWriteQueue
    .catch(() => {})
    .then(async () => {
      const data = await readFile(profileConfigPath(), 'utf-8')
      profileConfig = parse(data) || { items: [] }
      if (typeof profileConfig !== 'object') profileConfig = { items: [] }
      if (!Array.isArray(profileConfig.items)) profileConfig.items = []
      const next = await updater(JSON.parse(JSON.stringify(profileConfig)))
      await writeFileAtomically(profileConfigPath(), stringify(next))
      profileConfig = next
      result = next
    })
  await profileConfigWriteQueue
  return JSON.parse(JSON.stringify(result ?? profileConfig))
}

export async function getProfileItem(id: string | undefined): Promise<IProfileItem | undefined> {
  const { items } = await getProfileConfig()
  if (!id || id === 'default')
    return { id: 'default', type: 'local', name: i18next.t('profiles.emptyProfile') }
  return items.find((item) => item.id === id)
}

export async function changeCurrentProfile(id: string): Promise<void> {
  // 使用队列确保 profile 切换串行执行，避免竞态条件
  let taskError: unknown = null
  changeProfileQueue = changeProfileQueue
    .catch(() => {})
    .then(async () => {
      const { current } = await getProfileConfig()
      if (current === id) return

      try {
        await updateProfileConfig((config) => {
          config.current = id
          return config
        })
        const { useHotReloadProfile = false, hotReloadProfileAutoCloseConnection = false } =
          await getAppConfig()
        if (useHotReloadProfile) {
          await mihomoHotReloadConfig()
          if (hotReloadProfileAutoCloseConnection) {
            try {
              await mihomoCloseAllConnections()
            } catch (error) {
              profileLogger.warn('Failed to close connections after profile hot reload', error)
            }
          }
        } else {
          await restartCore()
        }
      } catch (e) {
        // 回滚配置
        await updateProfileConfig((config) => {
          config.current = current
          return config
        })
        try {
          await restartCore()
        } catch (rollbackError) {
          profileLogger.error(
            'Failed to restart the previous profile after rollback',
            rollbackError
          )
        }
        taskError = e
      }
    })
  await changeProfileQueue
  if (taskError) {
    throw taskError
  }
}

export async function updateProfileItem(item: IProfileItem): Promise<void> {
  await updateProfileConfig((config) => {
    const index = config.items.findIndex((i) => i.id === item.id)
    if (index === -1) {
      throw new Error('Profile not found')
    }
    config.items[index] = item
    return config
  })
}

export async function addProfileItem(item: Partial<IProfileItem>): Promise<void> {
  const newItem = await createProfile(item)
  let shouldChangeCurrent = false
  let newProfileIsCurrentAfterUpdate = false
  await updateProfileConfig((config) => {
    const existingIndex = config.items.findIndex((i) => i.id === newItem.id)
    if (existingIndex !== -1) {
      config.items[existingIndex] = newItem
    } else {
      config.items.push(newItem)
    }
    if (!config.current) {
      shouldChangeCurrent = true
      newProfileIsCurrentAfterUpdate = true
    }
    return config
  })

  // If the new profile will become the current profile, ensure generateProfile is called
  // to prepare working directory before restarting core
  if (newProfileIsCurrentAfterUpdate) {
    const { diffWorkDir } = await getAppConfig()
    if (diffWorkDir) {
      try {
        await generateProfile()
      } catch (error) {
        profileLogger.warn('Failed to generate profile for new subscription', error)
      }
    }
  }

  if (shouldChangeCurrent) {
    await changeCurrentProfile(newItem.id)
  }
  await addProfileUpdater(newItem)
}

export async function removeProfileItem(id: string): Promise<void> {
  assertSafeProfileId(id)
  await removeProfileUpdater(id)

  let shouldRestart = false
  let removedItem: IProfileItem | undefined
  await updateProfileConfig((config) => {
    removedItem = config.items?.find((item) => item.id === id)
    config.items = config.items?.filter((item) => item.id !== id)
    if (config.current === id) {
      shouldRestart = true
      config.current = config.items.length > 0 ? config.items[0].id : undefined
    }
    return config
  })

  if (existsSync(profilePath(id))) {
    await rm(profilePath(id))
  }
  await rm(profileHttpMetadataPath(id), { force: true })
  if (shouldRestart) {
    await restartCore()
  }
  await removeProfileWorkDir(id)

  if (removedItem?.type === 'plugin' && removedItem.pluginId) {
    const { removePluginItem } = await import('./plugin')
    const { removeVault } = await import('../resolve/plugin/vault')
    const { revokePluginDevice } = await import('../resolve/plugin')
    const { mainWindow } = await import('../window')
    // best-effort 通知服务端解绑设备（需 vault，故在 removeVault 之前）；失败不阻塞删除
    await revokePluginDevice(removedItem.pluginId)
    await removePluginItem(removedItem.pluginId)
    await removeVault(removedItem.pluginId)
    mainWindow?.webContents.send('pluginConfigUpdated')
  }
}

export async function getCurrentProfileItem(): Promise<IProfileItem> {
  const { current } = await getProfileConfig()
  return (
    (await getProfileItem(current)) || {
      id: 'default',
      type: 'local',
      name: i18next.t('profiles.emptyProfile')
    }
  )
}

interface FetchOptions {
  url: string
  useProxy: boolean
  mixedPort: number
  userAgent: string
  ageSecretKey?: string
  authToken?: string
  timeout: number
  conditionalHeaders?: Record<string, string>
}

interface FetchResult {
  data: string
  headers: Record<string, string>
  notModified: boolean
  usedProxy: boolean
}

const MAX_TIMER_DELAY_MS = 2_147_483_647
const MAX_PROFILE_INTERVAL_MINUTES = Math.floor(MAX_TIMER_DELAY_MS / (60 * 1000))
const DEFAULT_SUBSCRIPTION_TIMEOUT_MS = 30000
const MAX_SUBSCRIPTION_TIMEOUT_MS = 5 * 60 * 1000

function boundedSubscriptionTimeout(value: unknown, fallback: number): number {
  const timeout = Number(value)
  if (!Number.isFinite(timeout) || timeout <= 0) return fallback
  return Math.min(Math.max(Math.round(timeout), 1000), MAX_SUBSCRIPTION_TIMEOUT_MS)
}

function isValidProxyPort(value: unknown): value is number {
  return Number.isInteger(value) && Number(value) > 0 && Number(value) <= 65535
}

function subscriptionRequestIdentity(options: {
  profileId: string
  url: string
  authToken?: string
  userAgent: string
  useProxy: boolean
  ageSecretKey?: string
}): string {
  const secretHash = (value: string | undefined): string | undefined =>
    value
      ? createHash('sha256').update('aikobox-subscription-secret\0').update(value).digest('hex')
      : undefined
  return createHash('sha256')
    .update(
      JSON.stringify({
        version: 1,
        profileId: options.profileId,
        url: options.url,
        authorization: secretHash(options.authToken),
        userAgent: options.userAgent,
        policy: options.useProxy ? 'proxy-only' : 'direct-fallback',
        ageSecretKey: secretHash(options.ageSecretKey)
      })
    )
    .digest('hex')
}

function redactSubscriptionUrl(url: string): string {
  try {
    const urlObj = new URL(url)
    urlObj.username = ''
    urlObj.password = ''
    if (urlObj.pathname && urlObj.pathname !== '/') urlObj.pathname = '/***'
    if (urlObj.search) urlObj.search = '?***'
    urlObj.hash = ''
    return urlObj.toString()
  } catch {
    return '[redacted subscription URL]'
  }
}

function subscriptionAttemptErrorMessage(error: unknown): string {
  const message = (error instanceof Error ? error.message : String(error))
    .replace(/[\r\n\t]+/g, ' ')
    .trim()
  if (!message) return 'unknown request error'
  if (/https?:\/\//i.test(message)) return 'network request failed'
  if (/\b(?:Bearer|Basic|token|password|secret|authorization|credential)\b/i.test(message)) {
    return 'subscription request failed (sensitive details redacted)'
  }
  return message
    .replace(/\b(?:Bearer|Basic)\s+[A-Za-z0-9._~+/=-]+/gi, '[redacted authorization]')
    .replace(
      /\b(token|password|secret|authorization|credential)(\s*[:=]\s*)[^\s,;]+/gi,
      '$1$2[redacted]'
    )
    .slice(0, 512)
}

function sanitizedSubscriptionAttemptError(error: unknown): Error {
  return new Error(subscriptionAttemptErrorMessage(error))
}

function normalizeAxiosHeaders(headers: AxiosResponse['headers']): Record<string, string> {
  const normalized: Record<string, string> = {}
  Object.entries(headers as Record<string, unknown>).forEach(([key, value]) => {
    if (Array.isArray(value)) {
      normalized[key.toLowerCase()] = value.join(', ')
    } else if (value !== undefined) {
      normalized[key.toLowerCase()] = String(value)
    }
  })
  return normalized
}

function parsedProfileSummary(parsed: Record<string, unknown>): string {
  const topKeys = Object.keys(parsed).slice(0, 20)
  const proxies = parsed['proxies']
  const proxyProviders = parsed['proxy-providers']
  const proxyCount = Array.isArray(proxies) ? proxies.length : undefined
  const providerCount =
    proxyProviders && typeof proxyProviders === 'object'
      ? Object.keys(proxyProviders).length
      : undefined

  return JSON.stringify({
    topKeys,
    hasProxies: Boolean(proxies),
    hasProxyProviders: Boolean(proxyProviders),
    proxyCount,
    providerCount
  })
}

async function fetchAndValidateSubscription(options: FetchOptions): Promise<FetchResult> {
  const { url, useProxy, mixedPort, userAgent, authToken, timeout } = options
  const redactedUrl = redactSubscriptionUrl(url)
  const fetchMode = useProxy ? 'proxy' : 'direct'

  const headers: Record<string, string> = {
    'User-Agent': userAgent,
    'Accept-Encoding': 'identity',
    ...options.conditionalHeaders
  }
  if (authToken) headers['Authorization'] = authToken
  for (const [name, value] of Object.entries(headers)) {
    if (/[^\x20-\x7E]/.test(value) || value.length > 8192) {
      throw new Error(`Subscription request header "${name}" is invalid`)
    }
  }

  await profileLogger.info(
    `Fetching remote profile url=${redactedUrl} mode=${fetchMode} timeout=${timeout}ms auth=${authToken ? 'yes' : 'no'}`
  )

  const requestUrl = url
  let hasSensitiveRedirectContext = Boolean(authToken)
  let proxy:
    | {
        protocol: 'http'
        host: string
        port: number
      }
    | false = false

  if (useProxy && !isValidProxyPort(mixedPort)) {
    throw new Error('Subscription proxy-only mode requires a valid local mixed proxy port')
  }

  if (useProxy) {
    const parsedUrl = assertHttpUrl(url, 'Subscription URL')
    hasSensitiveRedirectContext ||= Boolean(parsedUrl.username || parsedUrl.password)
    proxy = { protocol: 'http', host: '127.0.0.1', port: mixedPort }
  } else {
    const parsedUrl = assertHttpUrl(url, 'Subscription URL')
    hasSensitiveRedirectContext ||= Boolean(parsedUrl.username || parsedUrl.password)
  }

  let res: AxiosResponse<string>
  try {
    res = await axios.get<string>(requestUrl, {
      headers,
      responseType: 'text',
      timeout,
      signal: AbortSignal.timeout(timeout),
      proxy,
      maxRedirects: 5,
      maxContentLength: 32 * 1024 * 1024,
      maxBodyLength: 32 * 1024 * 1024,
      beforeRedirect: (redirectOptions) => {
        assertSafeHttpRedirect(
          requestUrl,
          redirectOptions,
          'Subscription',
          hasSensitiveRedirectContext
        )
      },
      validateStatus: () => true,
      transformResponse: [(data) => data]
    })
  } catch (error) {
    const sanitizedError = sanitizedSubscriptionAttemptError(error)
    await profileLogger.warn(
      `Remote profile request failed url=${redactedUrl} mode=${fetchMode}`,
      sanitizedError
    )
    throw sanitizedError
  }

  const data = typeof res.data === 'string' ? res.data : String(res.data ?? '')
  const responseHeaders = normalizeAxiosHeaders(res.headers)

  await profileLogger.info(
    `Remote profile response url=${redactedUrl} mode=${fetchMode} status=${res.status} contentType=${String(
      responseHeaders['content-type'] || ''
    )} bytes=${Buffer.byteLength(data, 'utf8')}`
  )

  if (res.status === 304) {
    return { data: '', headers: responseHeaders, notModified: true, usedProxy: useProxy }
  }
  if (res.status < 200 || res.status >= 300) {
    await profileLogger.warn(
      `Remote profile request rejected url=${redactedUrl} mode=${fetchMode} status=${res.status}`
    )
    throw new Error(`Subscription failed: Request status code ${res.status}`)
  }

  assertRemoteText(data, responseHeaders['content-type'], 'Subscription')
  const decryptedData = await decryptAgeContent(data, options.ageSecretKey, 'subscription')
  let normalized: ReturnType<typeof normalizeSubscriptionPayload>
  try {
    normalized = normalizeSubscriptionPayload(decryptedData)
  } catch (error) {
    await profileLogger.warn(
      `Remote profile parse failed url=${redactedUrl} mode=${fetchMode}`,
      error
    )
    throw new Error(
      `Subscription failed: ${error instanceof Error ? error.message : String(error)}`
    )
  }
  if (options.ageSecretKey && normalized.format !== 'clash-yaml') {
    throw new Error('Subscription failed: encrypted URI-list subscriptions are not supported')
  }
  const parsed = parse(normalized.content) as Record<string, unknown>
  await profileLogger.info(
    `Remote profile parsed url=${redactedUrl} mode=${fetchMode} format=${normalized.format} summary=${parsedProfileSummary(parsed)}`
  )

  return {
    data: options.ageSecretKey ? data : normalized.content,
    headers: responseHeaders,
    notModified: false,
    usedProxy: useProxy
  }
}

async function hasValidCachedSubscription(id: string, ageSecretKey?: string): Promise<boolean> {
  try {
    const content = await readFile(profilePath(id), 'utf8')
    assertRemoteText(content, undefined, 'Cached subscription')
    const decrypted = await decryptAgeContent(content, ageSecretKey, 'cached subscription')
    const normalized = normalizeSubscriptionPayload(decrypted)
    return !ageSecretKey || normalized.format === 'clash-yaml'
  } catch {
    return false
  }
}

export async function createProfile(item: Partial<IProfileItem>): Promise<IProfileItem> {
  const id = item.id || new Date().getTime().toString(16)
  assertSafeProfileId(id)
  const newItem: IProfileItem = {
    id,
    name: item.name || (item.type === 'remote' ? 'Remote File' : 'Local File'),
    type: item.type || 'local',
    url: item.url,
    interval: item.interval || 0,
    override: item.override || [],
    useProxy: item.useProxy || false,
    allowFixedInterval: item.allowFixedInterval || false,
    autoUpdate: item.autoUpdate ?? false,
    authToken: item.authToken,
    userAgent: item.userAgent,
    ageSecretKey: item.ageSecretKey,
    home: item.home,
    extra: item.extra,
    updated: new Date().getTime(),
    updateTimeout: item.updateTimeout
  }

  // Local
  if (newItem.type === 'local') {
    await setProfileStr(id, item.file || '')
    return newItem
  }

  // Remote
  if (!item.url) throw new Error('Empty URL')

  const profileUrl = item.url
  const { userAgent, subscriptionTimeout = 30000 } = await getAppConfig()
  const mixedPort = getHealthyProxyEndpoint()?.port ?? 0
  const effectiveUserAgent =
    item.userAgent || userAgent || `mihomo.party/v${app.getVersion()} (clash.meta)`
  const requestIdentity = subscriptionRequestIdentity({
    profileId: id,
    url: profileUrl,
    authToken: newItem.authToken,
    userAgent: effectiveUserAgent,
    useProxy: Boolean(newItem.useProxy),
    ageSecretKey: newItem.ageSecretKey
  })
  await profileLogger.info(
    `Creating/updating remote profile id=${id} name=${newItem.name} url=${redactSubscriptionUrl(
      profileUrl
    )} useProxy=${newItem.useProxy}`
  )
  const existing = inflightRemoteFetches.get(id)
  if (existing) {
    if (existing.requestIdentity === requestIdentity) {
      await profileLogger.info(
        `Remote profile fetch deduplicated id=${id} url=${redactSubscriptionUrl(profileUrl)}`
      )
      return existing.promise
    }
    await profileLogger.info(`Remote profile fetch queued behind another update id=${id}`)
    try {
      await existing.promise
    } catch {
      // A newer URL must still get its own attempt after an older update failed.
    }
    if (inflightRemoteFetches.get(id) === existing) inflightRemoteFetches.delete(id)
    return createProfile(item)
  }

  const promise = (async (): Promise<IProfileItem> => {
    const defaultTimeoutMs = boundedSubscriptionTimeout(
      subscriptionTimeout,
      DEFAULT_SUBSCRIPTION_TIMEOUT_MS
    )
    const userItemTimeoutMs =
      typeof newItem.updateTimeout === 'number' && newItem.updateTimeout > 0
        ? boundedSubscriptionTimeout(newItem.updateTimeout * 1000, defaultTimeoutMs)
        : defaultTimeoutMs

    const cachedMetadata = await readHttpCacheMetadata(profileHttpMetadataPath(id), requestIdentity)
    const baseOptions: Omit<FetchOptions, 'useProxy' | 'timeout'> = {
      url: profileUrl,
      mixedPort,
      userAgent: effectiveUserAgent,
      ageSecretKey: newItem.ageSecretKey,
      authToken: item.authToken,
      conditionalHeaders: conditionalRequestHeaders(cachedMetadata)
    }

    const fetchSub = (useProxy: boolean, timeout: number): Promise<FetchResult> =>
      fetchAndValidateSubscription({ ...baseOptions, useProxy, timeout })

    let result: FetchResult
    if (newItem.useProxy) {
      result = await fetchSub(Boolean(newItem.useProxy), userItemTimeoutMs)
    } else {
      try {
        result = await fetchSub(false, userItemTimeoutMs)
      } catch (directError) {
        await profileLogger.warn(
          `Direct remote profile fetch failed id=${id} url=${redactSubscriptionUrl(
            profileUrl
          )}; trying proxy fallback`,
          sanitizedSubscriptionAttemptError(directError)
        )
        if (!isValidProxyPort(mixedPort)) {
          throw sanitizedSubscriptionAttemptError(directError)
        }
        try {
          // smart fallback
          result = await fetchSub(true, defaultTimeoutMs)
        } catch (proxyError) {
          const sanitizedDirectError = sanitizedSubscriptionAttemptError(directError)
          const sanitizedProxyError = sanitizedSubscriptionAttemptError(proxyError)
          throw new AggregateError(
            [sanitizedDirectError, sanitizedProxyError],
            `Subscription failed directly (${subscriptionAttemptErrorMessage(
              sanitizedDirectError
            )}) and through the local proxy (${subscriptionAttemptErrorMessage(
              sanitizedProxyError
            )})`
          )
        }
      }
    }

    if (result.notModified && !(await hasValidCachedSubscription(id, newItem.ageSecretKey))) {
      result = await fetchAndValidateSubscription({
        ...baseOptions,
        conditionalHeaders: undefined,
        useProxy: result.usedProxy,
        timeout: userItemTimeoutMs
      })
      if (result.notModified) {
        throw new Error('Subscription returned 304 but no cached profile exists')
      }
    }

    const { data, headers } = result

    if (headers['content-disposition'] && newItem.name === 'Remote File') {
      newItem.name = parseFilename(headers['content-disposition'])
    }
    if (headers['profile-web-page-url']) {
      newItem.home = headers['profile-web-page-url']
    }
    if (headers['profile-update-interval'] && !item.allowFixedInterval) {
      const hours = Number(headers['profile-update-interval'])
      if (Number.isFinite(hours) && hours > 0) {
        newItem.interval = Math.min(Math.ceil(hours * 60), MAX_PROFILE_INTERVAL_MINUTES)
      }
    }
    if (headers['subscription-userinfo']) {
      newItem.extra = parseSubinfo(headers['subscription-userinfo'])
    }

    if (!result.notModified) {
      await setProfileStr(id, data)
      await profileLogger.info(
        `Remote profile saved id=${id} name=${newItem.name} path=${profilePath(
          id
        )} bytes=${Buffer.byteLength(data || '', 'utf8')}`
      )
    } else {
      await profileLogger.info(`Remote profile unchanged id=${id} (HTTP 304)`)
    }
    try {
      await writeHttpCacheMetadata(profileHttpMetadataPath(id), {
        // The metadata binds validators to the complete request context without
        // persisting a subscription URL, token, or other credential.
        url: requestIdentity,
        etag: headers.etag || cachedMetadata?.etag,
        lastModified: headers['last-modified'] || cachedMetadata?.lastModified,
        fetchedAt: Date.now()
      })
    } catch (error) {
      await profileLogger.warn(`Failed to save HTTP cache metadata for profile id=${id}`, error)
    }
    return newItem
  })()

  const inflight = { requestIdentity, promise }
  inflightRemoteFetches.set(id, inflight)
  try {
    return await promise
  } finally {
    if (inflightRemoteFetches.get(id) === inflight) inflightRemoteFetches.delete(id)
  }
}

export async function getProfileStr(id: string | undefined): Promise<string> {
  const safeId = id || 'default'
  assertSafeProfileId(safeId)
  if (existsSync(profilePath(safeId))) {
    return await readFile(profilePath(safeId), 'utf-8')
  } else {
    return stringify(defaultProfile)
  }
}

export async function setProfileStr(id: string, content: string): Promise<void> {
  assertSafeProfileId(id)
  const prior = profileContentWriteQueues.get(id) || Promise.resolve()
  const queued = prior
    .catch(() => {})
    .then(async () => {
      // 读取最新的配置
      const { current } = await getProfileConfig(true)
      const target = profilePath(id)
      const previous = await readFile(target, 'utf8').catch((error: NodeJS.ErrnoException) => {
        if (error.code === 'ENOENT') return null
        throw error
      })
      await writeFileAtomically(target, content)
      if (current === id) {
        try {
          await mihomoHotReloadConfig()
          profileLogger.info('Config reloaded successfully')
        } catch (error) {
          profileLogger.error('Failed to reload config', error)
          try {
            profileLogger.info('Falling back to restart core')
            await restartCore()
            profileLogger.info('Core restarted successfully')
          } catch (restartError) {
            profileLogger.error('Failed to restart core', restartError)
            // Keep the subscription and the running configuration in sync. A
            // rejected update must not destroy the last usable profile.
            if (previous !== null) {
              await writeFileAtomically(target, previous)
              try {
                await restartCore()
              } catch (rollbackError) {
                profileLogger.error('Failed to restart restored subscription', rollbackError)
              }
            } else {
              await rm(target, { force: true })
            }
            throw restartError
          }
        }
      }
    })
  profileContentWriteQueues.set(id, queued)
  try {
    await queued
  } finally {
    if (profileContentWriteQueues.get(id) === queued) profileContentWriteQueues.delete(id)
  }
}

export async function getProfile(id: string | undefined): Promise<IMihomoConfig> {
  const item = await getProfileItem(id)
  const profile = await decryptAgeContent(
    await getProfileStr(id),
    item?.ageSecretKey,
    `profile "${id || 'default'}"`
  )

  // 检测是否为 HTML 内容（订阅返回错误页面）
  const trimmed = profile.trim()
  if (
    trimmed.startsWith('<!DOCTYPE') ||
    trimmed.startsWith('<html') ||
    trimmed.startsWith('<HTML') ||
    /<style[^>]*>/i.test(trimmed.slice(0, 500))
  ) {
    throw new Error(
      `Profile "${id}" contains HTML instead of YAML. The subscription may have returned an error page. Please re-import or update the subscription.`
    )
  }

  try {
    let result = parse(profile)
    if (typeof result !== 'object') result = {}
    return result as IMihomoConfig
  } catch (e) {
    const msg = e instanceof Error ? e.message : String(e)
    throw new Error(`Failed to parse profile "${id}": ${msg}`)
  }
}

// attachment;filename=xxx.yaml; filename*=UTF-8''%xx%xx%xx
function parseFilename(str: string): string {
  if (str.match(/filename\*=.*''/)) {
    const parts = str.split(/filename\*=.*''/)
    if (parts[1]) {
      return decodeURIComponent(parts[1])
    }
  }
  const parts = str.split('filename=')
  if (parts[1]) {
    return parts[1].replace(/^["']|["']$/g, '')
  }
  return 'Remote File'
}

// subscription-userinfo: upload=1234; download=2234; total=1024000; expire=2218532293
function parseSubinfo(str: string): ISubscriptionUserInfo {
  const parts = str.split(/\s*;\s*/)
  const obj = {} as ISubscriptionUserInfo
  parts.forEach((part) => {
    const [key, value] = part.split('=')
    obj[key] = parseInt(value)
  })
  return obj
}

async function resolveRuntimeWorkspaceFile(filePath: string): Promise<string> {
  const { diffWorkDir = false } = await getAppConfig()
  const { current } = await getProfileConfig()
  const root = await realpath(diffWorkDir ? mihomoProfileWorkDir(current) : mihomoWorkDir())
  const candidate = await realpath(isAbsolute(filePath) ? filePath : join(root, filePath))
  const relativePath = relative(root, candidate)
  if (relativePath.startsWith('..') || isAbsolute(relativePath)) {
    throw new Error('Runtime resource path escapes the active profile workspace')
  }
  return candidate
}

export async function getFileStr(filePath: string): Promise<string> {
  return await readFile(await resolveRuntimeWorkspaceFile(filePath), 'utf-8')
}

export async function setFileStr(filePath: string, content: string): Promise<void> {
  await writeFile(await resolveRuntimeWorkspaceFile(filePath), content, 'utf-8')
}

export async function convertMrsRuleset(filePath: string, behavior: string): Promise<string> {
  // .mrs 是 mihomo 专有二进制格式，sing-box 内核无法转换预览
  void filePath
  void behavior
  throw new Error(
    'Previewing .mrs rulesets is not supported with the sing-box core (mihomo-only format)'
  )
}

// 插件 profile：内容已由 plugin 网关取得，这里只写内容 + 维护 profile item，不走远程 URL 下载
export async function upsertPluginProfile(
  meta: {
    profileId: string
    pluginId: string
    name: string
    interval?: number
    autoUpdate?: boolean
  },
  content: string
): Promise<void> {
  await setProfileStr(meta.profileId, content)
  let isNew = false
  await updateProfileConfig((config) => {
    const idx = config.items.findIndex((i) => i.id === meta.profileId)
    const item: IProfileItem = {
      id: meta.profileId,
      type: 'plugin',
      name: meta.name,
      pluginId: meta.pluginId,
      interval: meta.interval ?? 0,
      autoUpdate: meta.autoUpdate ?? false,
      updated: Date.now()
    }
    if (idx === -1) {
      isNew = true
      config.items.push(item)
    } else {
      config.items[idx] = { ...config.items[idx], ...item }
    }
    if (!config.current) config.current = meta.profileId
    return config
  })
  if (isNew) {
    const created = await getProfileItem(meta.profileId)
    if (created) await addProfileUpdater(created)
  }
}

export async function removePluginProfileContent(profileId: string): Promise<void> {
  await removeProfileItem(profileId)
}
