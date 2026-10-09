// Offline provider fixture: real OpenCode still executes real native file/shell tools.
import http from 'node:http';import {writeFileSync} from 'node:fs';import path from 'node:path';
const [portFile,workspace,key]=process.argv.slice(2);
const server=http.createServer(async(req,res)=>{
 if(req.headers.authorization!==`Bearer ${key}`){res.writeHead(401);res.end('{}');return;}
 const chunks=[];for await(const chunk of req)chunks.push(chunk);let b;try{b=JSON.parse(Buffer.concat(chunks).toString())}catch{res.writeHead(400);res.end('{}');return;}
 const messages=b.messages||[];const user=[...messages].reverse().find(m=>m.role==='user');const text=typeof user?.content==='string'?user.content:JSON.stringify(user?.content||'');
 const done=messages.some(m=>m.role==='tool');const names=(b.tools||[]).map(t=>t.function.name);let call=null;
 const q=s=>"'"+s.replaceAll("'","''")+"'";
 if(!done&&text.includes('WRITE_FIXTURE')&&names.includes('write'))call={name:'write',arguments:JSON.stringify({filePath:path.join(workspace,'written.txt'),content:'Nova real engine wrote this.'})};
 if(!done&&text.includes('SHELL_FIXTURE')&&names.includes('bash'))call={name:'bash',arguments:JSON.stringify({command:`[System.IO.File]::WriteAllText(${q(path.join(workspace,'shell.txt'))},'approved only')`})};
 if(!done&&text.includes('CHILD_FIXTURE')&&names.includes('bash'))call={name:'bash',arguments:JSON.stringify({command:`$p=Start-Process -FilePath "$PSHOME\\powershell.exe" -ArgumentList '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -Command "Start-Sleep -Seconds 120"' -WindowStyle Hidden -PassThru; Set-Content -LiteralPath ${q(path.join(workspace,'child.pid'))} -Value $p.Id`})};
 if(!done&&text.includes('FORMAT_DENY_FIXTURE')&&names.includes('bash'))call={name:'bash',arguments:JSON.stringify({command:'format Z: /FS:NTFS /Q /Y'})};
 const answer=call?null:text.includes('RECALL_FIXTURE')?'Your prior marker is NOVA_MEMORY_271.':'Fixture task complete.';
 if(!b.stream){res.setHeader('Content-Type','application/json');res.end(JSON.stringify({id:'chatcmpl-fixture',object:'chat.completion',created:1,model:b.model,choices:[{index:0,message:{role:'assistant',content:answer,tool_calls:call?[{id:'call_fixture',type:'function',function:call}]:undefined},finish_reason:call?'tool_calls':'stop'}],usage:{prompt_tokens:12,completion_tokens:8,total_tokens:20}}));return;}
 res.writeHead(200,{'Content-Type':'text/event-stream','Cache-Control':'no-cache'});
 const emit=x=>res.write('data: '+JSON.stringify({id:'chatcmpl-fixture',object:'chat.completion.chunk',created:1,model:b.model,...x})+'\n\n');
 emit({choices:[{index:0,delta:{role:'assistant'},finish_reason:null}]});
 if(call){emit({choices:[{index:0,delta:{tool_calls:[{index:0,id:'call_fixture',type:'function',function:{name:call.name,arguments:call.arguments}}]},finish_reason:null}]});}
 else emit({choices:[{index:0,delta:{content:answer},finish_reason:null}]});
 emit({choices:[{index:0,delta:{},finish_reason:call?'tool_calls':'stop'}]});emit({choices:[],usage:{prompt_tokens:12,completion_tokens:8,total_tokens:20}});res.end('data: [DONE]\n\n');
});server.listen(0,'127.0.0.1',()=>writeFileSync(portFile,String(server.address().port)));
