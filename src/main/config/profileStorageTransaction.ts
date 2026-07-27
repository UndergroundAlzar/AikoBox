let profileStorageTransactionQueue: Promise<void> = Promise.resolve()

/**
 * Serializes every mutation of profile metadata/content with backup restore.
 * Keep the queue settled so one failed operation cannot block later writes.
 */
export async function runProfileStorageTransaction<T>(operation: () => Promise<T>): Promise<T> {
  const run = profileStorageTransactionQueue.catch(() => {}).then(operation)
  profileStorageTransactionQueue = run.then(
    () => undefined,
    () => undefined
  )
  return run
}
