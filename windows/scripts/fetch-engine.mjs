// Native engine only; pinned package, SHA-512 verification, no global install.
import { mkdirSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { gunzipSync } from 'node:zlib';
import { resolve } from 'node:path';
const version='1.18.35';
const sri='sha512-L4gD+osKK5YRY1ZDdH87dzvG5MAUpXci4CgBrJ5+GCxJnrBa+7sJqpgSHZPQBNRRPuT0nPqM3uasfFPEzkLSmQ==';
const response=await fetch(`https://registry.npmjs.org/opencode-windows-x64-baseline/-/opencode-windows-x64-baseline-${version}.tgz`);
if(!response.ok) throw new Error('Engine download failed');
const bytes=Buffer.from(await response.arrayBuffer());
if('sha512-'+createHash('sha512').update(bytes).digest('base64')!==sri) throw new Error('Engine integrity mismatch');
const tar=gunzipSync(bytes); const out=resolve('engine'); mkdirSync(out,{recursive:true});let found=false;
for(let at=0;at+512<=tar.length;){
 const name=tar.subarray(at,at+100).toString().split('\0')[0];if(!name)break;
 const size=parseInt(tar.subarray(at+124,at+136).toString().replace(/\0/g,'').trim()||'0',8);
 if(!Number.isFinite(size)||size<0||at+512+size>tar.length)throw new Error('Malformed engine archive');
 if(name==='package/bin/opencode.exe'){writeFileSync(resolve(out,'opencode.exe'),tar.subarray(at+512,at+512+size));found=true;}
 at+=512+Math.ceil(size/512)*512;
}
if(!found)throw new Error('Native engine executable missing');
const license=await fetch(`https://raw.githubusercontent.com/anomalyco/opencode/v${version}/LICENSE`);
if(!license.ok)throw new Error('Engine license download failed');
writeFileSync(resolve(out,'LICENSE.txt'),await license.text());
writeFileSync(resolve(out,'VERSION'),version+'\n');
console.log(`Verified OpenCode ${version}; ${bytes.length} compressed bytes`);
