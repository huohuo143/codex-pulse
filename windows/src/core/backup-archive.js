const fs = require("node:fs");
const path = require("node:path");
const { createHash, randomUUID } = require("node:crypto");

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
  manifest(directory) {
    try {
      const value = JSON.parse(this.io.readFileSync(path.join(directory, MANIFEST), "utf8"));
      return value?.schemaVersion === 1 && value.files && typeof value.files === "object" && !Array.isArray(value.files)
        ? value : null;
    } catch { return null; }
  }
  sourceNames(sourceFiles) {
    const names = new Set();
    for (const source of sourceFiles) {
      if (!this.io.existsSync(source)) continue;
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
      try { return digest(this.io.readFileSync(path.join(directory, name))) === manifest.files[name]; }
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
    for (const source of sourceFiles)
      if (this.io.existsSync(source)) sources.set(path.basename(source), this.io.readFileSync(source));
    const directory = this.directory(now);
    if (!sources.size) return { directory, itemCount: 0 };
    this.io.mkdirSync(directory, { recursive: true });
    const previous = this.manifest(directory);
    const manifest = { schemaVersion: 1, files: { ...(previous?.files || {}) } };
    for (const [name, data] of sources) {
      const file = path.join(directory, name), expected = digest(data);
      this.writeAtomic(file, data);
      if (digest(this.io.readFileSync(file)) !== expected) throw new Error("备份完整性校验失败");
      manifest.files[name] = expected;
    }
    this.prune(now, retentionDays);
    this.writeAtomic(path.join(directory, MANIFEST), JSON.stringify(manifest, null, 2));
    if (!this.hasBackup(now, sourceFiles)) throw new Error("备份完成清单校验失败");
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
