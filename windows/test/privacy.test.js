const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const os = require('node:os');
const path = require('node:path');
const { CodexReader, cacheStateForDisk } = require('../src/core/codex-reader');
const { Runtime } = require('../src/core/runtime');
const { DEFAULTS } = require('../src/core/settings');
const { OneDriveSync } = require('../src/core/onedrive-sync');

test('statistics cache, backup, sync and diagnostics exclude complete and unfinished conversation text', async (t) => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'pulse-privacy-'));
  const sessions = path.join(root, 'sessions');
  await fs.mkdir(sessions);
  const secret = 'PRIVATE_CONVERSATION_凭据_sk-test-no-real-key';
  const message = JSON.stringify({ type: 'event_msg', payload: { type: 'user_message', message: secret } });
  const token = JSON.stringify({ timestamp: new Date().toISOString(), payload: { type: 'token_count', info: { total_token_usage: { total_tokens: 123 }, last_token_usage: { total_tokens: 123, input_tokens: 100, output_tokens: 23 } } } });
  const log = path.join(sessions, 'test.jsonl');
  await fs.writeFile(log, message + '\n' + token + '\n' + message);
  const support = path.join(root, 'support');
  const runtime = new Runtime(support, { ...DEFAULTS, notifications: false, dailyBackup: true }, { sessionRoots: [sessions] });
  runtime.sync = new OneDriveSync(path.join(root, 'onedrive'));
  t.after(async () => { runtime.stop(); await fs.rm(root, { recursive: true, force: true }); });
  await runtime.statistics();
  assert.equal(runtime.state.tokenStats.todayTokens, 123);
  runtime.maintenance();
  await fs.writeFile(path.join(support, 'diagnostics.json'), JSON.stringify(runtime.diagnostics()));
  async function inspect(directory) {
    for (const entry of await fs.readdir(directory, { withFileTypes: true })) {
      const file = path.join(directory, entry.name);
      if (entry.isDirectory()) await inspect(file);
      else assert.equal((await fs.readFile(file, 'utf8')).includes(secret), false, file);
    }
  }
  await inspect(support);
  await inspect(path.join(root, 'onedrive'));
  const cachePath = path.join(support, 'session-cache-v5.json');
  const cache = JSON.parse(await fs.readFile(cachePath, 'utf8'));
  assert.equal(cache.files[0][1].partial, '');
  await fs.appendFile(log, '\n' + token + '\n');
  const restarted = new CodexReader({ sessionRoots: [sessions], cachePath, liveReader: async () => [] });
  assert.equal((await restarted.read()).eventCount, 2);
});

test('migration cache redaction rewinds UTF-8 bytes without changing completed statistics', () => {
  const input = { offset: 200, partial: '未完成的对话', events: [{ token: 123 }], size: 200 };
  const saved = cacheStateForDisk(input);
  assert.equal(saved.offset, 200 - Buffer.byteLength(input.partial));
  assert.equal(saved.partial, '');
  assert.deepEqual(saved.events, input.events);
  assert.equal(input.partial, '未完成的对话');
});
