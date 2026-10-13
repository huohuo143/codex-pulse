const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");
const { EventEmitter } = require("node:events");
const { PassThrough, Writable } = require("node:stream");

function clientWithReply(payload) {
  let killed = false;
  const module = { exports: {} };
  const spawn = () => {
    const child = new EventEmitter();
    child.stdout = new PassThrough();
    child.kill = () => {
      killed = true;
      child.stdout.end();
    };
    child.stdin = new Writable({
      write(chunk, encoding, done) {
        const request = JSON.parse(chunk.toString());
        if (request.id)
          setImmediate(() =>
            child.stdout.write(
              JSON.stringify({
                id: request.id,
                result: request.id === 1 ? {} : payload,
              }) + "\n",
            ),
          );
        done();
      },
    });
    return child;
  };
  vm.runInNewContext(
    fs.readFileSync(require.resolve("../src/core/codex-app-server"), "utf8"),
    {
      module,
      process,
      setTimeout,
      clearTimeout,
      require: (name) =>
        name === "node:child_process" ? { spawn } : require(name),
    },
  );
  return { fetch: module.exports.fetchLiveRateLimits, killed: () => killed };
}
const payload = {
  rateLimits: {
    limitId: "codex",
    primary: {
      usedPercent: 23,
      windowDurationMins: 300,
      resetsAt: 1800000000,
    },
  },
};

test("live reader returns raw payload when raw is requested", async () => {
  const client = clientWithReply(payload);
  const result = await client.fetch({ raw: true });
  assert.equal(JSON.stringify(result), JSON.stringify(payload));
  assert.equal(client.killed(), true);
});

test("live reader converts default and explicit false responses to quota events", async () => {
  for (const options of [{}, { raw: false }]) {
    const client = clientWithReply(payload);
    const events = await client.fetch(options);
    assert.equal(events.length, 1);
    assert.equal(events[0].limitID, "codex");
    assert.equal(events[0].primary.remainingPercent, 77);
    assert.equal(events[0].sourceName, "Codex app-server");
    assert.equal(client.killed(), true);
  }
});
