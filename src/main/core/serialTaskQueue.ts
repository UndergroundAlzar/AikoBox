/** A failure-tolerant FIFO queue for state-changing core operations. */
export class SerialTaskQueue {
  private tail: Promise<void> = Promise.resolve()
  private pendingCount = 0

  hasPending(): boolean {
    return this.pendingCount > 0
  }

  enqueue<T>(task: () => Promise<T>): Promise<T> {
    this.pendingCount++
    const operation = this.tail.then(task)
    const tracked = operation.finally(() => {
      this.pendingCount--
    })
    this.tail = tracked.then(
      () => undefined,
      () => undefined
    )
    return tracked
  }
}
