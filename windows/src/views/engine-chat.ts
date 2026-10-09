import { h,clear,svg } from './dom';
import { ICONS } from './icons';
import { renderMarkdown } from './markdown';
import { Engine,EngineBridge,commandPreview,permissionWarning,turnUsage,type Attachment } from '../core/engine';
import { Bridge } from '../core/bridge';
import { State } from '../core/state';
import { t } from '../i18n/i18n';
import type { ViewHost } from './views';

export function buildEnginePrompt(onHeightChange:()=>void):ViewHost {
 const status=h('span',{class:'engine-status',text:'Ready to set up'});
 const settings=h('button',{class:'engine-link',text:t('Settings'),onclick:()=>void Bridge.openSettingsWindow()});
 const historyButton=h('button',{class:'engine-link',text:'Chat history'});
 const fresh=h('button',{class:'engine-link',text:'New conversation'});
 const stop=h('button',{class:'engine-link stop-task',text:'Stop task'});
 const profiles=h('select',{'aria-label':'AI provider profile',class:'engine-profile'}) as HTMLSelectElement;
 const mode=h('select',{'aria-label':'Permission mode',class:'engine-mode'},h('option',{value:'normal',text:'Ask for changes / commands'}),h('option',{value:'strict',text:'Ask before every tool'})) as HTMLSelectElement;
 const header=h('div',{class:'engine-toolbar'},status,h('div',{class:'engine-actions'},historyButton,fresh,settings));
 const picker=h('div',{class:'engine-picker'},profiles,mode,stop);
 const log=h('div',{class:'chat-log engine-log'});
 const approvals=h('div',{class:'engine-approvals'});
 const usage=h('div',{class:'engine-usage'});
 const error=h('div',{class:'engine-error',role:'status'});
 const attached=h('div',{class:'engine-attachments'});
 const add=h('button',{class:'attach-btn',title:'Attach files or photos','aria-label':'Attach files or photos'},svg(ICONS.plus,14));
 const input=h('textarea',{class:'chat-input engine-input',placeholder:'Ask Nova, or give a file path to inspect…','aria-label':'Message',rows:2}) as HTMLTextAreaElement;
 const send=h('button',{class:'send-btn',title:t('Send')},svg(ICONS.arrowUp,12));
 const history=h('div',{class:'engine-history'});
 const search=h('input',{type:'search',placeholder:'Search conversations on this PC','aria-label':'Search local conversations'}) as HTMLInputElement;
 const historyRows=h('div',{class:'engine-history-rows'});
 history.append(h('p',{class:'engine-empty',text:'Saved on this PC. Open a conversation to continue it. Chat content is not encrypted.'}),search,historyRows);
 const body=h('div',{class:'chat-body engine-body'},header,picker,error,log,history,approvals,usage,attached,h('div',{class:'chat-bar'},add,input,send));
 const el=h('div',{class:'view'},h('div',{class:'card chat-card engine-card'},body));
 let sending=false,historyOpen=false,files:Attachment[]=[];let lastMessages='',lastPermissions='',lastProfiles='';let frame:number|null=null;let count=-1;let shown=100;let searchTimer:number|undefined;let historyRequest=0;
 async function action(fn:()=>Promise<unknown>){try{Engine.error='';await fn();}catch(e){Engine.error=String(e).replace(/^Error:\s*/,'');}Engine.notify();}
 async function newConversation(){if(Engine.status.busy)throw new Error('Stop the current task first');await EngineBridge.newSession();Engine.messages=[];Engine.permissions.clear();Engine.questions.clear();Engine.status.sessionId=null;files=[];historyOpen=false;shown=100;}
 profiles.addEventListener('change',()=>void action(()=>Engine.selectProfile(profiles.value)));
 mode.addEventListener('change',()=>void action(async()=>{if(Engine.status.busy)throw new Error('Stop the current task first');const next=mode.value as 'strict'|'normal';if(Engine.status.online){await EngineBridge.stop();Engine.status=await EngineBridge.start(Engine.config.activeProfile,Engine.config.workspace,next);}else Engine.status.mode=next;}));
 stop.addEventListener('click',()=>void action(async()=>{Engine.status=await EngineBridge.stop();}));
 fresh.addEventListener('click',()=>void action(newConversation));
 add.addEventListener('click',()=>void action(async()=>{const picked=await EngineBridge.pickFiles();if(files.length+picked.length>5)throw new Error('Attach at most five files per message');files.push(...picked);}));
 async function listHistory(){const ticket=++historyRequest;const rows=await EngineBridge.history(search.value);if(ticket!==historyRequest)return;clear(historyRows);if(!rows.length)historyRows.append(h('p',{class:'engine-empty',text:'No matching conversations yet.'}));for(const row of rows){const b=h('button',{class:'history-row',title:row.workspace},h('strong',{text:row.title}),h('span',{text:new Date(row.updated).toLocaleString()}));b.addEventListener('click',()=>void action(async()=>{const selected=await EngineBridge.resume(row.id);Engine.messages=selected.messages||[];Engine.config=await EngineBridge.config();Engine.status=await EngineBridge.status();historyOpen=false;files=[];shown=100;}));historyRows.append(b);}}
 historyButton.addEventListener('click',()=>void action(async()=>{historyOpen=!historyOpen;if(historyOpen)await listHistory();}));
 search.addEventListener('input',()=>{clearTimeout(searchTimer);searchTimer=window.setTimeout(()=>void action(listHistory),200);});
 async function submit(){const query=input.value.trim();if(!query||sending||Engine.status.busy)return;sending=true;historyOpen=false;State.stateOverride='thinking';State.notify();sync();
  try{await Engine.submit(query,files.map(f=>f.path));input.value='';files=[];}catch(e){Engine.error=String(e).replace(/^Error:\s*/,'');}finally{sending=false;State.stateOverride=null;State.notify();sync();input.focus();}}
 send.addEventListener('click',()=>void submit());input.addEventListener('keydown',e=>{const k=e as KeyboardEvent;if(k.key==='Enter'&&!k.shiftKey){e.preventDefault();void submit();}e.stopPropagation();});
 function drawMessages(){
  const signature=JSON.stringify(Engine.messages)+shown;if(signature===lastMessages)return;lastMessages=signature;
  const follow=log.scrollHeight-log.scrollTop-log.clientHeight<40;const before=log.scrollTop;clear(log);
  if(!Engine.messages.length)log.append(h('div',{class:'engine-empty'},h('strong',{text:'What would you like to do?'}),h('p',{text:Engine.config.profiles.length?'Give a request or an absolute file path. Nova can read files; every command and edit asks permission.':'Open Settings → AI Chat. Add a provider, or import your previous saved chat key. Then send your first request.'}),h('p',{text:'Use + to attach photos, PDFs or text/code. Photo/PDF support depends on your model.'})));
  if(Engine.messages.length>shown){const more=h('button',{class:'engine-link',text:'Load earlier messages'});more.addEventListener('click',()=>{shown+=100;Engine.notify();});log.append(more);}
  for(const m of Engine.messages.slice(-shown)){
   const text=m.parts.filter(p=>p.type==='text').map(p=>p.text||'').join('\n');
   if(text){const reply=h('div',{class:m.info.role==='user'?'bubble':'reply'});if(m.info.role==='user')reply.textContent=text;else renderMarkdown(reply,text);const row=h('div',{class:m.info.role==='user'?'chat-row user':'chat-row'},reply);if(m.info.role==='assistant'){const copy=h('button',{class:'message-copy',title:'Copy reply','aria-label':'Copy reply'},svg(ICONS.copy,11));copy.addEventListener('click',()=>void action(()=>navigator.clipboard.writeText(text)));row.append(copy);}log.append(row);}
   for(const file of m.parts.filter(p=>p.type==='file'))log.append(h('span',{class:'engine-attachment-label',text:'Attached: '+String((file as any).filename||'file')}));
   for(const part of m.parts.filter(p=>p.type==='tool')){
    const s=part.state;if(!s)continue;const title=String(s.metadata?.filepath||s.input.filePath||s.input.filepath||s.input.command||part.tool||'Tool');
    const details=h('details',{class:'engine-tool'},h('summary',{text:`${part.tool} · ${s.status} · ${commandPreview(title).slice(0,100)}`}));
    if(typeof s.metadata?.diff==='string')details.append(h('pre',{class:'engine-diff',text:s.metadata.diff}));
    if(s.output||s.error)details.append(h('pre',{class:'engine-output',text:(s.output||s.error||'').slice(0,32000)}));log.append(details);
   }
   if(m.info.error)log.append(h('div',{class:'engine-error',text:JSON.stringify(m.info.error)}));
  }
  log.scrollTop=follow?log.scrollHeight:before;
 }
 function drawApprovals(){
  const signature=JSON.stringify([[...Engine.permissions.values()],[...Engine.questions.values()]]);if(signature===lastPermissions)return;lastPermissions=signature;clear(approvals);
  for(const p of Engine.permissions.values()){
   const command=p.metadata.command;const shell=typeof command==='string';
   const box=h('div',{class:'engine-permission'},h('strong',{text:`Permission needed · ${p.permission}`}),h('span',{class:'engine-deadline',text:'Unanswered requests deny after 60 seconds. Allow applies to this call only.'}));
   const warn=permissionWarning(p);if(warn)box.append(h('p',{class:'engine-warning',text:warn}));
   box.append(h('pre',{class:'engine-command',text:shell?commandPreview(command):p.patterns.join('\n')}));
   if(typeof p.metadata.diff==='string')box.append(h('details',{class:'engine-tool'},h('summary',{text:'Review file changes'}),h('pre',{class:'engine-diff',text:p.metadata.diff})));
   const consent=h('input',{type:'checkbox'}) as HTMLInputElement;
   if(shell)box.append(h('label',{class:'engine-consent'},consent,'I reviewed this command and permit its effects, including any permanent deletion it may contain.'));
   const allow=h('button',{class:'engine-allow',text:'Allow once'});allow.disabled=shell;
   consent.addEventListener('change',()=>{allow.disabled=shell&&!consent.checked;});
   allow.addEventListener('click',()=>void action(()=>EngineBridge.reply(p.id,true,consent.checked)));
   box.append(h('div',{class:'engine-decision-row'},h('button',{class:'engine-deny',text:t('Deny'),onclick:()=>void action(()=>EngineBridge.reply(p.id,false))}),allow));approvals.append(box);
  }
  for(const q of Engine.questions.values()){
   const box=h('div',{class:'engine-permission'});const values:string[][]=q.questions.map(()=>[]);
   q.questions.forEach((question,index)=>{box.append(h('strong',{text:question.question}));const group=h('div',{class:'engine-answer-group'});for(const option of question.options){const b=h('button',{class:'engine-answer',text:option.label,title:option.description});b.addEventListener('click',()=>{if(question.multiple){values[index]=values[index].includes(option.label)?values[index].filter(x=>x!==option.label):[...values[index],option.label];b.classList.toggle('selected',values[index].includes(option.label));}else{values[index]=[option.label];for(const sibling of group.children)sibling.classList.remove('selected');b.classList.add('selected');}});group.append(b);}box.append(group);});
   box.append(h('button',{class:'engine-allow',text:'Submit answer',onclick:()=>void action(async()=>{if(values.some(a=>!a.length))throw new Error('Choose an answer for each question');await EngineBridge.answer(q.id,values);Engine.questions.delete(q.id);})}));approvals.append(box);
  }
 }
 function sync(){
  const s=Engine.status;if(s.busy||Engine.permissions.size)historyOpen=false;
  const active=Engine.questions.size?"question":Engine.permissions.size?"approval":s.busy?"thinking":null;
  if(State.stateOverride!==active&&(s.busy||sending||State.stateOverride==="thinking"||State.stateOverride==="approval")){State.stateOverride=active;State.notify();}
  status.textContent=s.busy?'Working on your request…':s.online?'Engine ready':'Engine starts when you send';status.classList.toggle('online',s.online);
  error.textContent=Engine.error||s.error||'';stop.disabled=!s.online;fresh.disabled=s.busy;historyButton.disabled=s.busy;add.disabled=sending||s.busy;input.disabled=sending||s.busy;send.disabled=sending||s.busy;profiles.disabled=s.busy;mode.disabled=s.busy;mode.value=s.mode;
  const signature=JSON.stringify(Engine.config.profiles);if(signature!==lastProfiles){lastProfiles=signature;clear(profiles);if(!Engine.config.profiles.length)profiles.append(h('option',{text:'Set up AI Chat in Settings',value:''}));for(const p of Engine.config.profiles)profiles.append(h('option',{value:p.id,text:`${p.label} · ${p.modelId}`}));}profiles.value=Engine.config.activeProfile;
  log.style.display=historyOpen?'none':'';history.style.display=historyOpen?'flex':'none';historyButton.classList.toggle('selected',historyOpen);
  drawMessages();drawApprovals();clear(attached);for(const f of files){const remove=h('button',{class:'attachment-remove',title:'Remove attachment',text:'×'});remove.addEventListener('click',()=>{files=files.filter(x=>x!==f);Engine.notify();});attached.append(h('span',{class:'attachment-chip'},f.name,remove));}
  const p=Engine.config.profiles.find(p=>p.id===Engine.config.activeProfile);const u=turnUsage(Engine.messages,p);usage.textContent=Engine.messages.length?`This turn: ${u.input} in · ${u.output} out · ${u.cached} cached${u.cost==null?'':` · estimated $${u.cost.toFixed(5)}`}`:'Enter sends · Shift+Enter adds a line · Ctrl+Alt+K emergency stop';
  if(count!==Engine.messages.length){count=Engine.messages.length;onHeightChange();}
 }
 Engine.subscribe(()=>{if(frame!=null)return;frame=requestAnimationFrame(()=>{frame=null;sync();});});void Engine.initialize();
 return{el,sync,focus(){input.focus();}};
}
