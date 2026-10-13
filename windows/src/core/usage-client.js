const { Worker } = require("node:worker_threads");
const path = require("node:path");
class UsageClient {
  constructor(options = {}) {
    this.options = options;
    this.worker = null;
    this.sequence = 0;
    this.pending = null;
    this.last = null;
    this.failures = 0;
  }
  spawn() {
    this.worker = new Worker(path.join(__dirname, "usage-worker.js"), {
      workerData: this.options,
    });
    this.worker.on("message", (m) => {
      if (m.id !== this.pending?.id) return;
      const p = this.pending;
      this.pending = null;
      clearTimeout(p.timer);
      if (m.error) p.reject(new Error(m.error));
      else {
        this.last = m.status;
        this.failures = 0;
        p.resolve(m.status);
      }
    });
    this.worker.on("error", () => this.fail());
    this.worker.on("exit", () => {
      if (this.worker) this.fail();
    });
  }
  fail() {
    const w = this.worker;
    this.worker = null;
    w?.removeAllListeners();
    w?.terminate();
    this.failures++;
    if (this.pending) {
      clearTimeout(this.pending.timer);
      this.pending.reject(new Error("统计进程中断，下次刷新重试"));
      this.pending = null;
    }
  }
  read(options = {}) {
    if (this.pending) return this.pending.promise;
    if (!this.worker) this.spawn();
    const id = ++this.sequence;
    let resolve, reject;
    const promise = new Promise((a, b) => {
      resolve = a;
      reject = b;
    });
    this.pending = {
      id,
      promise,
      resolve,
      reject,
      timer: setTimeout(() => this.fail(), 300000),
    };
    this.worker.postMessage({ id, ...options });
    return promise;
  }
  close() {
    this.fail();
  }
}
module.exports = { UsageClient };
