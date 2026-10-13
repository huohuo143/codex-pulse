const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const assert = require('node:assert/strict');
const source = path.resolve(__dirname, '..');
const stage = path.resolve(process.argv[2]);
const target = path.join(source, 'dist');
const evidence = path.join(target, 'validation-2.11.0');
const previousManifestPath = path.join(evidence, 'release-manifest.json');
const previousArtifacts = fs.existsSync(previousManifestPath) ? JSON.parse(fs.readFileSync(previousManifestPath, 'utf8')).artifacts || [] : [];
const hash = data => crypto.createHash('sha256').update(data).digest('hex');
function files(root, prefix = '') { return fs.readdirSync(path.join(root, prefix), {withFileTypes:true}).flatMap(e => e.isDirectory() ? files(root, path.join(prefix, e.name)) : [path.join(prefix, e.name)]).sort(); }
const asarPackage = fs.readdirSync(path.join(stage, 'node_modules/.pnpm')).find(n => n.startsWith('@electron+asar@'));
const asar = require(path.join(stage, 'node_modules/.pnpm', asarPackage, 'node_modules/@electron/asar'));
const archive = path.join(stage, 'dist/win-unpacked/resources/app.asar');
const sourceFiles = files(path.join(source, 'src')).map(file => {
  const relative = file.replaceAll('\\', '/');
  const expected = hash(fs.readFileSync(path.join(source, 'src', file)));
  assert.equal(hash(fs.readFileSync(path.join(stage, 'src', file))), expected, 'staged source mismatch: ' + relative);
  assert.equal(hash(asar.extractFile(archive, path.join('src', file))), expected, 'packaged source mismatch: ' + relative);
  return {path: relative, sha256: expected};
});
fs.mkdirSync(evidence, {recursive:true});
const artifacts = fs.readdirSync(path.join(stage, 'dist')).filter(f => f.endsWith('.exe')).map(file => {
  const data = fs.readFileSync(path.join(stage, 'dist', file));
  const sha256 = hash(data);
  const destination = path.join(target, file);
  if (fs.existsSync(destination)) {
    const old = hash(fs.readFileSync(destination));
    const previous = ['803b8320c4ac5ba35bff3fe9e98b7d3f1e55c880ad966735efa2ac3af41164bd', 'c4f232d5f53ed657ffd47597cf1ecda53ba7a99bcd8353fb786f0f4db3fd9b42'];
    assert.ok(old === sha256 || previous.includes(old) || previousArtifacts.some(a => a.file === file && a.sha256 === old), 'unexpected pre-existing delivery: ' + file);
  }
  fs.writeFileSync(destination, data);
  assert.equal(hash(fs.readFileSync(destination)), sha256);
  return {file, bytes:data.length, sha256};
});
fs.writeFileSync(path.join(target, 'SHA256SUMS-2.11.0.txt'), artifacts.map(a => a.sha256 + '  ' + a.file).join('\n') + '\n');
const manifest = {version:'2.11.0', build:2118, createdAt:new Date().toISOString(), asarSha256:hash(fs.readFileSync(archive)), source:sourceFiles, artifacts};
fs.writeFileSync(path.join(stage, 'test-results/release-manifest.json'), JSON.stringify(manifest, null, 2));
for (const file of ['final-tests.txt','build.txt','performance-100.json','performance-1000.json','performance-10000.json','installer-report.json','release-manifest.json']) fs.copyFileSync(path.join(stage, 'test-results', file), path.join(evidence, file));
for (const dir of ['ui-validation-scale-1','ui-validation-scale-1.25','ui-validation-scale-1.5','ui-validation-scale-1.75','ui-validation-scale-2','lifecycle-validation','portable-validation','network-validation']) {
  const from = path.join(stage, dir), to = path.join(evidence, dir);
  fs.mkdirSync(to, {recursive:true});
  for (const file of fs.readdirSync(from).filter(f => f === 'report.json' || f.endsWith('.png'))) fs.copyFileSync(path.join(from, file), path.join(to, file));
}
for (const file of ['UPGRADE_2.11.0.md', 'VALIDATION_2.11.0.md', 'v2.11.0-feature-parity.md']) fs.copyFileSync(path.join(source, 'docs', file), path.join(target, file));
console.log(JSON.stringify({artifacts, evidence, packagedFilesVerified:sourceFiles.length}));
