// Applies the reviewed Phase 1 source snapshot before the existing Tauri build.
// No credentials, network operations, package installation or git pushes.
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { dirname, resolve, sep } from 'node:path';
import { gunzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';
const root = process.cwd();
const encoded = readFileSync('.nova/phase1.snapshot.b64', 'utf8').trim();
const packed = Buffer.from(encoded, 'base64');
const hash = createHash('sha256').update(packed).digest('hex');
const expected = readFileSync('.nova/snapshot.sha256', 'utf8').trim();
if (hash !== expected) throw new Error('Snapshot integrity check failed');
const m = JSON.parse(gunzipSync(packed));
const current = createHash('sha256').update(readFileSync('windows/package.json')).digest('hex');
if (current !== m.basePackageSHA256) throw new Error('Unexpected upstream version: refusing to overwrite');
function safe(path) {
  if (path.split('/').some(p => !p || p === '..' || p === '.git')) throw new Error('Unsafe snapshot path');
  const target = resolve(root, path);
  if (!target.startsWith(root + sep)) throw new Error('Path escapes repository');
  return target;
}
for (const path of m.remove) rmSync(safe(path), {force:true});
for (const f of m.files) {
  const path = safe(f.path);
  mkdirSync(dirname(path), {recursive:true});
  writeFileSync(path, f.encoding === 'base64' ? Buffer.from(f.content, 'base64') : f.content);
}
// Empty removed directories are pruned; no build uses these platform/assets trees.
for (const path of ['NotchBuddy','linux','relay','design','docs','scripts','tests','windows/screenshots','windows/dev'])
  rmSync(safe(path), {recursive:true, force:true});
console.log(`Materialized Nova Phase 1: ${m.files.length} replacement files, ${m.remove.length} retired files`);
