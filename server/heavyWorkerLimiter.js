import os from 'node:os';

const defaultConcurrency = () => {
  const configured = Number(process.env.HEAVY_WORKER_MAX_ACTIVE);
  if (Number.isFinite(configured) && configured >= 1) {
    return Math.min(4, Math.floor(configured));
  }
  return os.totalmem() < 4.5 * 1024 * 1024 * 1024 ? 1 : 2;
};

export class HeavyWorkerLimiter {
  constructor({ maxActive = defaultConcurrency() } = {}) {
    this.maxActive = Math.max(1, maxActive);
    this.active = 0;
    this.highPriority = [];
    this.normalPriority = [];
  }

  run(task, { priority = 'normal' } = {}) {
    return new Promise((resolve, reject) => {
      const entry = { task, resolve, reject };
      if (priority === 'high') this.highPriority.push(entry);
      else this.normalPriority.push(entry);
      this.#drain();
    });
  }

  #drain() {
    while (this.active < this.maxActive) {
      const next = this.highPriority.shift() ?? this.normalPriority.shift();
      if (!next) break;
      this.active += 1;
      Promise.resolve()
        .then(() => next.task())
        .then(next.resolve, next.reject)
        .finally(() => {
          this.active -= 1;
          this.#drain();
        });
    }
  }
}

export const heavyWorkerLimiter = new HeavyWorkerLimiter();
