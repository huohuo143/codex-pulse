const fs = require('node:fs');
const path = require('node:path');
const { createHash, randomUUID } = require('node:crypto');
const MAX_BYTES = 8 * 1024 * 1024;
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
function safeRead(file, limit = MAX_BYTES, io = fs) {
  let stat;
  try { stat = io.lstatSync(file); } catch (e) { if (e.code === 'ENOENT') return null; throw e; }
  if (!stat.isFile() || stat.isSymbolicLink() || stat.size > limit) throw new Error('记录必须为大小受限的普通文件；请检查文件和备份');
  const fd = io.openSync(file, fs.constants.O_RDONLY | (fs.constants.O_NOFOLLOW || 0));
  try {
    const actual = io.fstatSync(fd);
    if (!actual.isFile() || actual.size > limit || actual.ino !== stat.ino || actual.dev !== stat.dev) throw new Error('文件在读取期间发生变化');
    const data = Buffer.alloc(actual.size);
    let offset = 0;
    while (offset < data.length) { const count = io.readSync(fd, data, offset, data.length - offset, offset); if (!count) throw new Error('记录读取不完整'); offset += count; }
    const after = io.fstatSync(fd), current = io.lstatSync(file);
    if (after.size !== actual.size || after.mtimeMs !== actual.mtimeMs || current.isSymbolicLink() || current.ino !== actual.ino || current.size !== actual.size || current.mtimeMs !== actual.mtimeMs) throw new Error('文件在读取期间发生变化');
    return data;
  } finally { io.closeSync(fd); }
}
function atomic(file, bytes) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = file + '.' + randomUUID() + '.tmp';
  try { fs.writeFileSync(temp, bytes, { flag: 'wx', mode: 0o600 }); fs.renameSync(temp, file); }
  finally { try { fs.unlinkSync(temp); } catch {} }
}
class ProtectedRecord {
  constructor(file, validate, fallback) {
    Object.assign(this, { file, validate, fallback });
    this.backup = file + '.last-good'; this.value = fallback; this.expected = undefined; this.error = null; this.pendingFailure = null;
    this.reload();
  }
  decode(bytes) {
    const value = JSON.parse(bytes.toString('utf8'));
    if (value && !Array.isArray(value) && (value.schemaVersion != null || value.version != null)) throw new Error('记录来自不支持的版本，已停止写入');
    if (!this.validate(value)) throw new Error('记录格式无效，已保留原件并停止写入');
    return value;
  }
  reload() {
    try {
      const bytes = safeRead(this.file), backup = safeRead(this.backup);
      if (!bytes && backup) throw new Error('主记录缺失，请显式恢复上次有效记录');
      const value = bytes ? this.decode(bytes) : this.fallback;
      this.value = value; this.expected = bytes ? digest(bytes) : null;
      if (backup) this.decode(backup);
      this.error = null;
    } catch (e) { this.error = e.message; }
    return this.value;
  }
  checkExpected() {
    const bytes = safeRead(this.file);
    if ((bytes ? digest(bytes) : null) !== this.expected) throw new Error('记录已被外部修改，请重新读取；当前输入已保留');
    return bytes;
  }
  write(value) {
    if (this.error) throw new Error(this.error);
    if (!this.validate(value)) throw new Error('记录格式无效');
    const bytes = Buffer.from(JSON.stringify(value, null, 2));
    if (bytes.length > MAX_BYTES) throw new Error('记录超过 8 MB，请缩短说明或来源');
    try {
      const old = this.checkExpected(), backup = safeRead(this.backup);
      if (backup) this.decode(backup);
      if (old) { atomic(this.backup, old); if (digest(safeRead(this.backup)) !== digest(old)) throw new Error('上次有效记录备份校验失败'); }
      this.checkExpected();
      atomic(this.file, bytes);
      if (digest(safeRead(this.file)) !== digest(bytes)) throw new Error('保存后校验失败');
      this.expected = digest(bytes); this.value = value; this.pendingFailure = null;
    } catch (e) { this.pendingFailure = e.message; throw e; }
    return value;
  }
  restore() {
    const bytes = safeRead(this.backup);
    if (!bytes) throw new Error('没有上次有效记录可恢复');
    const value = this.decode(bytes), original = safeRead(this.file);
    if (original) {
      try { this.decode(original); throw new Error('主记录有效，请重新读取'); }
      catch (e) { if (/主记录有效|不支持的版本/.test(e.message)) throw e; }
      const damaged = this.file + '.damaged-' + Date.now() + '-' + randomUUID() + '.json';
      fs.writeFileSync(damaged, original, { flag: 'wx', mode: 0o600 });
      if (digest(safeRead(damaged)) !== digest(original)) throw new Error('损坏原件备份失败');
    }
    const latest = safeRead(this.file), latestBackup = safeRead(this.backup);
    if ((latest ? digest(latest) : null) !== (original ? digest(original) : null) || !latestBackup || digest(latestBackup) !== digest(bytes)) throw new Error('文件在恢复期间发生变化');
    atomic(this.file, bytes); this.pendingFailure = null; this.error = null; this.reload();
    return value;
  }
  health() {
    try {
      this.checkExpected();
      const backup = safeRead(this.backup); if (backup) this.decode(backup);
      return { state: this.error || this.pendingFailure ? 'warning' : this.expected === null ? 'unknown' : 'healthy', message: this.error || this.pendingFailure || (this.expected === null ? '尚未建立记录' : '记录和备份已检查') };
    } catch (e) { return { state: 'warning', message: e.message }; }
  }
}
const arrayOf = validate => value => Array.isArray(value) && value.every(validate) && new Set(value.map(r => r.id)).size === value.length;
const validators = {
  budget: arrayOf(r => r && typeof r.id === 'string' && typeof r.projectName === 'string' && typeof r.projectPath === 'string' && Number.isSafeInteger(r.monthlyTokenLimit) && r.monthlyTokenLimit > 0),
  batches: arrayOf(r => r && typeof r.id === 'string' && typeof r.accountScope === 'string' && Number.isFinite(r.credits) && r.credits > 0 && require('./credit-expiry').validDate(r.grantedOn) && require('./credit-expiry').validDate(r.expiresOn) && r.expiresOn >= r.grantedOn && ['confirmed', 'estimated'].includes(r.kind) && typeof r.evidence === 'string' && r.evidence.length <= 1000),
  history: value => Array.isArray(value) && value.every(r => r && Number.isFinite(Date.parse(r.recordedAt)) && Number.isFinite(Date.parse(r.resetsAt)) && Number.isFinite(r.remainingPercent) && r.remainingPercent >= 0 && r.remainingPercent <= 100 && Number.isFinite(r.windowMinutes)),
  expiry: value => value === null || (value && require('./credit-expiry').validDate(value.date) && typeof value.evidence === 'string' && value.evidence.length <= 1000 && typeof value.confirmed === 'boolean'),
};
module.exports = { ProtectedRecord, safeRead, atomic, validators, MAX_BYTES };
