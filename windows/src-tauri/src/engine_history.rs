// Secret-redacted transcript cache for offline browse/search; OpenCode owns full sessions.
use std::{path::PathBuf,sync::Mutex,time::{SystemTime,UNIX_EPOCH}};
use serde_json::{json,Value};
static WRITE:Mutex<()>=Mutex::new(());
fn dir()->PathBuf{crate::settings::local_dir().join("history")}
fn valid(id:&str)->bool{id.starts_with("ses_")&&id.len()<100&&id.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'_')}
fn file(id:&str)->Result<PathBuf,String>{if !valid(id){return Err("Invalid conversation ID".into());}Ok(dir().join(format!("{id}.json")))}
pub fn save(id:&str,workspace:&str,messages:Value)->Result<(),String>{
 let path=file(id)?;let _lock=WRITE.lock().unwrap();crate::platform::ensure_private_dir(&dir()).map_err(|_|"Cannot create history folder")?;
 let title=messages.as_array().and_then(|a|a.iter().find(|m|m["info"]["role"]=="user")).and_then(|m|m["parts"].as_array()).and_then(|a|a.iter().find(|p|p["type"]=="text")).and_then(|p|p["text"].as_str()).unwrap_or("Conversation").chars().take(90).collect::<String>();
 let value=json!({"id":id,"title":title,"workspace":workspace,"updated":SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis(),"messages":messages});
 let temp=path.with_extension("tmp");std::fs::write(&temp,serde_json::to_vec(&value).map_err(|_|"Invalid transcript")?).map_err(|_|"Cannot save transcript")?;std::fs::rename(temp,path).map_err(|_|"Cannot replace transcript".into())
}
pub fn read(id:&str)->Result<Value,String>{let bytes=std::fs::read(file(id)?).map_err(|_|"Conversation cache unavailable")?;serde_json::from_slice(&bytes).map_err(|_|"Conversation cache damaged".into())}
#[tauri::command]pub fn engine_history_read(id:String)->Result<Value,String>{read(&id)}
#[tauri::command]pub fn engine_history_list(query:String)->Vec<Value>{let query=query.to_lowercase();let mut rows=Vec::new();if let Ok(files)=std::fs::read_dir(dir()){for entry in files.flatten(){let path=entry.path();let id=path.file_stem().and_then(|p|p.to_str()).unwrap_or("");if let Ok(mut v)=read(id){if query.is_empty()||v.to_string().to_lowercase().contains(&query){if let Some(o)=v.as_object_mut(){o.remove("messages");}rows.push(v);}}}}rows.sort_by(|a,b|b["updated"].as_u64().cmp(&a["updated"].as_u64()));rows.truncate(100);rows}
#[cfg(test)]mod tests{use super::*;#[test]fn conversation_ids_cannot_escape_storage(){for id in ["../secret","ses_/../../x","ses_a.json","x",""]{assert!(file(id).is_err());}assert!(file("ses_123ABC").is_ok());}}
