// Small HTTP helpers: bounded body read, body parsing, client IP, and response writers.
// TLS is terminated by Caddy in front, so the gateway speaks plain HTTP internally.
import { isIP } from 'node:net'

export async function readBody(req, maxBytes) {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > maxBytes) throw new Error('request body too large')
    chunks.push(chunk)
  }
  return Buffer.concat(chunks).toString('utf-8')
}

export function parseForm(body) {
  return Object.fromEntries(new URLSearchParams(body))
}

// Parse a JSON object body; returns undefined for invalid JSON or non-objects.
export function parseJson(body) {
  try {
    const v = JSON.parse(body)
    return typeof v === 'object' && v !== null && !Array.isArray(v) ? v : undefined
  } catch {
    return undefined
  }
}

function canonicalIp(value) {
  let ip = String(value ?? '').trim()
  const zone = ip.indexOf('%')
  if (zone !== -1) ip = ip.slice(0, zone)
  const mapped = /^::ffff:(\d{1,3}(?:\.\d{1,3}){3})$/i.exec(ip)
  if (mapped && isIP(mapped[1]) === 4) return mapped[1]
  return isIP(ip) ? ip.toLowerCase() : undefined
}

function ipNumber(ip) {
  if (isIP(ip) === 4) {
    return ip.split('.').reduce((n, part) => (n << 8n) | BigInt(part), 0n)
  }

  if (ip.includes('.')) {
    const lastColon = ip.lastIndexOf(':')
    const octets = ip
      .slice(lastColon + 1)
      .split('.')
      .map(Number)
    const tail = `${(octets[0] * 256 + octets[1]).toString(16)}:${(
      octets[2] * 256 +
      octets[3]
    ).toString(16)}`
    ip = ip.slice(0, lastColon + 1) + tail
  }

  let [left, right] = ip.split('::')
  const leftParts = left ? left.split(':') : []
  const rightParts = right ? right.split(':') : []
  const missing = 8 - leftParts.length - rightParts.length
  const parts = [...leftParts, ...Array(Math.max(0, missing)).fill('0'), ...rightParts]
  return parts.reduce((n, part) => (n << 16n) | BigInt(`0x${part || '0'}`), 0n)
}

function inCidr(ip, cidr) {
  const [networkText, prefixText] = String(cidr).trim().split('/')
  const network = canonicalIp(networkText)
  if (!network) return false
  const version = isIP(ip)
  if (isIP(network) !== version) return false
  const bits = version === 4 ? 32 : 128
  const prefix = prefixText === undefined ? bits : Number(prefixText)
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > bits) return false
  const shift = BigInt(bits - prefix)
  return ipNumber(ip) >> shift === ipNumber(network) >> shift
}

// Forwarded headers are accepted only from an explicitly trusted proxy source.
// The reference Caddy deployment overwrites X-Forwarded-For with one client address.
export function clientIp(req, trustedProxyCidrs = []) {
  const socketIp = canonicalIp(req.socket?.remoteAddress)
  if (!socketIp) return 'unknown'

  const cidrs = Array.isArray(trustedProxyCidrs)
    ? trustedProxyCidrs
    : String(trustedProxyCidrs).split(',')
  const trusted = cidrs.some((cidr) => inCidr(socketIp, cidr))
  if (!trusted) return socketIp

  const forwarded = String(req.headers?.['x-forwarded-for'] ?? '')
    .split(',')[0]
    .trim()
  return canonicalIp(forwarded) ?? socketIp
}

export function sendJson(res, status, obj) {
  const body = JSON.stringify(obj)
  res.writeHead(status, { 'content-type': 'application/json; charset=utf-8' }).end(body)
}

export function sendText(res, status, body, contentType = 'text/plain; charset=utf-8') {
  res.writeHead(status, { 'content-type': contentType }).end(body)
}

export function sendHtml(res, status, html) {
  res.writeHead(status, { 'content-type': 'text/html; charset=utf-8' }).end(html)
}

export function redirect(res, location) {
  res.writeHead(302, { location }).end()
}
