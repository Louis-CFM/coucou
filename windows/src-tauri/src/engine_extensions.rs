// Narrow configuration adapters for OpenCode's own skills, commands and MCP clients.
// No agent loop or MCP client implementation lives here.
use std::{path::{Path,PathBuf},collections::BTreeMap,sync::Mutex};
use serde::{Deserialize,Serialize};
use serde_json::{json,Value};
static WRITE:Mutex<()>=Mutex::new(());
#[derive(Clone,Serialize,Deserialize)]
#[serde(rename_all="camelCase",deny_unknown_fields)]
pub struct Instruction {pub id:String,pub description:String,pub body:String}
#[derive(Clone,Serialize,Deserialize)]
#[serde(rename_all="camelCase",deny_unknown_fields)]
pub struct Server {pub id:String,pub kind:String,pub url:String,pub command:Vec<String>,pub enabled:bool,pub authenticated:bool}
#[derive(Clone,Serialize,Deserialize)]
#[serde(rename_all="camelCase",deny_unknown_fields)]
pub struct Extensions {pub version:u32,pub skills:Vec<Instruction>,pub commands:Vec<Instruction>,pub servers:Vec<Server>}
impl Default for Extensions{fn default()->Self{Self{version:1,skills:vec![],commands:vec![],servers:vec![]}}}
fn file()->PathBuf{crate::settings::config_dir().join("engine-extensions.json")}
pub fn safe_id(id:&str)->bool{!id.is_empty()&&id.len()<=40&&id.bytes().all(|b|b.is_ascii_lowercase()||b.is_ascii_digit()||b==b'-')}
pub fn safe_command(text:&str)->Result<(),String>{if (text.contains('!')||text.contains('@'))||text.len()>64000{return Err("Instruction commands cannot contain ! or @: OpenCode expands shell/file references before permission hooks".into());}Ok(())}
fn validate(c:&mut Extensions)->Result<(),String>{
 if c.version!=1{return Err("Unsupported extension settings version; restore a compatible backup".into());}
 for list in [&c.skills,&c.commands]{if list.len()>24{return Err("At most 24 skills or commands".into());}let mut ids=std::collections::HashSet::new();for i in list{if !safe_id(&i.id)||!ids.insert(&i.id)||i.description.trim().is_empty()||i.description.len()>200||i.body.trim().is_empty()||i.body.len()>32000||i.body.contains('\0'){return Err("Use unique lowercase IDs, a short description and instruction text (max 32 KB)".into());}}}
 for i in &c.commands{safe_command(&i.body)?;}
 if c.servers.len()>12{return Err("At most 12 MCP servers".into());}let mut ids=std::collections::HashSet::new();
 for s in &mut c.servers{
  if !safe_id(&s.id)||!ids.insert(s.id.clone()){return Err("Use unique lowercase MCP IDs".into());}
  match s.kind.as_str(){
   "remote"=>{s.url=crate::engine_profiles::normal_url(&s.url)?;if !s.command.is_empty(){return Err("Remote MCP cannot specify a local command".into());}},
   "local"=>{if s.authenticated||!s.url.is_empty()||s.command.is_empty()||s.command.len()>24||s.command.iter().any(|v|v.len()>4096||v.chars().any(char::is_control)){return Err("Local MCP needs an existing .exe plus arguments; no URL or token".into());}let p=Path::new(&s.command[0]);if !p.is_absolute()||!p.is_file()||p.extension().and_then(|x|x.to_str()).is_none_or(|x|!x.eq_ignore_ascii_case("exe")){return Err("Local MCP must point to an existing absolute .exe; Nova does not install global tools".into());}},
   _=>return Err("MCP type must be remote or local".into())
  }
 }Ok(())
}
pub fn load()->Result<Extensions,String>{let bytes=match std::fs::read(file()){Ok(b)=>b,Err(e)if e.kind()==std::io::ErrorKind::NotFound=>return Ok(Extensions::default()),Err(_)=>return Err("Cannot read extension settings".into())};let mut c:Extensions=serde_json::from_slice(&bytes).map_err(|_|"Extension settings are damaged; preserve the file and restore a backup")?;validate(&mut c)?;Ok(c)}
fn save(c:&Extensions)->Result<(),String>{let _lock=WRITE.lock().unwrap();let dir=crate::settings::config_dir();crate::platform::ensure_private_dir(&dir).map_err(|_|"Cannot create private extension settings")?;let tmp=file().with_extension("tmp");std::fs::write(&tmp,serde_json::to_vec_pretty(c).map_err(|_|"Invalid extension settings")?).map_err(|_|"Cannot save extensions")?;std::fs::rename(tmp,file()).map_err(|_|"Cannot replace extension settings".into())}
#[tauri::command]pub fn engine_extensions()->Result<Extensions,String>{load()}
#[tauri::command]pub fn engine_instruction_save(instruction:Instruction,kind:String)->Result<Extensions,String>{crate::engine::settings_editable()?;let mut c=load()?;let list=match kind.as_str(){"skill"=>&mut c.skills,"command"=>&mut c.commands,_=>return Err("Choose skill or command".into())};list.retain(|i|i.id!=instruction.id);list.push(instruction);validate(&mut c)?;save(&c)?;crate::engine::config_changed();Ok(c)}
#[derive(Serialize,Deserialize)]struct BoundToken{url:String,token:String}
fn key(id:&str)->String{format!("engine-mcp-{id}")}
#[tauri::command]pub fn engine_mcp_save(mut server:Server,token:Option<String>,trusted_local:bool)->Result<Extensions,String>{
 crate::engine::settings_editable()?;let mut c=load()?;if server.kind=="local"&&!trusted_local{return Err("Explicitly trust this exact local server executable and arguments first".into());}
 c.servers.retain(|s|s.id!=server.id);c.servers.push(server.clone());validate(&mut c)?;server=c.servers.last().unwrap().clone();
 if let Some(token)=token.filter(|t|!t.is_empty()){if server.kind!="remote"||!server.authenticated||token.len()>4096||token.chars().any(char::is_control){return Err("Invalid remote MCP bearer token".into());}crate::secrets::set(&key(&server.id),&serde_json::to_string(&BoundToken{url:server.url.clone(),token}).unwrap())?;}
 if server.kind!="remote"||!server.authenticated{crate::secrets::clear(&key(&server.id))?;}save(&c)?;crate::engine::config_changed();Ok(c)
}
#[tauri::command]pub fn engine_extension_remove(kind:String,id:String)->Result<Extensions,String>{crate::engine::settings_editable()?;if !safe_id(&id){return Err("Invalid extension ID".into());}let mut c=load()?;match kind.as_str(){"skill"=>c.skills.retain(|i|i.id!=id),"command"=>c.commands.retain(|i|i.id!=id),"mcp"=>{c.servers.retain(|i|i.id!=id);crate::secrets::clear(&key(&id))?;},_=>return Err("Unknown extension type".into())}save(&c)?;crate::engine::config_changed();Ok(c)}
pub struct Runtime{pub commands:Value,pub mcp:Value,pub env:BTreeMap<String,String>,pub secrets:Vec<String>}
pub fn runtime(base:&Path)->Result<Runtime,String>{
 let c=load()?;let skills=base.join("config/opencode/skills");if skills.is_dir(){std::fs::remove_dir_all(&skills).map_err(|_|"Cannot refresh app-owned skills")?;}std::fs::create_dir_all(&skills).map_err(|_|"Cannot create app-owned skills")?;
 for i in &c.skills{let dir=skills.join(&i.id);std::fs::create_dir_all(&dir).map_err(|_|"Cannot write skill directory")?;let body=format!("---\nname: {}\ndescription: {}\n---\n\n{}\n",serde_json::to_string(&i.id).unwrap(),serde_json::to_string(&i.description).unwrap(),i.body);std::fs::write(dir.join("SKILL.md"),body).map_err(|_|"Cannot write skill")?;}
 let commands:serde_json::Map<String,Value>=c.commands.iter().map(|i|(format!("nova-{}",i.id),json!({"description":i.description,"template":i.body}))).collect();
 let mut env=BTreeMap::new();let mut secrets=Vec::new();let mut mcp=serde_json::Map::new();
 for s in c.servers.iter().filter(|s|s.enabled&&s.kind=="remote"&&s.authenticated){let raw=crate::secrets::get(&key(&s.id)).ok_or("MCP token missing; re-enter it in Settings")?;let b:BoundToken=serde_json::from_str(&raw).map_err(|_|"MCP token damaged; re-enter it")?;if b.url!=s.url{return Err("MCP endpoint changed: re-enter its token before contacting another host".into());}let name=format!("NOVA_MCP_TOKEN_{}",s.id.replace('-','_').to_uppercase());env.insert(name,b.token.clone());secrets.push(b.token);}
 for s in &c.servers{let name=format!("nova-{}",s.id);let v=if s.kind=="remote"{let mut v=json!({"type":"remote","url":s.url,"oauth":false,"enabled":s.enabled,"timeout":10000});if s.authenticated{let n=format!("NOVA_MCP_TOKEN_{}",s.id.replace('-','_').to_uppercase());v["headers"]=json!({"Authorization":format!("Bearer {{env:{n}}}")});}v}else{let mut isolated:BTreeMap<String,String>=env.keys().map(|k|(k.clone(),String::new())).collect();for n in ["NOVA_PROVIDER_API_KEY","OPENCODE_SERVER_PASSWORD"]{isolated.insert(n.into(),String::new());}json!({"type":"local","command":s.command,"enabled":s.enabled,"timeout":10000,"environment":isolated})};mcp.insert(name,v);}
 Ok(Runtime{commands:Value::Object(commands),mcp:Value::Object(mcp),env,secrets})
}
#[cfg(test)]mod tests{use super::*;#[test]fn command_pre_hook_shell_and_file_expansion_is_blocked(){for text in ["!`del C:\\x`","inspect @C:\\secrets","hello!","$ARGUMENTS @"]{assert!(safe_command(text).is_err());}assert!(safe_command("Review this code: $ARGUMENTS").is_ok());}#[test]fn ids_cannot_escape_skill_or_credential_paths(){for id in ["../x","X","a_b","","a b"]{assert!(!safe_id(id));}assert!(safe_id("code-review"));}#[test]fn unknown_versions_fail_closed(){let mut c=Extensions::default();c.version=99;assert!(validate(&mut c).is_err());}}
