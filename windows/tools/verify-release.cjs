const fs = require('node:fs'), path = require('node:path'), crypto = require('node:crypto'), assert = require('node:assert/strict');
const stage = path.resolve(process.argv[2] || path.join(__dirname, '..'));
const source = path.resolve(process.argv[3] || stage), output = path.resolve(process.argv[4] || path.join(source, 'dist'));
const asar = require(require.resolve('@electron/asar', { paths: [stage] }));
const archive = path.join(stage, 'dist/win-unpacked/resources/app.asar');
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
function files(root) { return fs.readdirSync(root, { withFileTypes: true }).flatMap(e => e.isDirectory() ? files(path.join(root, e.name)) : [path.join(root, e.name)]).sort(); }
const pkg = JSON.parse(asar.extractFile(archive, 'package.json'));
assert.equal(pkg.version, '2.12.29');
const entries = [...files(path.join(source, 'src')), ...files(path.join(source, 'assets'))].map(file => {
  const relative = path.relative(source, file), expected = digest(fs.readFileSync(file));
  assert.equal(digest(fs.readFileSync(path.join(stage, relative))), expected, 'staged source differs: ' + relative);
  assert.equal(digest(asar.extractFile(archive, relative)), expected, 'packaged source differs: ' + relative);
  return { path: relative.replaceAll('\\', '/'), sha256: expected };
});
const expectedFiles = ['Installer', 'Portable'].map(kind => `Codex-Pulse-Windows-2.12.29-build2157-x64-${kind}.exe`);
fs.mkdirSync(output, { recursive: true });
const artifacts = expectedFiles.map(name => {
  const file = path.join(stage, 'dist', name), bytes = fs.readFileSync(file), sha256 = digest(bytes);
  assert.ok(bytes.length > 1000000); assert.equal(bytes.subarray(0, 2).toString(), 'MZ');
  const destination = path.join(output, name);
  if (path.resolve(file) !== path.resolve(destination)) {
    if (fs.existsSync(destination)) assert.equal(digest(fs.readFileSync(destination)), sha256, 'existing delivery differs');
    else fs.copyFileSync(file, destination);
  }
  assert.equal(digest(fs.readFileSync(destination)), sha256);
  return { name, bytes: bytes.length, sha256 };
});
const manifest = { version: '2.12.29', build: 2157, platform: 'win32', arch: 'x64', createdAt: new Date().toISOString(), asarSha256: digest(fs.readFileSync(archive)), files: entries, artifacts };
fs.writeFileSync(path.join(output, 'SOURCE-ASAR-MANIFEST-2.12.29-build2157.json'), JSON.stringify(manifest, null, 2));
fs.writeFileSync(path.join(output, 'SHA256SUMS-2.12.29.txt'), artifacts.map(a => a.sha256 + '  ' + a.name).join('\r\n') + '\r\n');
console.log(JSON.stringify({ matchedFiles: entries.length, version: manifest.version, build: manifest.build, artifacts }));
