const fs = require("node:fs");
const path = require("node:path");
const { ProtectedRecord, validators } = require('./protected-record');
function readJSON(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}
function writeJSON(file, value) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const temp = file + ".tmp";
  fs.writeFileSync(temp, JSON.stringify(value, null, 2), { mode: 0o600 });
  fs.renameSync(temp, file);
}
class Store {
  constructor(root) {
    this.root = root;
    this.records = new Map();
  }
  file(name) {
    if (!/^[a-z0-9._-]+$/i.test(name)) throw new Error("无效存储名称");
    return path.join(this.root, name + ".json");
  }
  read(name, fallback) {
    const record = this.protected(name, fallback);
    if (record) return record.value;
    return readJSON(this.file(name), fallback);
  }
  write(name, value) {
    const record = this.protected(name, Array.isArray(value) ? [] : null);
    if (record) return record.write(value);
    writeJSON(this.file(name), value);
    return value;
  }
  protected(name, fallback = []) {
    const validate = name === 'project-budgets-v1' ? validators.budget : name === 'credit-expiry-batches-v1' ? validators.batches : name === 'credit-expiry-v1' ? validators.expiry : name.startsWith('quota-history-') ? validators.history : null;
    if (!validate) return null;
    if (!this.records.has(name)) this.records.set(name, new ProtectedRecord(this.file(name), validate, fallback));
    return this.records.get(name);
  }
}
module.exports = { Store, readJSON, writeJSON };
