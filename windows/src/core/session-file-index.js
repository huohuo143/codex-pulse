const fs = require("node:fs/promises");
const path = require("node:path");

const within = (parent, child) => {
  const relative = path.relative(parent, child);
  return relative === "" || (!relative.startsWith(".." + path.sep) && relative !== ".." && !path.isAbsolute(relative));
};

class SessionFileIndex {
  constructor(roots, { maxFiles = Infinity, io = fs } = {}) {
    this.roots = [...new Set(roots.map(root => path.resolve(root)))];
    this.maxFiles = maxFiles;
    this.io = io;
    this.entries = new Map();
    this.directories = new Set();
    this.pending = new Set();
    this.needsFull = true;
    this.metrics = { fullScans: 0, subtreeScans: 0, statChecks: 0 };
  }
  markDirty(root, filename) {
    if (!filename) { this.needsFull = true; return; }
    const base = path.resolve(root), target = path.resolve(base, String(filename));
    if (!this.roots.includes(base) || !within(base, target)) { this.needsFull = true; return; }
    this.pending.add(target);
    if (this.pending.size > 10000) { this.pending.clear(); this.needsFull = true; }
  }
  async stat(file) { this.metrics.statChecks++; return this.io.lstat(file); }
  record(file, stat, entries = this.entries) {
    entries.set(file, { path: file, mtimeMs: stat.mtimeMs, size: stat.size, identity: String(stat.ino) + ":" + stat.birthtimeMs });
  }
  async scan(directory, entries, directories) {
    let children;
    try { children = await this.io.readdir(directory, { withFileTypes: true }); }
    catch (error) {
      if (!["ENOENT", "ENOTDIR"].includes(error.code)) {
        this.needsFull = true;
        for (const [file, value] of this.entries) if (within(directory, file)) entries.set(file, value);
        for (const item of this.directories) if (within(directory, item)) directories.add(item);
      }
      return;
    }
    directories.add(directory);
    for (const child of children) {
      const file = path.join(directory, child.name);
      if (child.isDirectory()) await this.scan(file, entries, directories);
      else if (child.isFile() && child.name.toLowerCase().endsWith(".jsonl")) {
        try {
          const stat = await this.stat(file);
          if (stat.isFile()) this.record(file, stat, entries);
        } catch (error) {
          if (!["ENOENT", "ENOTDIR"].includes(error.code)) {
            this.needsFull = true;
            const previous = this.entries.get(file);
            if (previous) entries.set(file, previous);
          }
        }
      }
    }
  }
  removeSubtree(directory) {
    for (const file of this.entries.keys()) if (within(directory, file)) this.entries.delete(file);
    for (const item of this.directories) if (within(directory, item)) this.directories.delete(item);
  }
  async refresh(force = false) {
    const pending = [...this.pending];
    this.pending.clear();
    if (force || this.needsFull) {
      this.needsFull = false;
      this.metrics.fullScans++;
      const entries = new Map(), directories = new Set();
      for (const root of this.roots) await this.scan(root, entries, directories);
      this.entries = entries;
      this.directories = directories;
      return true;
    }
    if (!pending.length) return false;
    const scanned = [];
    for (const file of pending.sort((a, b) => a.length - b.length)) {
      if (scanned.some(parent => within(parent, file))) continue;
      let stat;
      try { stat = await this.stat(file); }
      catch (error) {
        if (["ENOENT", "ENOTDIR"].includes(error.code)) {
          // A known file deletion is an O(1) map update; only directory events
          // inspect descendants across the index.
          if (this.directories.has(file)) this.removeSubtree(file);
          else this.entries.delete(file);
        } else this.needsFull = true;
        continue;
      }
      if (stat.isDirectory()) {
        this.metrics.subtreeScans++;
        const entries = new Map(), directories = new Set();
        await this.scan(file, entries, directories);
        this.removeSubtree(file);
        for (const [name, value] of entries) this.entries.set(name, value);
        for (const name of directories) this.directories.add(name);
        scanned.push(file);
      } else if (stat.isFile() && file.toLowerCase().endsWith(".jsonl")) {
        if (this.directories.has(file)) this.removeSubtree(file);
        this.record(file, stat);
      } else if (this.directories.has(file)) this.removeSubtree(file);
      else this.entries.delete(file);
    }
    return true;
  }
  files() {
    return [...this.entries.values()].sort((a, b) => b.mtimeMs - a.mtimeMs || a.path.localeCompare(b.path)).slice(0, this.maxFiles);
  }
}

module.exports = { SessionFileIndex };
