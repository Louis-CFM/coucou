// Native picker authorizes only files actually selected by the user.
use std::path::{Path,PathBuf};
use serde_json::{json,Value};
use windows::{core::{PCWSTR,PWSTR},Win32::{Foundation::HWND,UI::Controls::Dialogs::{GetOpenFileNameW,OPENFILENAMEW,OFN_EXPLORER,OFN_ALLOWMULTISELECT,OFN_FILEMUSTEXIST,OFN_PATHMUSTEXIST,OFN_NOCHANGEDIR,OFN_DONTADDTORECENT}}};
const MAX_FILE:u64=8*1024*1024;const MAX_TOTAL:u64=16*1024*1024;
fn paths(buffer:&[u16])->Vec<PathBuf>{let mut parts=Vec::new();for p in buffer.split(|c|*c==0){if p.is_empty(){break;}parts.push(String::from_utf16_lossy(p));}match parts.len(){0=>vec![],1=>vec![PathBuf::from(&parts[0])],_=>parts[1..].iter().map(|p|PathBuf::from(&parts[0]).join(p)).collect()}}
fn mime(path:&Path)->Option<&'static str>{match path.extension().and_then(|x|x.to_str()).unwrap_or("").to_lowercase().as_str(){"png"=>Some("image/png"),"jpg"|"jpeg"=>Some("image/jpeg"),"webp"=>Some("image/webp"),"gif"=>Some("image/gif"),"pdf"=>Some("application/pdf"),"txt"|"md"|"json"|"csv"|"tsv"|"log"|"rs"|"ts"|"tsx"|"js"|"jsx"|"py"|"css"|"html"|"xml"|"yaml"|"yml"|"toml"|"ini"|"ps1"|"sql"=>Some("text/plain"),_=>None}}
fn check(paths:&[PathBuf])->Result<(),String>{if paths.len()>5{return Err("Attach at most five files".into());}let mut total=0;for p in paths{if mime(p).is_none(){return Err("Use images, PDF, text or code; export Office documents as PDF first".into());}let m=std::fs::metadata(p).map_err(|_|"Cannot read selected file")?;if !m.is_file()||m.len()>MAX_FILE{return Err("Each attachment must be a regular file smaller than 8 MB".into());}total+=m.len();}if total>MAX_TOTAL{return Err("Attachments together must be smaller than 16 MB".into());}Ok(())}
#[tauri::command]
pub async fn engine_pick_files(app:tauri::AppHandle)->Result<Vec<crate::files::DroppedFile>,String>{
 let owner=crate::island::window(&app).and_then(|w|w.hwnd().ok()).map(|h|h.0 as isize).unwrap_or(0);
 tauri::async_runtime::spawn_blocking(move||{
  let mut buffer=vec![0u16;32768];let filter:Vec<u16>="Images, PDF, text and code\0*.png;*.jpg;*.jpeg;*.webp;*.gif;*.pdf;*.txt;*.md;*.json;*.csv;*.ts;*.js;*.py;*.rs;*.ps1;*.log;*.yaml;*.yml;*.toml;*.css;*.html\0All files\0*.*\0\0".encode_utf16().collect();
  let mut dialog=OPENFILENAMEW::default();dialog.lStructSize=std::mem::size_of::<OPENFILENAMEW>() as u32;dialog.hwndOwner=HWND(owner as _);dialog.lpstrFilter=PCWSTR(filter.as_ptr());dialog.lpstrFile=PWSTR(buffer.as_mut_ptr());dialog.nMaxFile=buffer.len() as u32;dialog.Flags=OFN_EXPLORER|OFN_ALLOWMULTISELECT|OFN_FILEMUSTEXIST|OFN_PATHMUSTEXIST|OFN_NOCHANGEDIR|OFN_DONTADDTORECENT;
  if !unsafe{GetOpenFileNameW(&mut dialog)}.as_bool(){return Ok(vec![]);}
  let chosen=paths(&buffer);check(&chosen)?;let raw:Vec<String>=chosen.iter().map(|p|p.to_string_lossy().into_owned()).collect();crate::files::allow_dropped(raw.iter().cloned());raw.iter().map(|p|crate::files::ingest(p)).collect()
 }).await.map_err(|_|"File picker could not complete".to_string())?
}
pub fn parts(raw:&[String])->Result<Vec<Value>,String>{
 if raw.is_empty(){return Ok(vec![]);}
 let paths:Vec<PathBuf>=raw.iter().map(PathBuf::from).collect();check(&paths)?;
 let inbox=crate::files::inbox_dir().canonicalize().map_err(|_|"Use the + button to add attachments")?;
 paths.into_iter().map(|path|{let p=path.canonicalize().map_err(|_|"Attachment is no longer available")?;if p.parent()!=Some(inbox.as_path()){return Err("Only files explicitly attached through the island may be uploaded".into());}let name=p.file_name().unwrap().to_string_lossy();let kind=mime(&p).unwrap();let url=reqwest::Url::from_file_path(&p).map_err(|_|"Invalid attachment path")?;Ok(json!({"type":"file","mime":kind,"filename":name,"url":url.as_str()}))}).collect()
}
#[cfg(test)]mod tests{use super::*;#[test]fn picker_paths_handle_one_and_many(){let one:Vec<u16>="C:\\Docs\\a.txt\0\0".encode_utf16().collect();assert_eq!(paths(&one),vec![PathBuf::from("C:\\Docs\\a.txt")]);let many:Vec<u16>="C:\\Docs\0a.txt\0b.png\0\0".encode_utf16().collect();assert_eq!(paths(&many).len(),2);}#[test]fn unknown_binary_files_are_not_silently_sent(){assert_eq!(mime(Path::new("photo.PNG")),Some("image/png"));assert!(mime(Path::new("secret.exe")).is_none());assert!(mime(Path::new("report.docx")).is_none());assert!(check(&vec![PathBuf::new();6]).is_err());}}

pub fn transcript_markdown(entry:&Value)->String{
 let title=entry["title"].as_str().unwrap_or("Nova conversation").replace(['\r','\n']," ");let mut out=format!("# {title}\n\n");
 if let Some(messages)=entry["messages"].as_array(){for message in messages{let role=message["info"]["role"].as_str().unwrap_or("assistant");out.push_str(if role=="user"{"## You\n\n"}else{"## Nova\n\n"});if let Some(parts)=message["parts"].as_array(){for p in parts{match p["type"].as_str(){Some("text")=>{out.push_str(p["text"].as_str().unwrap_or(""));out.push_str("\n\n");},Some("tool")=>{let name=p["tool"].as_str().unwrap_or("tool");let status=p["state"]["status"].as_str().unwrap_or("unknown");out.push_str(&format!("Tool: {name} ({status})\n\n"));},Some("file")=>{out.push_str(&format!("Attachment: {}\n\n",p["filename"].as_str().unwrap_or("file")));},_=>{}}}}}}out
}
#[tauri::command]pub async fn engine_export_session(app:tauri::AppHandle,id:String)->Result<Option<String>,String>{
 let entry=crate::engine_history::read(&id)?;let text=transcript_markdown(&entry);let owner=crate::island::window(&app).and_then(|w|w.hwnd().ok()).map(|h|h.0 as isize).unwrap_or(0);
 tauri::async_runtime::spawn_blocking(move||{
  use windows::Win32::UI::Controls::Dialogs::{GetSaveFileNameW,OFN_OVERWRITEPROMPT};
  let mut buffer=vec![0u16;32768];let initial:Vec<u16>="Nova-conversation.md".encode_utf16().collect();buffer[..initial.len()].copy_from_slice(&initial);
  let filter:Vec<u16>="Markdown\0*.md\0\0".encode_utf16().collect();let extension:Vec<u16>="md\0".encode_utf16().collect();let mut dialog=OPENFILENAMEW::default();dialog.lStructSize=std::mem::size_of::<OPENFILENAMEW>()as u32;dialog.hwndOwner=HWND(owner as _);dialog.lpstrFilter=PCWSTR(filter.as_ptr());dialog.lpstrFile=PWSTR(buffer.as_mut_ptr());dialog.nMaxFile=buffer.len()as u32;dialog.lpstrDefExt=PCWSTR(extension.as_ptr());dialog.Flags=OFN_OVERWRITEPROMPT|OFN_PATHMUSTEXIST|OFN_NOCHANGEDIR|OFN_DONTADDTORECENT;
  if !unsafe{GetSaveFileNameW(&mut dialog)}.as_bool(){return Ok(None);}let path=paths(&buffer).into_iter().next().ok_or("Invalid export path")?;std::fs::write(&path,text).map_err(|_|"Cannot save Markdown export")?;Ok(Some(path.to_string_lossy().into_owned()))
 }).await.map_err(|_|"Export picker could not complete".to_string())?
}
#[cfg(test)]mod export_tests{use super::*;#[test]fn markdown_export_keeps_full_text_and_never_embeds_attachment_bytes(){let v=json!({"title":"Example\nTitle","messages":[{"info":{"role":"user"},"parts":[{"type":"text","text":"hello"},{"type":"file","filename":"photo.png","url":"data:SECRET"}]}]});let text=transcript_markdown(&v);assert!(text.contains("hello"));assert!(text.contains("photo.png"));assert!(!text.contains("SECRET"));}}
