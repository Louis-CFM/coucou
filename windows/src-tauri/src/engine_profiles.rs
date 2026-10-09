// Secret-free engine profiles. Raw API keys remain in Windows Credential Manager.
use std::{collections::BTreeMap, path::PathBuf, sync::Mutex};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use reqwest::Url;
static WRITE: Mutex<()> = Mutex::new(());
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all="camelCase", deny_unknown_fields)]
pub struct Profile {
    pub id: String, pub label: String, pub base_url: String, pub model_id: String,
    pub protocol: String,
    #[serde(default)] pub no_auth: bool,
    #[serde(default)] pub params: BTreeMap<String, Value>,
    #[serde(default)] pub input_usd_per_million: Option<f64>,
    #[serde(default)] pub output_usd_per_million: Option<f64>,
    #[serde(default)] pub cached_input_usd_per_million: Option<f64>,
}
#[derive(Clone, Default, Serialize, Deserialize)]
#[serde(rename_all="camelCase", default)]
pub struct Config { pub profiles: Vec<Profile>, pub active_profile: String, pub workspace: String, pub last_session: Option<String> }
fn file()->PathBuf { crate::settings::config_dir().join("engine-profiles.json") }
pub fn load()->Config { std::fs::read(file()).ok().and_then(|b|serde_json::from_slice(&b).ok()).unwrap_or_default() }
pub fn save(c:&Config)->Result<(),String> {
    let _lock=WRITE.lock().unwrap();let dir=crate::settings::config_dir();crate::platform::ensure_private_dir(&dir).map_err(|_|"Cannot create private settings directory")?;
    let tmp=dir.join("engine-profiles.tmp");std::fs::write(&tmp,serde_json::to_vec_pretty(c).map_err(|_|"Invalid profiles")?).map_err(|_|"Cannot save profiles")?;
    std::fs::rename(&tmp,&file()).map_err(|_|"Cannot replace profiles file".into())
}
pub fn valid_id(id:&str)->bool { !id.is_empty()&&id.len()<=48&&id.bytes().all(|b|b.is_ascii_alphanumeric()||b==b'-'||b==b'_') }
pub fn key_name(id:&str)->String { format!("engine-profile-{id}") }
pub fn normal_url(raw:&str)->Result<String,String>{
    let u=Url::parse(raw.trim()).map_err(|_|"Base URL must be an absolute URL")?;
    let local=matches!(u.host_str(),Some("localhost"|"127.0.0.1"|"::1"));
    if !(u.scheme()=="https"||(u.scheme()=="http"&&local))||!u.username().is_empty()||u.password().is_some()||u.query().is_some()||u.fragment().is_some(){return Err("Use HTTPS, or HTTP only on localhost; no credentials/query/fragment in the URL".into());}
    Ok(u.as_str().trim_end_matches('/').to_string())
}
pub fn validate(p:&mut Profile)->Result<(),String>{
    if !valid_id(&p.id)||p.label.trim().is_empty()||p.label.len()>80||p.model_id.trim().is_empty()||p.model_id.len()>256{return Err("Profile ID, label and model ID are required".into());}
    p.base_url=normal_url(&p.base_url)?;
    if !["openai-compatible","openai-responses","anthropic","google"].contains(&p.protocol.as_str()){return Err("Unsupported provider protocol".into());}
    if p.no_auth&&!matches!(Url::parse(&p.base_url).unwrap().host_str(),Some("localhost"|"127.0.0.1"|"::1")){return Err("No-auth profiles are allowed only for local servers".into());}
    for v in [p.input_usd_per_million,p.output_usd_per_million,p.cached_input_usd_per_million].into_iter().flatten(){if !v.is_finite()||v<0.0||v>1_000_000.0{return Err("Pricing must be a nonnegative finite USD rate".into());}}
    for (k,v) in &p.params {
        let ok=match k.as_str(){"temperature"=>v.as_f64().is_some_and(|n|n.is_finite()&&n>=0.0&&n<=2.0),"topP"=>v.as_f64().is_some_and(|n|n.is_finite()&&n>=0.0&&n<=1.0),"contextWindow"=>v.as_u64().is_some_and(|n|(4096..=2000000).contains(&n)),"maxOutputTokens"=>v.as_u64().is_some_and(|n|(256..=128000).contains(&n)),"reasoningEffort"=>v.as_str().is_some_and(|s|["none","minimal","low","medium","high","xhigh"].contains(&s)),_=>false};
        if !ok{return Err("Use temperature, topP, reasoningEffort, contextWindow or maxOutputTokens; credentials/headers are not allowed".into());}
    } Ok(())
}
#[derive(Serialize,Deserialize)]
struct BoundKey { base_url:String, key:String }
pub fn credential(p:&Profile)->Result<String,String>{
    if p.no_auth{return Ok("nova-local-no-auth".into());}
    let raw=crate::secrets::get(&key_name(&p.id)).ok_or("API key missing for this profile")?;
    let bound:BoundKey=serde_json::from_str(&raw).map_err(|_|"Re-enter this profile's API key")?;
    if bound.base_url!=p.base_url{return Err("Endpoint changed: re-enter the API key before sending it to another host".into());}Ok(bound.key)
}
#[tauri::command]
pub fn engine_config()->Config {load()}
#[tauri::command]
pub fn engine_profile_save(mut profile:Profile,key:Option<String>)->Result<Config,String>{
    crate::engine::settings_editable()?;validate(&mut profile)?;let mut c=load();
    if !c.profiles.iter().any(|p|p.id==profile.id)&&c.profiles.len()>=12{return Err("At most 12 profiles are supported".into());}
    if let Some(key)=key.filter(|k|!k.is_empty()){
        if key.len()>4096||key.chars().any(char::is_control){return Err("Invalid API key".into());}
        crate::secrets::set(&key_name(&profile.id),&serde_json::to_string(&BoundKey{base_url:profile.base_url.clone(),key}).unwrap())?;
    }
    c.profiles.retain(|p|p.id!=profile.id);if c.active_profile.is_empty(){c.active_profile=profile.id.clone();}c.profiles.push(profile);save(&c)?;crate::engine::config_changed();Ok(c)
}
#[tauri::command]
pub fn engine_profile_remove(id:String)->Result<Config,String>{
    crate::engine::settings_editable()?;if !valid_id(&id){return Err("Invalid profile ID".into());}let mut c=load();c.profiles.retain(|p|p.id!=id);crate::secrets::clear(&key_name(&id))?;
    if c.active_profile==id{c.active_profile=c.profiles.first().map(|p|p.id.clone()).unwrap_or_default();}save(&c)?;crate::engine::config_changed();Ok(c)
}
#[tauri::command]
pub fn engine_profile_key_present(id:String)->bool {valid_id(&id)&&crate::secrets::present(&key_name(&id))}
#[cfg(test)] mod tests {
 use super::*;
 #[test]fn credentials_never_belong_in_urls_or_params(){for s in ["http://example.com/v1","https://key@host/v1","https://host/v1?key=x","file:///secret"]{assert!(normal_url(s).is_err());}assert!(normal_url("http://127.0.0.1:1234/v1").is_ok());}
 #[test]fn credential_names_are_bounded(){for id in ["","../key","x y","x:y"]{assert!(!valid_id(id));}assert!(valid_id("provider-1"));}
}

#[tauri::command]
pub fn engine_preferences(workspace:String,active_profile:String)->Result<Config,String>{
 crate::engine::settings_editable()?;
 let mut c=load();
 if !active_profile.is_empty()&&!c.profiles.iter().any(|p|p.id==active_profile){return Err("Choose an existing provider profile".into());}
 let folder=crate::engine::workspace(&workspace)?.to_string_lossy().into_owned();
 if c.workspace!=folder{c.last_session=None;}
 c.workspace=folder;c.active_profile=active_profile;save(&c)?;crate::engine::config_changed();Ok(c)
}
#[tauri::command]
pub fn engine_import_provider(shared:tauri::State<crate::Shared>)->Result<Config,String>{
 crate::engine::settings_editable()?;let s=shared.settings.lock().unwrap().clone();
 let (base,protocol,secret)=match s.chat_provider.as_str(){
 "anthropic"=>("https://api.anthropic.com/v1","anthropic","anthropic-api-key"),
 "openai"=>("https://api.openai.com/v1","openai-compatible","openai-api-key"),
 "openrouter"=>("https://openrouter.ai/api/v1","openai-compatible","openrouter-api-key"),
 "google"=>("https://generativelanguage.googleapis.com/v1beta","google","google-api-key"),
 _=>return Err("Add your local/custom provider using the form below".into())};
 let key=crate::secrets::get(secret).ok_or("No saved API key for this provider; use the form below")?;
 let model=if s.chat_provider=="anthropic"{s.model}else{s.chat_models.get(&s.chat_provider).cloned().unwrap_or_default()};
 engine_profile_save(Profile{id:format!("imported-{}",s.chat_provider),label:s.chat_provider,base_url:base.into(),model_id:model,protocol:protocol.into(),no_auth:false,params:BTreeMap::new(),input_usd_per_million:None,output_usd_per_million:None,cached_input_usd_per_million:None},Some(key))
}
