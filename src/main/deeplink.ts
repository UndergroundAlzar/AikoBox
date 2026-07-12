import { Notification } from 'electron'
import i18next from 'i18next'
import { addProfileItem } from './config'
import { mainWindow } from './window'
import { safeShowErrorBox } from './utils/init'
import { confirmSubscriptionImport } from './confirmSubscriptionImport'

export async function handleDeepLink(url: string): Promise<void> {
  if (
    !url.startsWith('clash://') &&
    !url.startsWith('mihomo://') &&
    !url.startsWith('aikobox://')
  ) {
    return
  }

  const urlObj = new URL(url)
  switch (urlObj.host) {
    case 'install-config': {
      try {
        const profileUrl = urlObj.searchParams.get('url')
        const profileName = urlObj.searchParams.get('name')
        if (!profileUrl) {
          throw new Error(i18next.t('profiles.error.urlParamMissing'))
        }
        const remote = new URL(profileUrl)
        const hostname = remote.hostname.toLowerCase()
        const privateIpv4 =
          /^(?:127\.|10\.|192\.168\.|169\.254\.|172\.(?:1[6-9]|2\d|3[01])\.)/.test(hostname)
        if (
          remote.protocol !== 'https:' ||
          remote.username ||
          remote.password ||
          hostname === 'localhost' ||
          hostname === '::1' ||
          hostname.endsWith('.localhost') ||
          privateIpv4
        ) {
          throw new Error('Deep-link subscriptions must use a public HTTPS URL')
        }

        if (!(await confirmSubscriptionImport(remote.hostname, mainWindow))) return
        await addProfileItem({
          type: 'remote',
          name: profileName?.slice(0, 120) || undefined,
          url: remote.toString()
        })
        mainWindow?.webContents.send('profileConfigUpdated')
        new Notification({ title: i18next.t('profiles.notification.importSuccess') }).show()
      } catch (e) {
        // Never display the original deep link: subscription tokens commonly
        // live in its query string and error dialogs may be captured in logs.
        safeShowErrorBox('profiles.error.importFailed', `${e}`)
      }
      break
    }
  }
}
