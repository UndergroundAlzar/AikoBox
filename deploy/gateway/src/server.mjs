// HTTP wiring. Caddy terminates TLS in front and reverse-proxies here over plain HTTP.
import http from 'node:http'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { loadConfig } from './config.mjs'
import { openDb } from './db.mjs'
import { createCodeStore } from './codes.mjs'
import { createNonceStore } from './nonces.mjs'
import { createRateLimiter } from './ratelimit.mjs'
import { fetchSubscription } from './origin.mjs'
import { readBody, parseForm, parseJson, clientIp, sendJson } from './http.mjs'
import { authorizeGet, authorizePost } from './auth.mjs'
import { enroll, challenge, config as configHandler, revoke } from './gateway.mjs'

const BODY_MAX = 64 * 1024
const ENDPOINTS = {
  enroll: '/enroll',
  challenge: '/challenge',
  config: '/config',
  revoke: '/revoke'
}

export function createHandler(deps) {
  return async (req, res) => {
    try {
      const url = new URL(req.url, 'http://gateway')
      const path = url.pathname
      const method = req.method

      if (method === 'GET' && path === '/.well-known/cpx-gateway') {
        return sendJson(res, 200, {
          spec: 'cpx-plugin/2',
          gateway: deps.config.publicOrigin,
          endpoints: ENDPOINTS
        })
      }

      if (path === '/oauth/authorize') {
        if (method === 'GET') return authorizeGet(Object.fromEntries(url.searchParams), res)
        if (method === 'POST') {
          const form = parseForm(await readBody(req, BODY_MAX))
          return authorizePost(form, clientIp(req, deps.config.trustedProxyCidrs), res, deps)
        }
      }

      if (method === 'POST' && Object.values(ENDPOINTS).includes(path)) {
        const body = parseJson(await readBody(req, BODY_MAX)) ?? {}
        if (path === ENDPOINTS.enroll) return enroll(body, res, deps)
        if (path === ENDPOINTS.challenge) return challenge(body, res, deps)
        if (path === ENDPOINTS.config) return configHandler(body, res, deps)
        if (path === ENDPOINTS.revoke) return revoke(body, res, deps)
      }

      sendJson(res, 404, { error: 'not_found' })
    } catch (e) {
      if (e?.message && /too large/.test(e.message))
        return sendJson(res, 413, { error: 'too_large' })
      sendJson(res, 500, { error: 'server_error' })
    }
  }
}

export function buildDeps(config) {
  const originCa = config.originCaFile ? readFileSync(config.originCaFile) : undefined
  return {
    db: openDb(config.dbPath),
    codes: createCodeStore({ ttlMs: config.codeTtlMs, maxSize: config.codePoolMax }),
    nonces: createNonceStore({ ttlMs: config.nonceTtlMs, poolMax: config.noncePoolMax }),
    loginIpLimiter: createRateLimiter({ max: config.loginMax, windowMs: config.loginWindowMs }),
    loginAccountLimiter: createRateLimiter({
      max: config.loginAccountMax,
      windowMs: config.loginAccountWindowMs
    }),
    fetchSubscription,
    config: { ...config, originCa }
  }
}

export function createServer(deps) {
  return http.createServer(createHandler(deps))
}

function main() {
  const config = loadConfig()
  const deps = buildDeps(config)
  createServer(deps).listen(config.port, '0.0.0.0', () => {
    console.log(`cpx-gateway listening on :${config.port} (public origin ${config.publicOrigin})`)
  })
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main()
