// UI adapter over OpenCode's existing session/events/permissions, not an agent loop.
import { invoke } from '@tauri-apps/api/core';
import { onEvent, IS_TAURI } from './bridge';
export interface EngineProfile { id:string;label:string;baseUrl:string;modelId:string;protocol:'openai-compatible'|'openai-responses'|'anthropic'|'google';noAuth:boolean;params:Record<string,unknown>;inputUsdPerMillion:number|null;outputUsdPerMillion:number|null;cachedInputUsdPerMillion:number|null }
export interface EngineConfig { profiles:EngineProfile[];activeProfile:string;workspace:string;lastSession:string|null }
export interface EngineStatus {online:boolean;busy:boolean;profileId:string;workspace:string;mode:'normal'|'strict';sessionId:string|null;restartCount:number;error:string|null;version:string}
export interface EnginePermission {id:string;sessionID:string;permission:string;patterns:string[];metadata:Record<string,unknown>}
export interface EngineMessage {info:{id:string;role:'user'|'assistant';parentID?:string;tokens?:{input:number;output:number;reasoning:number;cache:{read:number;write:number}};cost?:number;error?:unknown};parts:EnginePart[]}
export interface EnginePart {id:string;messageID:string;sessionID:string;type:string;text?:string;tool?:string;state?:{status:string;input:Record<string,unknown>;output?:string;error?:string;metadata?:Record<string,unknown>}}
export interface EngineQuestion {id:string;questions:{header:string;question:string;options:{label:string;description:string}[];multiple?:boolean}[]}
export interface HistoryEntry {id:string;title:string;workspace:string;updated:number;messages?:EngineMessage[]}
export interface Attachment {name:string;path:string;size:number}
export const EngineBridge={
 pickFiles:()=>invoke<Attachment[]>('engine_pick_files'),
 history:(query:string)=>invoke<HistoryEntry[]>('engine_history_list',{query}),
 readHistory:(id:string)=>invoke<HistoryEntry>('engine_history_read',{id}),
 resume:(id:string)=>invoke<HistoryEntry>('engine_resume',{id}),
 importProvider:()=>invoke<EngineConfig>('engine_import_provider'),
 config:()=>invoke<EngineConfig>('engine_config'),
 status:()=>invoke<EngineStatus>('engine_status'),
 saveProfile:(profile:EngineProfile,key:string|null)=>invoke<EngineConfig>('engine_profile_save',{profile,key}),
 removeProfile:(id:string)=>invoke<EngineConfig>('engine_profile_remove',{id}),
 keyPresent:(id:string)=>invoke<boolean>('engine_profile_key_present',{id}),
 preferences:(workspace:string,activeProfile:string)=>invoke<EngineConfig>('engine_preferences',{workspace,activeProfile}),
 start:(profileId:string,workspace:string,mode:'strict'|'normal')=>invoke<EngineStatus>('engine_start',{profileId,workspace,mode}),
 stop:()=>invoke<EngineStatus>('engine_stop'),
 send:(query:string,attachments:string[]=[])=>invoke<unknown>('engine_send',{query,attachments}),
 reply:(requestId:string,allow:boolean,permanentConfirmed=false)=>invoke<void>('engine_reply',{requestId,allow,permanentConfirmed}),
 snapshot:()=>invoke<{messages:EngineMessage[];permissions:EnginePermission[]}>('engine_snapshot'),
 newSession:()=>invoke<void>('engine_new_session'),
 answer:(requestId:string,answers:string[][])=>invoke<void>('engine_question_reply',{requestId,answers}),
};
export function commandPreview(raw:string):string {
 const marker=" -Command '& { ";const at=raw.indexOf(marker);
 return at>=0&&raw.endsWith(" }'")?raw.slice(at+marker.length,-3).replaceAll("''","'"):raw;
}
export function permissionWarning(p:EnginePermission):string|null {
 const text=JSON.stringify(p).replaceAll('\\\\','\\').toLowerCase();
 const command=String(p.metadata.command||'').toLowerCase();
 if(/\b(format(?:\.com)?|diskpart|bcdedit|vssadmin|wbadmin|sdelete|cipher|clear-disk|initialize-disk|format-volume|remove-partition|set-partition)\b/.test(command))return 'Critical disk / boot / recovery operation: review every argument.';
 if(/hklm|hkey_local_machine/.test(text))return 'Machine-wide registry operation.';
 if(/c:\\windows|c:\\program files|programdata|engine-runtime|nova-plugin/.test(text))return 'Protected system or Nova path: do not approve unless you specifically intend this.';
 if(/\b(remove-item|del|erase|rmdir|rd|rm)\b|\.delete\s*\(/.test(command))return 'This command may permanently delete files. Prefer nova_recycle.';
 return command?'Opaque shell commands can conceal destructive actions. Approval is for this exact call only.':null;
}
export function turnUsage(messages:EngineMessage[],profile?:EngineProfile){
 const latest=[...messages].reverse().find(m=>m.info.role==='user');
 const replies=messages.filter(m=>m.info.role==='assistant'&&m.info.parentID===latest?.info.id);
 const usage={input:0,output:0,reasoning:0,cached:0,cost:null as number|null};
 for(const m of replies){const t=m.info.tokens;if(t){usage.input+=t.input;usage.output+=t.output;usage.reasoning+=t.reasoning;usage.cached+=t.cache?.read||0;}}
 if(profile?.inputUsdPerMillion!=null&&profile.outputUsdPerMillion!=null&&replies.length)usage.cost=replies.reduce((n,m)=>n+(m.info.cost||0),0);
 return usage;
}
class EngineState {
 config:EngineConfig={profiles:[],activeProfile:'',workspace:'',lastSession:null};
 status:EngineStatus={online:false,busy:false,profileId:'',workspace:'',mode:'normal',sessionId:null,restartCount:0,error:null,version:'1.18.35'};
 messages:EngineMessage[]=[];permissions=new Map<string,EnginePermission>();questions=new Map<string,EngineQuestion>();
 error='';initialized=false;private listeners=new Set<()=>void>();private loading:Promise<void>|null=null;
 subscribe(fn:()=>void){this.listeners.add(fn);return()=>this.listeners.delete(fn);}
 notify(){for(const f of this.listeners)f();}
 async initialize(){
  if(this.loading)return this.loading;
  this.loading=(async()=>{if(!IS_TAURI)return;
   await onEvent<EngineStatus>('engine-status',s=>{this.status=s;if(!s.online){this.permissions.clear();this.questions.clear();}this.notify();});
   await onEvent<{type:string;properties:any}>('engine-event',e=>this.accept(e));
   await onEvent<EngineConfig>('engine-config-changed',c=>{this.config=c;this.error='';this.notify();});
   this.config=await EngineBridge.config();this.status=await EngineBridge.status();this.initialized=true;
   if(!this.status.online&&this.config.lastSession){try{this.messages=(await EngineBridge.readHistory(this.config.lastSession)).messages||[];}catch{ /* First-run or interrupted conversation has no cache yet. */ }}
   if(this.status.online)await this.refresh();this.notify();
  })().catch(e=>{this.error=String(e);this.notify();});return this.loading;
 }
 async refresh(){if(!this.status.online)return;const s=await EngineBridge.snapshot();this.messages=s.messages;this.permissions=new Map(s.permissions.map(p=>[p.id,p]));this.notify();}
 accept(e:{type:string;properties:any}){
  const p=e.properties;
  const sid=p.info?.sessionID||p.part?.sessionID||p.sessionID;
  if(sid&&this.status.sessionId&&sid!==this.status.sessionId)return;
  if(e.type==='permission.asked')this.permissions.set(p.id,p);
  if(e.type==='permission.replied')this.permissions.delete(p.requestID);
  if(e.type==='question.asked')this.questions.set(p.id,p);
  if(e.type==='question.replied'||e.type==='question.rejected')this.questions.delete(p.requestID);
  if(e.type==='message.updated'){
   const old=this.messages.find(m=>m.info.id===p.info.id);if(old)old.info=p.info;else this.messages.push({info:p.info,parts:[]});
  }
  if(e.type==='message.part.updated'){
   const part=p.part as EnginePart;let msg=this.messages.find(m=>m.info.id===part.messageID);
   if(!msg){msg={info:{id:part.messageID,role:'assistant'},parts:[]};this.messages.push(msg);}
   const at=msg.parts.findIndex(x=>x.id===part.id);if(at<0)msg.parts.push(part);else msg.parts[at]=part;
  }
  if(e.type==='message.part.delta'){
   const msg=this.messages.find(m=>m.info.id===p.messageID);const part=msg?.parts.find(x=>x.id===p.partID);
   if(part&&p.field==='text')part.text=(part.text||'')+p.delta;
  }
  if(e.type==='session.error')this.error=String(p.error?.data?.message||p.error?.message||'Engine task failed');
  this.notify();
 }
 async submit(query:string,attachments:string[]=[]){
  await this.initialize();this.config=await EngineBridge.config();if(this.status.busy)throw new Error('Stop the current task first');
  if(!this.config.activeProfile)throw new Error('Add a managed provider profile in Settings first');
  this.error='';
  if(!this.status.online)this.status=await EngineBridge.start(this.config.activeProfile,this.config.workspace,this.status.mode);
  this.status.busy=true;this.notify();
  try{await EngineBridge.send(query,attachments);await this.refresh();}finally{this.status=await EngineBridge.status();this.notify();}
 }
 async selectProfile(id:string){
  if(this.status.busy)throw new Error('Stop the task before switching providers');
  this.config=await EngineBridge.preferences(this.config.workspace,id);
  if(this.status.online){const mode=this.status.mode;await EngineBridge.stop();this.status=await EngineBridge.start(id,this.config.workspace,mode);await this.refresh();}
  this.notify();
 }
}
export const Engine=new EngineState();
