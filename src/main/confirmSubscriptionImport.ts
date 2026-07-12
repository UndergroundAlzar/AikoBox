import { dialog, type BrowserWindow, type MessageBoxOptions } from 'electron'

/** Native, non-web confirmation gate for OS protocol subscription imports. */
export async function confirmSubscriptionImport(
  hostname: string,
  parent: BrowserWindow | null
): Promise<boolean> {
  const options: MessageBoxOptions = {
    type: 'question',
    title: 'Confirm subscription',
    message: `Add a subscription from ${hostname}?`,
    detail: 'The secret URL parameters are hidden. Continue only if you trust this provider.',
    buttons: ['Cancel', 'Add'],
    defaultId: 0,
    cancelId: 0,
    noLink: true
  }
  const choice = parent
    ? await dialog.showMessageBox(parent, options)
    : await dialog.showMessageBox(options)
  return choice.response === 1
}
