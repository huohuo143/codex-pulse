const fs = require("node:fs");
const path = require("node:path");
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
  }
  file(name) {
    if (!/^[a-z0-9._-]+$/i.test(name)) throw new Error("无效存储名称");
    return path.join(this.root, name + ".json");
  }
  read(name, fallback) {
    return readJSON(this.file(name), fallback);
  }
  write(name, value) {
    writeJSON(this.file(name), value);
    return value;
  }
}
module.exports = { Store, readJSON, writeJSON };
