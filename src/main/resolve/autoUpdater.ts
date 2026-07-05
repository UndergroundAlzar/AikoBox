import i18next from 'i18next'

/**
 * AikoBox 不使用应用内自动更新：
 * 远程检查始终静默返回“无可用更新”，更新随完整安装包发布。
 * UI（检查更新按钮/更新弹窗）保留，checkUpdate 永远不会抛出网络错误。
 */
export async function checkUpdate(): Promise<IAppVersion | undefined> {
  return undefined
}

export async function downloadAndInstallUpdate(_version: string): Promise<void> {
  // checkUpdate 恒为无更新，此入口正常情况下不可达；保留以维持 IPC 接口兼容。
  throw new Error(i18next.t('common.error.autoUpdateNotSupported'))
}
