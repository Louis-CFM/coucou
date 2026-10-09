// Minimal adapters on OpenCode's existing plugin/tool/permission interfaces.
// No model loop, permission protocol, or generic executor is implemented here.
import { tool } from '@opencode-ai/plugin';
import { spawn } from 'node:child_process';
import { realpath,readFile,readdir,stat } from 'node:fs/promises';
import path from 'node:path';

const secretNames=['NOVA_PROVIDER_API_KEY','OPENCODE_SERVER_PASSWORD',...Object.keys(process.env).filter(n=>n.startsWith('NOVA_MCP_TOKEN_'))];
const ps=path.join(process.env.SystemRoot||'C:\\Windows','System32','WindowsPowerShell','v1.0','powershell.exe');
const quote=s=>"'"+s.replaceAll("'","''")+"'";
const protectedRoots=[path.join(process.env.APPDATA||'', 'Nova'),path.join(process.env.LOCALAPPDATA||'', 'Nova'),path.dirname(path.dirname(process.execPath))].map(p=>path.resolve(p).toLowerCase());
async function canonical(raw){let target=path.resolve(raw);let ancestor=target;while(true){try{const resolved=await realpath(ancestor);target=path.join(resolved,path.relative(ancestor,target));break;}catch{const parent=path.dirname(ancestor);if(parent===ancestor)break;ancestor=parent;}}return target.toLowerCase();}
let physicalRoots;
async function protect(raw){if(typeof raw!=='string')return;const normalized=await canonical(raw);const roots=await(physicalRoots??=Promise.all(protectedRoots.map(canonical)));if(roots.some(p=>normalized===p||normalized.startsWith(p+path.sep)))throw new Error('Nova credentials/runtime/install files are protected; use nova_history_search for approved chat recall');}
const prefix=`& ${quote(ps)} -NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command `;

export default async ()=>({
 'shell.env':async(_input,output)=>{
  // An empty override removes these credentials from ordinary tool children.
  for(const name of secretNames) output.env[name]='';
 },
 'tool.execute.before':async(input,output)=>{
  if(['read','write','edit','glob','grep','list','apply_patch'].includes(input.tool)){for(const key of ['filePath','filepath','path'])await protect(output.args[key]);}

  if(input.tool==='bash'||input.tool==='powershell'||input.tool==='shell'){
   const original=String(output.args.command||'');
   if(!original.trim()||original.length>32000)throw new Error('Empty or oversized command blocked');
   // Member expressions may otherwise produce no shell permission pattern.
   // A real executable invocation forces the CLI's own ctx.ask gate.
   output.args.command=prefix+quote('& { '+original+' }');
  }
  if(input.tool==='apply_patch'){for(const match of String(output.args.patchText||'').matchAll(/^\*\*\* (?:(?:Add|Update|Delete) File|Move to):\s*(.+)$/gm))await protect(match[1].trim());}
  if(input.tool==='apply_patch'&&/^\*\*\* Delete File:/mi.test(String(output.args.patchText||'')))
   throw new Error('Use nova_recycle to delete files safely; permanent patch deletion is disabled');
 },
 tool:{
  nova_history_search:tool({description:'Search locally saved Nova conversations for previous context. Requires user approval; returns bounded excerpts, not unlimited memory.',args:{query:tool.schema.string().describe('Words to look for; empty returns recent conversations')},async execute({query},context){await context.ask({permission:'nova_history',patterns:[query||'recent chats'],always:[],metadata:{query,localHistory:true}});const folder=path.join(process.env.LOCALAPPDATA,'Nova','history');const names=await readdir(folder).catch(()=>[]);const rows=[];for(const name of names.filter(n=>/^ses_[a-z0-9_]+\.json$/i.test(n))){const p=path.join(folder,name);const info=await stat(p).catch(()=>null);if(info&&info.size<32*1024*1024)rows.push({p,time:info.mtimeMs});}rows.sort((a,b)=>b.time-a.time);const result=[];for(const row of rows){try{const v=JSON.parse(await readFile(row.p,'utf8'));const text=v.messages.flatMap(m=>m.parts.filter(p=>p.type==='text').map(p=>m.info.role+': '+p.text)).join('\n');const terms=query.toLowerCase().split(/\s+/).filter(Boolean);if(!terms.length||terms.some(q=>text.toLowerCase().includes(q))){result.push({title:v.title,updated:v.updated,excerpt:text.slice(-8000)});if(result.length>=3)break;}}catch{}}return JSON.stringify(result);}}),
  nova_recycle:tool({
   description:'Move a file or directory to the Windows Recycle Bin after fresh user permission. Never permanently delete.',
   args:{filePath:tool.schema.string().describe('Absolute existing path to recycle')},
   async execute({filePath},context){
    await protect(filePath);
    const target=await realpath(filePath);
    if(path.parse(target).root.toLowerCase()===target.toLowerCase())throw new Error('Drive roots cannot be recycled');
    await context.ask({permission:'nova_recycle',patterns:[target],always:[],metadata:{filepath:target,recycle:true}});
    const script=`Add-Type -AssemblyName Microsoft.VisualBasic; $p=${quote(target)}; if(Test-Path -LiteralPath $p -PathType Container){[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p,'OnlyErrorDialogs','SendToRecycleBin','ThrowException')}else{[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p,'OnlyErrorDialogs','SendToRecycleBin','ThrowException')}`;
    await new Promise((resolve,reject)=>{
     const p=spawn(ps,['-NoLogo','-NoProfile','-NonInteractive','-WindowStyle','Hidden','-Command',script],{windowsHide:true,stdio:['ignore','ignore','ignore'],env:{...process.env,...Object.fromEntries(secretNames.map(n=>[n,'']))}});
     const abort=()=>{p.kill();reject(new Error('Recycle operation cancelled'));};context.abort.addEventListener('abort',abort,{once:true});
     const timer=setTimeout(()=>{p.kill();reject(new Error('Recycle operation timed out'));},30000);
     p.on('error',()=>{clearTimeout(timer);reject(new Error('Recycle operation could not start'));});
     p.on('exit',code=>{context.abort.removeEventListener('abort',abort);clearTimeout(timer);code===0?resolve():reject(new Error('Windows could not move this path to the Recycle Bin'));});
    });
    return 'Moved to the Recycle Bin: '+target;
   },
  }),
 },
});
