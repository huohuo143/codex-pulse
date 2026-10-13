const test = require('node:test');
const assert = require('node:assert/strict');
const { Runtime } = require('../src/core/runtime');

test('idle polling waits 120 seconds and activity recovery immediately checks official data', () => {
  let clock = 1000000, visible = false, refreshes = 0;
  const runtime = Object.create(Runtime.prototype);
  Object.assign(runtime, {
    now: () => clock,
    isVisible: () => visible,
    settings: { refreshSeconds: 30 },
    state: { metrics: { lastActivityAt: clock - 300001 } },
    lastOfficialAt: clock,
    refresh() { refreshes++; this.lastOfficialAt = clock; },
    publish() {},
  });
  runtime.tick();
  clock += 119999;
  runtime.tick();
  assert.equal(refreshes, 0);
  clock++;
  runtime.tick();
  assert.equal(refreshes, 1);
  clock++;
  runtime.state.metrics.lastActivityAt = clock;
  runtime.tick();
  assert.equal(refreshes, 2, 'session activity resumes without waiting for the normal polling interval');
  runtime.tick();
  assert.equal(refreshes, 2);
  clock += 300001;
  runtime.tick();
  const before = refreshes;
  visible = true;
  clock++;
  runtime.tick();
  assert.equal(refreshes, before + 1, 'showing a window also wakes official polling');
});

test('quick official refresh does not invoke the log statistics worker', async () => {
  let scans = 0, reads = 0;
  const runtime = Object.create(Runtime.prototype);
  Object.assign(runtime, {
    now: () => 1000000,
    scope: null,
    official: { async read() { reads++; return { accountScope: null, sourceStates: { quota: 'unavailable' } }; } },
    exchange: { async current() { return null; } },
    state: {},
    statistics() { scans++; },
    publish() {},
    event() {},
  });
  await runtime.refresh();
  assert.equal(reads, 1);
  assert.equal(scans, 0);
  await runtime.refresh({ force: true });
  assert.equal(reads, 2);
  assert.equal(scans, 1, 'explicit full refresh is allowed to reconcile statistics');
});
