export class ExclusiveRunner {
  private tails = new Map<string, Promise<void>>();

  async run<T>(
    key: string,
    task: () => T | Promise<T>,
    signal?: AbortSignal,
  ): Promise<T> {
    const previous = this.tails.get(key) ?? Promise.resolve();
    let unlock!: () => void;
    const current = new Promise<void>((resolve) => {
      unlock = resolve;
    });
    const tail = previous.then(() => current);
    this.tails.set(key, tail);
    await previous;
    try {
      signal?.throwIfAborted();
      return await task();
    } finally {
      unlock();
      if (this.tails.get(key) === tail) this.tails.delete(key);
    }
  }
}
