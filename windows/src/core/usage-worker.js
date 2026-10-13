const { parentPort, workerData } = require("node:worker_threads");
const { CodexReader } = require("./codex-reader");
const { setPriceTable } = require("./model-pricing");
const reader = new CodexReader({
  ...workerData,
  watch: true,
  liveReader: async () => [],
});
parentPort.on("message", async ({ id, prices, force }) => {
  try {
    if (prices) setPriceTable(prices);
    if (force) reader.invalidate();
    const status = await reader.read();
    parentPort.postMessage({ id, status });
  } catch {
    parentPort.postMessage({ id, error: "会话统计失败，请重试" });
  }
});
