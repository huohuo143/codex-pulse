const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const { Store } = require('../src/core/storage');
const { RadarService } = require('../src/core/radar-v2110');
const { UpdateService } = require('../src/core/update-service');
(async () => {
  const root = path.resolve(process.argv[2]);
  const output = path.join(root, 'network-validation');
  const service = new RadarService({ store: new Store(path.join(output, 'isolated-state')) });
  const successful = await service.current({ force: true });
  assert.equal(successful?.sourceState, 'fresh', 'real public source fetch must succeed');
  const previous = successful.lastSuccessAt;
  const fetcher = service.fetcher;
  service.fetcher = async () => { throw new Error('isolated simulated connection failure'); };
  const failed = await service.current({ force: true });
  assert.equal(failed.sourceState, 'cached');
  assert.equal(failed.lastSuccessAt, previous);
  assert.ok(failed.nextSyncAt > Date.now() + 55000);
  service.fetcher = fetcher;
  const recovered = await service.current({ force: true });
  assert.equal(recovered.sourceState, 'fresh');
  assert.equal(recovered.error, null);
  const updates = await new UpdateService(new Store(path.join(output, 'isolated-update-state'))).check(true);
  const report = {
    completedAt: new Date().toISOString(),
    initial: { state: successful.sourceState, successAt: new Date(previous).toISOString() },
    injectedFailure: { state: failed.sourceState, preservesSuccessTimestamp: true, backoffSeconds: Math.round((failed.nextSyncAt - failed.lastAttemptAt) / 1000) },
    recovered: { state: recovered.sourceState, successAt: new Date(recovered.lastSuccessAt).toISOString() },
    updates: { version: updates.version, available: updates.available, message: updates.message },
    limitation: 'Network failure is deliberately injected into an isolated fetcher; host networking was never disabled.'
  };
  fs.writeFileSync(path.join(output, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report));
})().catch(error => { console.error(error); process.exitCode = 1; });
