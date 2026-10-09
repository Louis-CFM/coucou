import {test} from 'node:test';import assert from 'node:assert/strict';import {readFile,mkdtemp,rm} from 'node:fs/promises';import os from 'node:os';import path from 'node:path';
test('protected runtime paths cannot be edited through ordinary tools, patches or recycling',async()=>{
 const base=await mkdtemp(path.join(os.tmpdir(),'nova-plugin-test-'));const old=process.env.APPDATA,local=process.env.LOCALAPPDATA;process.env.APPDATA=base;process.env.LOCALAPPDATA=base;
 try{let source=await readFile(new URL('../engine-plugin/nova.mjs',import.meta.url),'utf8');source=source.replace("import { tool } from '@opencode-ai/plugin';", "const tool=Object.assign(def=>def,{schema:{string:()=>({describe(){return this}})}});");const factory=(await import('data:text/javascript;base64,'+Buffer.from(source).toString('base64'))).default;const plugin=await factory();
 const protectedFile=path.join(base,'Nova','credentials.json');for(const name of ['read','write','edit'])await assert.rejects(()=>plugin['tool.execute.before']({tool:name},{args:{filePath:protectedFile}}),/protected/);
 for(const action of ['Add','Update'])await assert.rejects(()=>plugin['tool.execute.before']({tool:'apply_patch'},{args:{patchText:`*** Begin Patch\n*** ${action} File: ${protectedFile}\n+unsafe\n*** End Patch`}}),/protected/);
 await assert.rejects(()=>plugin.tool.nova_recycle.execute({filePath:protectedFile},{}),/protected/);
 await assert.rejects(()=>plugin['tool.execute.before']({tool:'apply_patch'},{args:{patchText:'*** Begin Patch\n*** Delete File: safe.txt\n*** End Patch'}}),/permanent patch deletion/);
 const out={args:{command:"[IO.File]::WriteAllText('x','y')"}};await plugin['tool.execute.before']({tool:'bash'},out);assert.match(out.args.command,/-NonInteractive -WindowStyle Hidden -Command/);assert.match(out.args.command,/WriteAllText/);
 }finally{if(old===undefined)delete process.env.APPDATA;else process.env.APPDATA=old;if(local===undefined)delete process.env.LOCALAPPDATA;else process.env.LOCALAPPDATA=local;await rm(base,{recursive:true,force:true});}
});
