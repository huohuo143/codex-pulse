const fs = require('node:fs');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const { safeRead, atomic } = require('./protected-record');

// Legacy radar archives can be much larger than editable records. Copy them in
// fixed-size chunks, retaining the same identity/change checks as safeRead.
function copyVerified(source, destination, io = fs) {
  const before = io.lstatSync(source);
  if (!before.isFile() || before.isSymbolicLink()) throw new Error('升级备份来源必须为普通文件');
  const input = io.openSync(source, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  let output, created = false;
  const same = (a, b) => a.isFile() && !a.isSymbolicLink() && a.dev === b.dev && a.ino === b.ino && a.size === b.size && a.mtimeMs === b.mtimeMs && a.ctimeMs === b.ctimeMs;
  const chunk = Buffer.alloc(64 * 1024), hash = createHash('sha256');
  try {
    const opened = io.fstatSync(input);
    if (!same(opened, before)) throw new Error('升级备份来源在读取期间发生变化');
    output = io.openSync(destination, 'wx', 0o600); created = true;
    let offset = 0;
    while (offset < opened.size) {
      const count = io.readSync(input, chunk, 0, Math.min(chunk.length, opened.size - offset), offset);
      if (!count) throw new Error('升级备份来源读取不完整');
      hash.update(chunk.subarray(0, count));
      let written = 0;
      while (written < count) {
        const size = io.writeSync(output, chunk, written, count - written, offset + written);
        if (!size) throw new Error('升级备份写入不完整');
        written += size;
      }
      offset += count;
    }
    io.fsyncSync(output);
    if (!same(io.fstatSync(input), opened) || !same(io.lstatSync(source), opened)) throw new Error('升级备份来源在读取期间发生变化');
    io.closeSync(output); output = undefined;
    const copied = io.openSync(destination, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
    const verify = createHash('sha256');
    try {
      const initial = io.fstatSync(copied);
      if (!initial.isFile() || initial.size !== opened.size) throw new Error('升级前数据备份校验失败');
      let offset = 0;
      while (offset < initial.size) {
        const count = io.readSync(copied, chunk, 0, Math.min(chunk.length, initial.size - offset), offset);
        if (!count) throw new Error('升级前数据备份校验失败');
        verify.update(chunk.subarray(0, count)); offset += count;
      }
      if (!same(io.fstatSync(copied), initial) || !same(io.lstatSync(destination), initial)) throw new Error('升级前数据备份校验失败');
    } finally { io.closeSync(copied); }
    const sha256 = hash.digest('hex');
    if (verify.digest('hex') !== sha256) throw new Error('升级前数据备份校验失败');
    return { sha256, bytes: opened.size };
  } catch (error) {
    if (output !== undefined) { io.closeSync(output); output = undefined; }
    if (created) { try { io.unlinkSync(destination); } catch {} }
    throw error;
  } finally { io.closeSync(input); }
}

function backupBeforeUpgrade(root, version, build) {
  const marker = path.join(root, 'app-version.json');
  const bytes = safeRead(marker, 65536);
  let previous = null;
  if (bytes) { try { previous = JSON.parse(bytes); } catch { throw new Error('版本记录损坏，升级前未改写设置'); } }
  if (previous?.version === version && previous?.build === build) return null;
  const selected = fs.existsSync(root) ? fs.readdirSync(root).filter(name => /^(?:settings|quota-history-[a-z0-9_-]+|alert-ledger-[a-z0-9_-]+|credit-expiry(?:-batches)?-v1|project-budgets-v1|radar-(?:source-v1|announcements-v2|evaluation-v1)|reset-calendar-v1|model-prices-v1|last-summary-day)\.json(?:\.last-good|\.damaged-[a-z0-9-]+\.json)?$/i.test(name)) : [];
  let directory = null;
  if (selected.length) {
    const parent = path.join(root, 'version-backups');
    try { const stat = fs.lstatSync(parent); if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('升级备份目录异常'); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    directory = path.join(parent, 'before-' + version + '-build' + build + '-' + Date.now() + '-' + randomUUID().slice(0, 8));
    fs.mkdirSync(directory, { recursive: true });
    const files = [];
    for (const name of selected) {
      files.push({ name, ...copyVerified(path.join(root, name), path.join(directory, name)) });
    }
    atomic(path.join(directory, 'manifest.json'), JSON.stringify({ schemaVersion: 1, previousVersion: previous?.version || 'unknown', nextVersion: version, build, createdAt: new Date().toISOString(), files }, null, 2));
  }
  atomic(marker, JSON.stringify({ version, build }));
  return directory;
}
module.exports = { backupBeforeUpgrade, copyVerified };
