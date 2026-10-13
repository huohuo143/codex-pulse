const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs/promises");
const path = require("node:path");
const os = require("node:os");
const { performance } = require("node:perf_hooks");
const { CodexReader } = require("../src/core/codex-reader");
for (const count of [100, 1000, 10000])
  test(
    "incremental reference comparison: " + count + " session files",
    async (t) => {
      const root = await fs.mkdtemp(path.join(os.tmpdir(), "pulse-perf-"));
      const sessions = path.join(root, "sessions");
      await fs.mkdir(sessions);
      const now = new Date(),
        timestamp = now.toISOString();
      const token = (i, total = i + 1) =>
        JSON.stringify({
          timestamp,
          payload: {
            type: "token_count",
            info: {
              total_token_usage: { total_tokens: total },
              last_token_usage: {
                total_tokens: total,
                input_tokens: total,
                output_tokens: 0,
                cached_input_tokens: 0,
              },
            },
          },
        }) + "\n";
      let reader;
      t.after(async () => {
        reader?.close();
        await fs.rm(root, { recursive: true, force: true });
      });
      for (let start = 0; start < count; start += 100) {
        await Promise.all(
          Array.from({ length: Math.min(100, count - start) }, (_, n) => {
            const i = start + n;
            return fs.writeFile(path.join(sessions, i + ".jsonl"), token(i));
          }),
        );
      }
      reader = new CodexReader({
        sessionRoots: [sessions],
        cachePath: path.join(root, "cache.json"),
        liveReader: async () => [],
      });
      const start = performance.now(),
        cold = await reader.read(now),
        coldMs = performance.now() - start;
      assert.equal(cold.scannedFiles, count);
      assert.equal(cold.tokenStats.monthTokens, (count * (count + 1)) / 2);
      assert.equal(cold.eventCount, count);
      assert.equal(cold.metrics.parseCount, count);
      const warmStart = performance.now(),
        warm = await reader.read(now),
        warmMs = performance.now() - warmStart;
      assert.equal(warm.metrics.parseCount, count);
      assert.equal(warm.metrics.analysisCount, 1);
      await fs.appendFile(path.join(sessions, "0.jsonl"), token(0, 100));
      const appended = await reader.read(now);
      assert.equal(
        appended.tokenStats.monthTokens,
        (count * (count + 1)) / 2 + 100,
      );
      assert.equal(appended.metrics.parseCount, count + 1);
      await fs.writeFile(path.join(sessions, "1.jsonl"), token(1, 5));
      await fs.unlink(path.join(sessions, "2.jsonl"));
      const changed = await reader.read(now);
      assert.equal(
        changed.tokenStats.monthTokens,
        (count * (count + 1)) / 2 + 100 + 5 - 2 - 3,
      );
      const result = {
        count,
        coldMs,
        warmMs,
        parseCount: changed.metrics.parseCount,
        analysisCount: changed.metrics.analysisCount,
        referenceMatched: true,
        memory: process.memoryUsage(),
      };
      console.log(JSON.stringify(result));
      if (process.env.PULSE_TEST_REPORT_DIR) {
        await fs.mkdir(process.env.PULSE_TEST_REPORT_DIR, { recursive: true });
        await fs.writeFile(
          path.join(
            process.env.PULSE_TEST_REPORT_DIR,
            "performance-" + count + ".json",
          ),
          JSON.stringify(result, null, 2),
        );
      }
    },
  );
