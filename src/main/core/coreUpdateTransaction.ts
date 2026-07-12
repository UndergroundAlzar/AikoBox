/**
 * Applies a core selection and proves it by restarting. If proof fails, the
 * inverse selection is applied and the prior core is restarted before the
 * original failure is returned to the caller.
 */
export async function runCoreUpdateTransaction<T>(options: {
  select: () => Promise<T>
  restoreSelection: () => Promise<unknown>
  restart: () => Promise<void>
  commitSelection?: () => Promise<void>
  onRecoveryRestartError?: (error: unknown) => void
}): Promise<T> {
  const selection = await options.select()
  try {
    await options.restart()
    await options.commitSelection?.()
    return selection
  } catch (startError) {
    try {
      await options.restoreSelection()
    } catch (selectionError) {
      throw new AggregateError(
        [startError, selectionError],
        'The new core failed and its selection could not be restored'
      )
    }
    try {
      await options.restart()
    } catch (recoveryError) {
      options.onRecoveryRestartError?.(recoveryError)
    }
    throw startError
  }
}
