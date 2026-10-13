const fs = require("node:fs"), path = require("node:path"), crypto = require("node:crypto"), assert = require("node:assert/strict");
const source = path.resolve(__dirname, ".."), stage = path.resolve(process.argv[2]);
const version = JSON.parse(fs.readFileSync(path.join(source, "package.json"))).version;
const gaugeFix = process.argv.includes("--gauge-fix");
const output = path.join(source, "dist"), evidence = path.join(output, "validation-" + version);
const hash = data => crypto.createHash("sha256").update(data).digest("hex");
function files(root) { return fs.readdirSync(root, { withFileTypes: true }).flatMap(e => e.isDirectory() ? files(path.join(root, e.name)) : [path.join(root, e.name)]).sort(); }
const asarPackage = fs.readdirSync(path.join(stage, "node_modules/.pnpm")).find(n => n.startsWith("@electron+asar@"));
const asar = require(path.join(stage, "node_modules/.pnpm", asarPackage, "node_modules/@electron/asar"));
const archive = path.join(stage, "dist/win-unpacked/resources/app.asar");
assert.equal(JSON.parse(asar.extractFile(archive, "package.json")).version, version);
const sourceFiles = files(path.join(source, "src")).map(file => {
  const relative = path.relative(source, file).replaceAll("\\", "/"), expected = hash(fs.readFileSync(file));
  assert.equal(hash(fs.readFileSync(path.join(stage, relative))), expected, "staged file mismatch: " + relative);
  assert.equal(hash(asar.extractFile(archive, relative.split("/").join(path.sep))), expected, "packaged file mismatch: " + relative);
  return { path: relative, sha256: expected };
});
fs.mkdirSync(evidence, { recursive: true });
const artifacts = fs.readdirSync(path.join(stage, "dist")).filter(f => f.endsWith(".exe") && f.includes(version)).map(file => {
  const data = fs.readFileSync(path.join(stage, "dist", file)), digest = hash(data), destination = path.join(output, file);
  if (fs.existsSync(destination)) assert.equal(hash(fs.readFileSync(destination)), digest, "unexpected existing artifact: " + file);
  else fs.writeFileSync(destination, data);
  assert.equal(hash(fs.readFileSync(destination)), digest); return { file, bytes: data.length, sha256: digest };
});
assert.equal(artifacts.length, 2);
fs.writeFileSync(path.join(output, "SHA256SUMS-" + version + ".txt"), artifacts.map(a => a.sha256 + "  " + a.file).join("\n") + "\n");
const manifest = { version, createdAt: new Date().toISOString(), asarSha256: hash(fs.readFileSync(archive)), source: sourceFiles, artifacts };
fs.writeFileSync(path.join(evidence, "release-manifest.json"), JSON.stringify(manifest, null, 2));
for (const name of ["tests-final.txt", "build-final.txt", "ui-tests-final.txt", ...(gaugeFix ? ["gauge-tests-1.txt", "gauge-tests-1.75.txt", "gauge-tests-2.txt"] : ["parity-tests-final.txt"]), "installed-validation.json", "installer-validation.json"])
  if (fs.existsSync(path.join(stage, name))) fs.copyFileSync(path.join(stage, name), path.join(evidence, name));
for (const dir of gaugeFix ? ["ui-validation-scale-1", "gauge-validation-scale-1", "gauge-validation-scale-1.75", "gauge-validation-scale-2"] : ["ui-validation", "ui-validation-scale-1", "ui-validation-scale-2", "parity-validation", "lifecycle-validation", "portable-validation", "network-validation"])
  if (fs.existsSync(path.join(stage, dir))) {
    const target = path.join(evidence, dir); fs.mkdirSync(target, { recursive: true });
    for (const name of fs.readdirSync(path.join(stage, dir)).filter(n => n.endsWith(".png") || n === "report.json" || n === "official-history.csv"))
      fs.copyFileSync(path.join(stage, dir, name), path.join(target, name));
  }
for (const name of ["UPGRADE_" + version + ".md", "VALIDATION_" + version + ".md", "v" + version + "-feature-parity.md"])
  fs.copyFileSync(path.join(source, "docs", name), path.join(output, name));
console.log(JSON.stringify({ version, packagedFilesVerified: sourceFiles.length, artifacts, evidence }));
