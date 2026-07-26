export interface IpcErrorEnvelope {
  invokeError: unknown
  // 稳定的机器可读错误码，渲染进程据此分支，不要再去匹配 message 子串
  invokeErrorCode?: string
}

export function toIpcErrorEnvelope(e: unknown): IpcErrorEnvelope {
  if (e && typeof e === 'object' && 'message' in e) {
    const code = (e as { code?: unknown }).code
    return typeof code === 'string' && code
      ? { invokeError: e.message, invokeErrorCode: code }
      : { invokeError: e.message }
  }
  return { invokeError: typeof e === 'string' ? e : 'Unknown Error' }
}
