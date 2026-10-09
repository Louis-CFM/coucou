// OpenCode host adapter: process lifetime, fixed API calls and event forwarding.
// OpenCode owns the agent loop, tools, context, sessions and native permissions.
use std::{collections::{HashMap,HashSet}, io::{Read,Write}, net::TcpListener, path::{Path,PathBuf}, process::{Child,Command,Stdio}, sync::{Mutex,OnceLock}, time::{Duration,Instant,SystemTime,UNIX_EPOCH}};
use serde::{Serialize,Deserialize};
use serde_json::{json,Value};
use tauri::{AppHandle,Emitter,Manager};
use crate::engine_profiles::{self,Profile};
use windows::{core::PCWSTR,Win32::{Foundation::{HANDLE,CloseHandle},Security::Cryptography::{BCryptGenRandom,BCRYPT_USE_SYSTEM_PREFERRED_RNG},System::JobObjects::{CreateJobObjectW,AssignProcessToJobObject,SetInformationJobObject,JOBOBJECT_EXTENDED_LIMIT_INFORMATION,JobObjectExtendedLimitInformation,JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE}}};
use std::os::windows::io::AsRawHandle;
const ENGINE_VERSION:&str="1.18.35";
const APPROVAL_TIMEOUT:Duration=Duration::from_secs(60);
static APP:OnceLock<AppHandle>=OnceLock::new();
static STATE:OnceLock<Mutex<State>>=OnceLock::new();
static START:OnceLock<tokio::sync::Mutex<()>>=OnceLock::new();
fn state()->&'static Mutex<State>{STATE.get_or_init(||Mutex::new(State::default()))}
fn start_lock()->&'static tokio::sync::Mutex<()>{START.get_or_init(||tokio::sync::Mutex::new(()))}
#[derive(Clone,Serialize,Default)]
#[serde(rename_all="camelCase")]
pub struct Status { pub online:bool,pub busy:bool,pub profile_id:String,pub workspace:String,pub mode:String,pub session_id:Option<String>,pub restart_count:u32,pub error:Option<String>,pub version:String }
#[derive(Clone)]
struct Connection{url:String,password:String,secrets:Vec<String>,cwd:String,generation:u64,session:Option<String>}
struct Process{child:Child,job:Job,connection:Connection}
struct Job(isize);
impl Drop for Job{fn drop(&mut self){unsafe{let _=CloseHandle(HANDLE(self.0 as _));}}}
#[derive(Clone)]struct Desired{profile_id:String,workspace:String,mode:String}
struct Pending{value:Value,deadline:Instant}
struct State{process:Option<Process>,status:Status,desired:Option<Desired>,generation:u64,pending:HashMap<String,Pending>,audited:HashSet<String>}
impl Default for State{fn default()->Self{Self{process:None,status:Status{mode:"normal".into(),version:ENGINE_VERSION.into(),..Default::default()},desired:None,generation:0,pending:HashMap::new(),audited:HashSet::new()}}}
fn emit(name:&str,value:Value){if let Some(app)=APP.get(){let _=app.emit(name,value);}}
fn emit_status(){emit("engine-status",serde_json::to_value(&state().lock().unwrap().status).unwrap());}
fn redact(value:&Value,secrets:&[String])->Value{
 match value {
  Value::String(text)=>{if text.starts_with("data:")&&text.len()>1024{return json!("[attachment content stored locally]");}let mut out=text.clone();for key in secrets.iter().filter(|s|!s.is_empty()){out=out.replace(key,"[REDACTED]");}json!(out)},
  Value::Array(a)=>Value::Array(a.iter().map(|v|redact(v,secrets)).collect()),
  Value::Object(m)=>Value::Object(m.iter().map(|(k,v)|(k.clone(),redact(v,secrets))).collect()),
  _=>value.clone()
 }
}
pub fn settings_editable()->Result<(),String>{if state().lock().unwrap().status.busy{Err("Stop the current task before changing setup".into())}else{Ok(())}}
pub fn config_changed(){shutdown();state().lock().unwrap().status.error=None;emit_status();emit("engine-config-changed",serde_json::to_value(engine_profiles::load()).unwrap());}

fn audit(value:Value,secrets:&[String]){
    let dir=crate::settings::local_dir();let _=crate::platform::ensure_private_dir(&dir);
    if let Ok(mut f)=std::fs::OpenOptions::new().create(true).append(true).open(dir.join("engine-audit.jsonl")){
        let entry=json!({"time":SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis(),"record":redact(&value,secrets)});
        let _=writeln!(f,"{entry}");
    }
}
fn random_password()->Result<String,String>{let mut bytes=[0u8;32];let result=unsafe{BCryptGenRandom(None,&mut bytes,BCRYPT_USE_SYSTEM_PREFERRED_RNG)};if result.0<0{return Err("Secure local engine authentication unavailable".into());}Ok(bytes.iter().map(|b|format!("{b:02x}")).collect())}
fn job(child:&Child)->Result<Job,String>{unsafe{
    let h=CreateJobObjectW(None,PCWSTR::null()).map_err(|_|"Cannot create engine process group")?;let owned=Job(h.0 as isize);
    let mut info=JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();info.BasicLimitInformation.LimitFlags=JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
    SetInformationJobObject(h,JobObjectExtendedLimitInformation,&info as *const _ as _,std::mem::size_of_val(&info) as u32).map_err(|_|"Cannot secure engine process group")?;
    AssignProcessToJobObject(h,HANDLE(child.as_raw_handle())).map_err(|_|"Cannot attach engine to its process group")?;Ok(owned)
}}
fn root()->PathBuf{crate::settings::local_dir().join("engine-runtime")}
fn exe()->Result<PathBuf,String>{
    if let Ok(p)=std::env::var("NOVA_ENGINE_TEST_EXE"){#[cfg(test)]return Ok(PathBuf::from(p));#[cfg(not(test))]let _=p;}
    let mut choices=Vec::new();if let Some(app)=APP.get(){if let Ok(dir)=app.path().resource_dir(){choices.push(dir.join("engine/opencode.exe"));}}
    if let Ok(app)=std::env::current_exe(){if let Some(dir)=app.parent(){choices.push(dir.join("engine/opencode.exe"));choices.push(dir.join("opencode.exe"));}}
    choices.into_iter().find(|p|p.is_file()).ok_or("Bundled OpenCode engine is missing; reinstall Nova or keep the portable engine folder alongside nova.exe".into())
}
pub fn workspace(raw:&str)->Result<PathBuf,String>{
    let path=if raw.trim().is_empty(){crate::platform::home_dir().join("NovaWorkspace")}else{PathBuf::from(raw.trim())};
    if !path.is_absolute()||path.parent().is_none(){return Err("Select an absolute project folder, not a drive root".into());}
    if raw.trim().is_empty(){std::fs::create_dir_all(&path).map_err(|_|"Cannot create NovaWorkspace")?;}
    if !path.is_dir(){return Err("Choose an existing folder, or leave blank for NovaWorkspace".into());}
    let canonical=path.canonicalize().map_err(|_|"Cannot resolve the project folder")?;
    let normalized=canonical.to_string_lossy().replace("\\\\?\\","").to_lowercase();
    let mut blocked=vec![std::env::var("SystemRoot").unwrap_or_else(|_|"C:\\Windows".into()),std::env::var("ProgramFiles").unwrap_or_else(|_|"C:\\Program Files".into()),std::env::var("ProgramData").unwrap_or_else(|_|"C:\\ProgramData".into()),crate::settings::local_dir().to_string_lossy().into_owned()];
    blocked.push(std::env::var("ProgramFiles(x86)").unwrap_or_else(|_|"C:\\Program Files (x86)".into()));
    blocked.push(crate::settings::config_dir().to_string_lossy().into_owned());
    if let Ok(exe)=std::env::current_exe(){if let Some(p)=exe.parent(){blocked.push(p.to_string_lossy().into_owned());}}
    if blocked.iter().any(|b|{let b=std::fs::canonicalize(b).map(|p|p.to_string_lossy().replace("\\\\?\\", "").to_lowercase()).unwrap_or_else(|_|b.to_lowercase());normalized==b||normalized.starts_with(&(b+"\\"))}){return Err("Do not use a protected system/app folder as the engine workspace".into());}
    Ok(PathBuf::from(canonical.to_string_lossy().replace("\\\\?\\","")))
}
pub fn rules(mode:&str)->Value{
 let mut r=vec![json!({"permission":"*","pattern":"*","action":"ask"})];
 if mode=="normal"{for name in ["read","glob","grep","list"]{r.push(json!({"permission":name,"pattern":"*","action":"allow"}));}}
 for pattern in [".env",".env.*","**/.env","**/.env.*"]{r.push(json!({"permission":"read","pattern":pattern,"action":"deny"}));}
 // Subagents/MCP are not exposed before Phase 5. No 'always' approvals exist.
 r.push(json!({"permission":"task","pattern":"*","action":"deny"}));json!(r)
}
fn config(p:&Profile,plugin:&Path)->Value{
 let npm=match p.protocol.as_str(){"anthropic"=>"@ai-sdk/anthropic","google"=>"@ai-sdk/google","openai-responses"=>"@ai-sdk/openai",_=>"@ai-sdk/openai-compatible"};
 let mut options=p.params.clone();let context=options.remove("contextWindow").and_then(|v|v.as_u64()).unwrap_or(128000);let output=options.remove("maxOutputTokens").and_then(|v|v.as_u64()).unwrap_or(8192).min(context);
 let mut model=json!({"name":p.model_id,"tool_call":true,"modalities":{"input":["text","image","pdf"],"output":["text"]},"limit":{"context":context,"output":output},"options":options});
 if let (Some(input),Some(output))=(p.input_usd_per_million,p.output_usd_per_million){model["cost"]=json!({"input":input,"output":output,"cache_read":p.cached_input_usd_per_million.unwrap_or(input),"cache_write":input});}
 json!({"shell":std::env::var("SystemRoot").unwrap_or_else(|_|"C:\\Windows".into())+"\\System32\\WindowsPowerShell\\v1.0\\powershell.exe","$schema":"https://opencode.ai/config.json","model":format!("nova/{}",p.model_id),"enabled_providers":["nova"],"autoupdate":false,"share":"disabled","snapshot":false,"lsp":false,"formatter":false,"plugin":[reqwest::Url::from_file_path(plugin).unwrap().to_string()],"permission":{"*":"ask","task":"deny"},"provider":{"nova":{"npm":npm,"name":p.label,"options":{"baseURL":p.base_url,"apiKey":"{env:NOVA_PROVIDER_API_KEY}","timeout":300000},"models":{p.model_id.clone():model}}}})
}
fn spawn(p:&Profile,key:String,cwd:&Path,generation:u64,base:&Path)->Result<Process,String>{
    let bin=exe()?;crate::platform::ensure_private_dir(base).map_err(|_|"Cannot create private engine data directory")?;
    let plugin_dir=base.join("config/opencode");std::fs::create_dir_all(&plugin_dir).map_err(|_|"Cannot create engine config")?;
    let plugin=plugin_dir.join("nova-plugin.mjs");std::fs::write(&plugin,include_str!("../../engine-plugin/nova.mjs")).map_err(|_|"Cannot install engine adapter")?;
    let password=random_password()?;let socket=TcpListener::bind("127.0.0.1:0").map_err(|_|"Cannot allocate a local engine port")?;let port=socket.local_addr().unwrap().port();drop(socket);
    let mut cmd=Command::new(bin);cmd.args(["serve","--hostname","127.0.0.1","--port",&port.to_string(),"--log-level","ERROR"]);
    cmd.current_dir(cwd).env_clear();
    for name in ["PATH","SystemRoot","WINDIR","SystemDrive","USERPROFILE","HOMEDRIVE","HOMEPATH","TEMP","TMP","ComSpec","PATHEXT","APPDATA","LOCALAPPDATA","PROCESSOR_ARCHITECTURE","NUMBER_OF_PROCESSORS"]{if let Some(v)=std::env::var_os(name){cmd.env(name,v);}}
    cmd.env("NOVA_PROVIDER_API_KEY",&key).env("OPENCODE_SERVER_PASSWORD",&password).env("OPENCODE_SERVER_USERNAME","opencode").env("OPENCODE_DISABLE_PROJECT_CONFIG","true").env("OPENCODE_DISABLE_AUTOUPDATE","true").env("OPENCODE_DISABLE_MODELS_FETCH","true").env("OPENCODE_CONFIG_CONTENT",config(p,&plugin).to_string()).env("OPENCODE_TEST_HOME",base.join("home"));
    for (name,folder) in [("XDG_CONFIG_HOME","config"),("XDG_DATA_HOME","data"),("XDG_CACHE_HOME","cache"),("XDG_STATE_HOME","state")]{cmd.env(name,base.join(folder));}
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());crate::platform::no_console(&mut cmd);
    let mut child=cmd.spawn().map_err(|_|"OpenCode could not start")?;
    let group=match job(&child){Ok(j)=>j,Err(e)=>{let _=child.kill();let _=child.wait();return Err(e);}};
    // CLI diagnostics are deliberately not persisted: provider errors may contain secrets.
    if let Some(mut stream)=child.stdout.take(){std::thread::spawn(move||{let _=std::io::copy(&mut stream,&mut std::io::sink());});}
    if let Some(mut stream)=child.stderr.take(){std::thread::spawn(move||{let _=std::io::copy(&mut stream,&mut std::io::sink());});}
    Ok(Process{child,job:group,connection:Connection{url:format!("http://127.0.0.1:{port}"),password:password.clone(),secrets:vec![key,password],cwd:cwd.to_string_lossy().into_owned(),generation,session:None}})
}
fn connection()->Result<Connection,String>{state().lock().unwrap().process.as_ref().map(|p|p.connection.clone()).ok_or("Engine offline".into())}
fn client()->reqwest::Client{reqwest::Client::builder().no_proxy().connect_timeout(Duration::from_secs(5)).build().unwrap()}
async fn api(c:&Connection,method:reqwest::Method,path:&str,body:Option<Value>,timeout:Duration)->Result<Value,String>{
    let mut r=client().request(method,format!("{}{}",c.url,path)).basic_auth("opencode",Some(&c.password)).header("x-opencode-directory",&c.cwd).timeout(timeout);
    if let Some(body)=body{r=r.json(&body);}let res=r.send().await.map_err(|_|"Engine request failed or timed out")?;
    if !res.status().is_success(){let code=res.status().as_u16();
      #[cfg(test)]{let text=res.text().await.unwrap_or_default();return Err(format!("HTTP {code}: {}",redact(&json!(text),&c.secrets)));}
      #[cfg(not(test))]return Err(format!("Engine returned HTTP {code}; check the selected endpoint/model/key"));}
    let bytes=res.bytes().await.map_err(|_|"Incomplete engine response")?;if bytes.is_empty(){return Ok(Value::Null);}if bytes.len()>64*1024*1024{return Err("Engine response too large".into());}let v=serde_json::from_slice(&bytes).map_err(|_|"Invalid engine response")?;Ok(redact(&v,&c.secrets))
}
fn current(generation:u64)->bool{state().lock().unwrap().generation==generation}
fn handle_event(c:&Connection,event:Value){
    if !current(c.generation){return;}let event=redact(&event,&c.secrets);
    let kind=event["type"].as_str().unwrap_or("");let props=&event["properties"];
    if kind=="permission.asked"{track_pending(c,props.clone());}
    if kind=="permission.replied"{if let Some(id)=props["requestID"].as_str(){state().lock().unwrap().pending.remove(id);}}
    if kind=="message.part.updated"{
        let part=&props["part"];let status=part["state"]["status"].as_str().unwrap_or("");
        if part["type"]=="tool"&&["completed","error"].contains(&status){
            let id=part["id"].as_str().unwrap_or("").to_string();if state().lock().unwrap().audited.insert(id){
                let start=part["state"]["time"]["start"].as_i64().unwrap_or(0);let end=part["state"]["time"]["end"].as_i64().unwrap_or(start);
                audit(json!({"phase":"tool-finished","name":part["tool"],"arguments":part["state"]["input"],"status":status,"exitCode":part["state"]["metadata"]["exit"],"engineDurationMs":end-start}),&c.secrets);
            }
        }
    }
    if kind=="message.updated"&&props["info"]["time"]["completed"].is_number(){let generation=c.generation;tauri::async_runtime::spawn(async move{let _=cache_current(generation).await;});}
    emit("engine-event",event);
}
fn track_pending(c:&Connection,value:Value){
 if !current(c.generation){return;}if let Some(id)=value["id"].as_str(){let id=id.to_string();let mut s=state().lock().unwrap();if !s.pending.contains_key(&id){s.pending.insert(id.clone(),Pending{value:value.clone(),deadline:Instant::now()+APPROVAL_TIMEOUT});drop(s);audit(json!({"phase":"permission-requested","request":value}),&c.secrets);emit("engine-event",json!({"type":"permission.asked","properties":value}));let generation=c.generation;let request_id=id.clone();tauri::async_runtime::spawn(async move{tokio::time::sleep(APPROVAL_TIMEOUT).await;if let Ok(c)=connection(){if c.generation==generation{let _=reply_inner(&c,&request_id,false,false).await;}}});}}
}
async fn observe(c:Connection){
    let result=client().get(format!("{}/event",c.url)).basic_auth("opencode",Some(&c.password)).header("x-opencode-directory",&c.cwd).send().await;
    let Ok(mut stream)=result else{fail_connection(c.generation,"Engine event connection failed");return;};
    if !stream.status().is_success(){fail_connection(c.generation,"Engine events unavailable");return;}
    let mut buffer=Vec::new();
    while current(c.generation){match stream.chunk().await{
        Ok(Some(chunk))=>{buffer.extend_from_slice(&chunk);if buffer.len()>64*1024*1024{fail_connection(c.generation,"Oversized engine event");return;}
            while let Some(at)=buffer.iter().position(|b|*b==b'\n'){let line:Vec<u8>=buffer.drain(..=at).collect();if let Ok(line)=std::str::from_utf8(&line){if let Some(data)=line.trim().strip_prefix("data:"){if let Ok(v)=serde_json::from_str(data.trim()){handle_event(&c,v);}}}}
        },_=>{if current(c.generation){fail_connection(c.generation,"Engine event connection lost; interrupted tasks are never replayed");}return;}
    }}
}
fn stop_process(s:&mut State){s.generation+=1;s.pending.clear();if let Some(mut p)=s.process.take(){let _=p.child.kill();drop(p.job);let _=p.child.wait();}s.status.online=false;s.status.busy=false;}
fn fail_connection(generation:u64,error:&str){let mut s=state().lock().unwrap();if s.generation!=generation{return;}stop_process(&mut s);s.status.error=Some(error.into());drop(s);emit_status();}
pub fn shutdown(){let mut s=state().lock().unwrap();s.desired=None;stop_process(&mut s);}
pub fn kill_switch(){shutdown();state().lock().unwrap().status.mode="strict".into();emit_status();audit(json!({"phase":"kill-switch","mode":"strict"}),&[]);}
pub fn attach(app:AppHandle){
 if APP.set(app).is_err(){return;}
 tauri::async_runtime::spawn(async{
  loop{tokio::time::sleep(Duration::from_millis(500)).await;
   let conn=connection().ok();
   if let Some(c)=conn{
    let exited={let mut s=state().lock().unwrap();s.process.as_mut().is_some_and(|p|p.child.try_wait().ok().flatten().is_some())};
    if exited{fail_connection(c.generation,"Engine exited; restarting server without replaying the interrupted task");continue;}
    // Also catches permissions missed while the SSE connection was initializing.
    if let Ok(v)=api(&c,reqwest::Method::GET,"/permission",None,Duration::from_secs(5)).await{if let Some(a)=v.as_array(){for value in a{track_pending(&c,value.clone());}}}
    let expired:Vec<String>={let s=state().lock().unwrap();s.pending.iter().filter(|(_,p)|Instant::now()>=p.deadline).map(|(id,_)|id.clone()).collect()};
    for id in expired{let _=reply_inner(&c,&id,false,false).await;}
   }else{
    let desired={let mut s=state().lock().unwrap();if s.desired.is_some()&&s.status.restart_count<3{s.status.restart_count+=1;s.desired.clone()}else{None}};
    if let Some(d)=desired{let n=state().lock().unwrap().status.restart_count;tokio::time::sleep(Duration::from_secs(1<<n.min(3))).await;let still=state().lock().unwrap().desired.is_some();if still{let _=start_inner(d,true).await;}}
   }
  }
 });
}
async fn start_inner(d:Desired,recovery:bool)->Result<Status,String>{
 let _guard=start_lock().lock().await;if !["strict","normal"].contains(&d.mode.as_str()){return Err("Only Strict/Normal are enabled before hardening".into());}
 let mut cfg=engine_profiles::load();let mut p=cfg.profiles.iter().find(|p|p.id==d.profile_id).cloned().ok_or("Choose a saved provider profile")?;engine_profiles::validate(&mut p)?;
 let key=engine_profiles::credential(&p)?;let cwd=workspace(&d.workspace)?;
 let generation={let mut s=state().lock().unwrap();stop_process(&mut s);s.desired=Some(d.clone());s.status.profile_id=p.id.clone();s.status.workspace=cwd.to_string_lossy().into_owned();s.status.mode=d.mode.clone();if !recovery{s.status.restart_count=0;}s.generation};
 if !cfg.workspace.is_empty()&&cfg.workspace!=cwd.to_string_lossy(){cfg.last_session=None;}
 let mut process=match spawn(&p,key,&cwd,generation,&root()){Ok(p)=>p,Err(e)=>{fail_connection(generation,&e);state().lock().unwrap().desired=None;return Err(e);}};process.connection.session=cfg.last_session.clone();let c=process.connection.clone();state().lock().unwrap().process=Some(process);
 let mut healthy=false;for _ in 0..120{if !current(generation){return Err("Engine start cancelled".into());}if api(&c,reqwest::Method::GET,"/global/health",None,Duration::from_secs(2)).await.is_ok(){healthy=true;break;}tokio::time::sleep(Duration::from_millis(500)).await;}
 if !healthy{fail_connection(generation,"Engine did not become ready");return Err("Engine did not become ready".into());}
 let tools=api(&c,reqwest::Method::GET,"/experimental/tool/ids",None,Duration::from_secs(120)).await;
 if !tools.as_ref().ok().and_then(|v|v.as_array()).is_some_and(|a|a.iter().any(|v|v=="nova_recycle")&&a.iter().any(|v|v=="nova_history_search")){fail_connection(generation,"Safety plugin did not load; execution stays disabled");state().lock().unwrap().desired=None;return Err("Engine safety plugin unavailable; check network for first-start dependency setup".into());}
 cfg.active_profile=p.id;cfg.workspace=c.cwd.clone();engine_profiles::save(&cfg)?;
 {let mut s=state().lock().unwrap();if s.generation!=generation{return Err("Engine start cancelled".into());}s.status.online=true;s.status.error=None;s.status.session_id=c.session.clone();}
 tauri::async_runtime::spawn(observe(c));emit_status();Ok(state().lock().unwrap().status.clone())
}
#[tauri::command]pub async fn engine_start(profile_id:String,workspace:String,mode:String)->Result<Status,String>{start_inner(Desired{profile_id,workspace,mode},false).await}
#[tauri::command]pub fn engine_status()->Status{state().lock().unwrap().status.clone()}
#[tauri::command]pub fn engine_stop()->Status{shutdown();emit_status();state().lock().unwrap().status.clone()}
async fn session(c:&Connection)->Result<String,String>{
 let mode=state().lock().unwrap().status.mode.clone();
 if let Some(id)=&c.session{if api(c,reqwest::Method::PATCH,&format!("/session/{id}"),Some(json!({"permission":rules(&mode)})),Duration::from_secs(20)).await.is_ok(){return Ok(id.clone());}}
 let v=api(c,reqwest::Method::POST,"/session",Some(json!({"title":"Nova task","permission":rules(&mode)})),Duration::from_secs(30)).await?;
 let id=v["id"].as_str().ok_or("Engine did not return a session ID")?.to_string();
 {let mut s=state().lock().unwrap();if s.generation!=c.generation{return Err("Engine restarted".into());}if let Some(p)=s.process.as_mut(){p.connection.session=Some(id.clone());}s.status.session_id=Some(id.clone());}
 let mut cfg=engine_profiles::load();cfg.last_session=Some(id.clone());engine_profiles::save(&cfg)?;emit_status();Ok(id)
}
#[tauri::command]pub async fn engine_send(query:String,attachments:Option<Vec<String>>)->Result<Value,String>{
 if query.trim().is_empty()||query.len()>64000{return Err("Enter a request up to 64,000 bytes".into());}
 let selected=attachments.unwrap_or_default();let files=crate::engine_files::parts(&selected)?;
 let c=connection()?;
 {let mut s=state().lock().unwrap();if !s.status.online||s.status.busy{return Err("Engine is offline or busy".into());}s.status.busy=true;}emit_status();
 let result=async{
  let id=session(&c).await?;let cfg=engine_profiles::load();let p=cfg.profiles.iter().find(|p|p.id==cfg.active_profile).ok_or("Profile missing")?;
  let mut parts=vec![json!({"type":"text","text":query})];parts.extend(files);
  api(&c,reqwest::Method::POST,&format!("/session/{id}/message"),Some(json!({"model":{"providerID":"nova","modelID":p.model_id},"parts":parts,"system":"You are Nova, a personal Windows assistant using an existing local agent engine. Work in the selected project folder. Use native file tools for edits and nova_recycle for deletions. Never permanently delete through patch tools. Every shell call requires fresh user approval; never try to bypass it. Do not modify Nova, its runtime, credentials, permission configuration or plugins. Never put credentials into model messages, logs, commands or files."})),Duration::from_secs(1800)).await
 }.await;
 let _=cache_current(c.generation).await;
 {let mut s=state().lock().unwrap();if s.generation==c.generation{s.status.busy=false;}}emit_status();result
}
async fn reply_inner(c:&Connection,id:&str,allow:bool,permanent:bool)->Result<(),String>{
 let pending={let mut s=state().lock().unwrap();let p=s.pending.get(id).ok_or("Permission expired or was already answered")?;
  let shell=p.value["permission"]=="bash"||p.value["metadata"]["command"].is_string();
  if allow&&Instant::now()>=p.deadline{return Err("Permission expired; it will be denied".into());}
  if allow&&shell&&!permanent{return Err("Shell programs can conceal permanent deletions: explicitly consent for this exact command, or use nova_recycle".into());}
  let v=p.value.clone();s.pending.remove(id);v
 };
 let decision=if allow{"once"}else{"reject"};let result=api(c,reqwest::Method::POST,&format!("/permission/{id}/reply"),Some(json!({"reply":decision})),Duration::from_secs(5)).await;
 audit(json!({"phase":"permission-decision","requestId":id,"decision":decision,"permanentConfirmed":permanent,"request":pending}),&c.secrets);
 emit("engine-event",json!({"type":"permission.replied","properties":{"requestID":id,"reply":decision}}));
 if result.is_err(){fail_connection(c.generation,"Permission reply failed; engine stopped to fail closed");}result.map(|_|())
}
#[tauri::command]pub async fn engine_reply(request_id:String,allow:bool,permanent_confirmed:bool)->Result<(),String>{reply_inner(&connection()?,&request_id,allow,permanent_confirmed).await}
#[tauri::command]pub async fn engine_snapshot()->Result<Value,String>{
 let c=connection()?;let pending={let s=state().lock().unwrap();s.pending.values().map(|p|p.value.clone()).collect::<Vec<_>>()};
 let messages=if let Some(id)=&c.session{api(&c,reqwest::Method::GET,&format!("/session/{id}/message"),None,Duration::from_secs(10)).await?}else{json!([])};
 Ok(json!({"messages":messages,"permissions":pending}))
}
#[tauri::command]pub async fn engine_new_session()->Result<(),String>{
 settings_editable()?;
 let mut cfg=engine_profiles::load();cfg.last_session=None;engine_profiles::save(&cfg)?;
 {let mut s=state().lock().unwrap();if let Some(p)=s.process.as_mut(){p.connection.session=None;}s.pending.clear();s.status.session_id=None;}emit_status();Ok(())
}
async fn cache_current(generation:u64)->Result<(),String>{
 let c=connection()?;if c.generation!=generation{return Ok(());}
 if let Some(id)=&c.session{let messages=api(&c,reqwest::Method::GET,&format!("/session/{id}/message"),None,Duration::from_secs(30)).await?;crate::engine_history::save(id,&c.cwd,messages)?;}Ok(())
}
#[tauri::command]pub fn engine_resume(id:String)->Result<Value,String>{
 settings_editable()?;let entry=crate::engine_history::read(&id)?;let folder=workspace(entry["workspace"].as_str().ok_or("Invalid history workspace")?)?;
 shutdown();let mut cfg=engine_profiles::load();cfg.workspace=folder.to_string_lossy().into_owned();cfg.last_session=Some(id.clone());engine_profiles::save(&cfg)?;
 {let mut s=state().lock().unwrap();s.status.session_id=Some(id);s.status.workspace=cfg.workspace.clone();}emit_status();emit("engine-config-changed",serde_json::to_value(&cfg).unwrap());Ok(entry)
}
#[tauri::command]pub async fn engine_question_reply(request_id:String,answers:Vec<Vec<String>>)->Result<(),String>{
 api(&connection()?,reqwest::Method::POST,&format!("/question/{request_id}/reply"),Some(json!({"answers":answers})),Duration::from_secs(5)).await.map(|_|())
}
#[cfg(test)]mod tests{
 use super::*;
 #[test]fn modes_never_auto_allow_writes_or_shell(){for mode in ["strict","normal"]{let r=rules(mode);for kind in ["bash","edit","nova_recycle","unknown_mcp"]{assert!(!r.as_array().unwrap().iter().any(|x|x["permission"]==kind&&x["action"]=="allow"));}assert!(!r.to_string().contains("always"));}}
 #[test]fn output_redacts_keys(){let v=json!({"output":"Bearer private-key"});assert!(!redact(&v,&["private-key".into()]).to_string().contains("private-key"));}
}
#[cfg(test)]#[path="engine_integration.rs"]mod integration_tests;
