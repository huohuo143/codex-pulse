const fs = require("node:fs");
const path = require("node:path");
const { createHash, randomUUID } = require("node:crypto");
const { safeRead } = require('./protected-record');

const MANIFEST = "backup-manifest-v1.json";
const digest = data => createHash("sha256").update(data).digest("hex");
const dayKey = date => date.toLocaleDateString("sv-SE");
const safeName = name => typeof name === "string" && /^[a-z0-9._-]+$/i.test(name) && name !== MANIFEST;

// Only caller-selected application records are archived. Session logs and
// authentication files must never be supplied as sources.
class BackupArchive {
  constructor(root, { io = fs } = {}) {
    this.root = path.join(root, "backups");
    this.io = io;
  }
  directory(now) { return path.join(this.root, dayKey(now)); }
  read(file) { return safeRead(file, 16 * 1024 * 1024, this.io); }
  safeDirectory(directory) {
    for (const target of [this.root, directory]) {
      try { const stat = this.io.lstatSync(target); if (!stat.isDirectory() || stat.isSymbolicLink()) throw new Error('备份目录必须为普通目录'); }
      catch (e) { if (e.code !== 'ENOENT') throw e; }
    }
  }
  manifest(directory, strict = false) {
    try {
      this.safeDirectory(directory);
      const bytes = this.read(path.join(directory, MANIFEST));
      if (!bytes) return null;
      const value = JSON.parse(bytes.toString('utf8'));
      if (value?.schemaVersion !== 1 || !value.files || typeof value.files !== 'object' || Array.isArray(value.files) || !Object.entries(value.files).every(([key, hash]) => safeName(key) && /^[a-f0-9]{64}$/.test(hash))) throw new Error('备份清单损坏或来自不支持的版本');
      return value;
    } catch (e) { if (strict) throw e; return null; }
  }
  sourceNames(sourceFiles) {
    const names = new Set();
    for (const source of sourceFiles) {
      if (!this.read(source)) continue;
      const name = path.basename(source);
      if (!safeName(name) || names.has(name)) throw new Error("备份来源文件名重复或无效");
      names.add(name);
    }
    return names;
  }
  hasBackup(now, sourceFiles) {
    const directory = this.directory(now), manifest = this.manifest(directory);
    if (!manifest) return false;
    let names;
    try { names = sourceFiles ? this.sourceNames(sourceFiles) : new Set(Object.keys(manifest.files)); }
    catch { return false; }
    if (!names.size) return false;
    return [...names].every(name => {
      if (!safeName(name) || !/^[a-f0-9]{64}$/.test(manifest.files[name] || "")) return false;
      try { const data = this.read(path.join(directory, name)); return !!data && digest(data) === manifest.files[name]; }
      catch { return false; }
    });
  }
  writeAtomic(file, data) {
    const temporary = `${file}.${randomUUID()}.tmp`;
    try {
      this.io.writeFileSync(temporary, data, { mode: 0o600 });
      this.io.renameSync(temporary, file);
    } finally {
      try { this.io.unlinkSync(temporary); } catch {}
    }
  }
  backup(sourceFiles, now = new Date(), retentionDays = 7) {
    this.sourceNames(sourceFiles);
    const sources = new Map();
    // Read everything before replacing any archive file. A failed or empty
    // attempt never creates a completion receipt.
    for (const source of sourceFiles) {
      const data = this.read(source); if (data) sources.set(path.basename(source), data);
    }
    const directory = this.directory(now);
    if (!sources.size) return { directory, itemCount: 0 };
    this.safeDirectory(directory);
    const previous = this.manifest(directory, true);
    const priorManifest = this.read(path.join(directory, MANIFEST));
    const destinations = new Map([...sources.keys()].map(name => [name, this.read(path.join(directory, name))]));
    this.io.mkdirSync(directory, { recursive: true });
    const manifest = { schemaVersion: 1, files: { ...(previous?.files || {}) } };
    for (const [name, data] of sources) {
      const file = path.join(directory, name), expected = digest(data);
      const latest = this.read(file), prior = destinations.get(name);
      if ((latest ? digest(latest) : null) !== (prior ? digest(prior) : null)) throw new Error('归档文件被外部修改');
      this.writeAtomic(file, data);
      if (digest(this.read(file)) !== expected) throw new Error("备份完整性校验失败");
      manifest.files[name] = expected;
    }
    const currentManifest = this.read(path.join(directory, MANIFEST));
    if ((currentManifest ? digest(currentManifest) : null) !== (priorManifest ? digest(priorManifest) : null)) throw new Error('备份清单被外部修改');
    this.writeAtomic(path.join(directory, MANIFEST), JSON.stringify(manifest, null, 2));
    if (!this.hasBackup(now, sourceFiles)) throw new Error("备份完成清单校验失败");
    this.prune(now, retentionDays);
    return { directory, itemCount: sources.size };
  }
  prune(now, retentionDays) {
    const cutoff = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    cutoff.setDate(cutoff.getDate() - Math.max(1, retentionDays));
    const oldest = dayKey(cutoff);
    for (const entry of this.io.readdirSync(this.root, { withFileTypes: true })) {
      if (!entry.isDirectory() || !/^\d{4}-\d{2}-\d{2}$/.test(entry.name) || entry.name >= oldest) continue;
      const directory = path.join(this.root, entry.name);
      // Legacy daily JSON files and unrelated directories are preserved.
      if (this.manifest(directory)) this.io.rmSync(directory, { recursive: true });
    }
  }
}

module.exports = { BackupArchive, dayKey, MANIFEST };
