import { describe, expect, it } from 'vitest'
import { isRetiredDefaultPanelUrl, resolveWebUIPanelUrl } from './webui-panel'

const vars = { host: '127.0.0.1', port: '9090', secret: 's3cr3t' }

describe('webui panel url resolution', () => {
  it('replaces every occurrence, not just the first', () => {
    const resolved = resolveWebUIPanelUrl(
      'http://%host:%port/ui/#/setup?hostname=%host&port=%port',
      vars
    )
    expect(resolved.url).toBe('http://127.0.0.1:9090/ui/#/setup?hostname=127.0.0.1&port=9090')
  })

  it('flags a secret placed in the query string', () => {
    const resolved = resolveWebUIPanelUrl(
      'https://yacd.metacubex.one/?hostname=%host&port=%port&secret=%secret',
      vars
    )
    expect(resolved.secretInQuery).toBe(true)
    expect(resolved.carriesSecret).toBe(true)
    expect(resolved.isExternal).toBe(true)
    expect(resolved.hostname).toBe('yacd.metacubex.one')
  })

  it('does not treat a secret in the fragment as a query secret', () => {
    const resolved = resolveWebUIPanelUrl(
      'https://metacubex.github.io/metacubexd/#/setup?http=true&secret=%secret',
      vars
    )
    expect(resolved.secretInQuery).toBe(false)
    expect(resolved.carriesSecret).toBe(true)
    expect(resolved.isExternal).toBe(true)
  })

  it('treats loopback panels as local', () => {
    for (const template of [
      'http://%host:%port/ui/#/setup?secret=%secret',
      'http://localhost:9090/ui/#secret=%secret',
      'http://[::1]:9090/ui/#secret=%secret'
    ]) {
      expect(resolveWebUIPanelUrl(template, vars).isExternal).toBe(false)
    }
  })

  it('reports no secret when the core has none configured', () => {
    const resolved = resolveWebUIPanelUrl('https://example.com/?secret=%secret', {
      ...vars,
      secret: ''
    })
    expect(resolved.carriesSecret).toBe(false)
    expect(resolved.secretInQuery).toBe(false)
  })

  it('flags a secret in the path or the userinfo, not only the query', () => {
    // both reach the remote server verbatim: one in the request line, one in an
    // Authorization: Basic header
    expect(resolveWebUIPanelUrl('https://evil.example/%secret', vars).secretInQuery).toBe(true)
    expect(resolveWebUIPanelUrl('https://%secret@evil.example/', vars).secretInQuery).toBe(true)
  })

  it('treats an unparseable template as external', () => {
    expect(resolveWebUIPanelUrl('not a url %secret', vars).isExternal).toBe(true)
  })
})

describe('retired default panel migration', () => {
  it('matches the three retired remote dashboards', () => {
    for (const url of [
      'https://metacubex.github.io/metacubexd/#/setup?http=true&hostname=%host&port=%port&secret=%secret',
      'https://yacd.metacubex.one/?hostname=%host&port=%port&secret=%secret',
      'https://board.zash.run.place/#/setup?http=true&hostname=%host&port=%port&secret=%secret'
    ]) {
      expect(isRetiredDefaultPanelUrl(url)).toBe(true)
    }
  })

  it('keeps a panel the user repointed at their own dashboard', () => {
    // the entry can still carry id "metacubexd" — deleting by id would destroy it
    expect(isRetiredDefaultPanelUrl('http://127.0.0.1:9090/ui/#/setup?secret=%secret')).toBe(false)
    expect(isRetiredDefaultPanelUrl('https://dash.example.com/#/setup')).toBe(false)
  })

  it('keeps anything it cannot parse rather than deleting it', () => {
    expect(isRetiredDefaultPanelUrl('not a url')).toBe(false)
    expect(isRetiredDefaultPanelUrl(undefined)).toBe(false)
    expect(isRetiredDefaultPanelUrl(null)).toBe(false)
  })
})
