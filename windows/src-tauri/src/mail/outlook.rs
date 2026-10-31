// Classic Outlook on Windows, driven through its own COM objects by a small PowerShell
// script: the Windows counterpart of Apple Mail's AppleScript on the Mac (MailController.swift).
//
// Coucou attaches to the Outlook already open (GetActiveObject) and never starts it. No
// sign-in, no app registration, no admin consent: it is the user's Outlook, on the user's PC.
// The new Outlook for Windows has no COM objects, so it is not reached this way.
//
// The script builders are pure and tested; `run` (Windows only) writes the script to a
// temporary .ps1 and runs Windows PowerShell on it, without a console window.

use serde::{Deserialize, Serialize};

use super::triage::{Action, Filter, Query};

/// One message of an inbox, as the list script reports it.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    /// Outlook's EntryID: with the store's id, finds the message again.
    pub entry_id: String,
    pub store_id: String,
    /// The store's name ("louis@company.com"): what the rules call the account.
    pub account: String,
    #[serde(default)]
    pub sender_name: String,
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub subject: String,
    /// Milliseconds since 1970.
    pub date: i64,
    #[serde(default)]
    pub unread: bool,
    #[serde(default)]
    pub flagged: bool,
    /// The date in the computer's time, for the AI ("2026-10-30 14:05").
    #[serde(default)]
    pub local: String,
}

impl Message {
    pub fn id(&self) -> String {
        format!("{}/{}", self.store_id, self.entry_id)
    }
}

#[derive(Deserialize, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Listing {
    #[serde(default)]
    pub unread: i64,
    #[serde(default)]
    pub messages: Vec<Message>,
}

/// A string inside PowerShell single quotes (nothing is expanded there; ' is doubled).
pub fn ps(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// Attaches to the running Outlook, or prints {"error":"notRunning"} and stops. JSON goes
/// out as UTF-8 so names and subjects keep their accents.
const PRELUDE: &str = r#"$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
try { $ol = [System.Runtime.InteropServices.Marshal]::GetActiveObject('Outlook.Application') }
catch { Write-Output '{"error":"notRunning"}'; exit 0 }
$ns = $ol.GetNamespace('MAPI')
function Coucou-Address($i) {
  try {
    if ($i.SenderEmailType -eq 'EX') {
      $u = $i.Sender.GetExchangeUser()
      if ($u) { return $u.PrimarySmtpAddress }
    }
  } catch {}
  return [string]$i.SenderEmailAddress
}
function Coucou-Row($i, $store) {
  [pscustomobject]@{
    entryId = $i.EntryID; storeId = $store.StoreID; account = $store.DisplayName
    senderName = [string]$i.SenderName; address = (Coucou-Address $i); subject = [string]$i.Subject
    date = [long](([DateTimeOffset]$i.ReceivedTime).ToUnixTimeMilliseconds())
    unread = [bool]$i.UnRead; flagged = ($i.FlagStatus -eq 2)
    local = $i.ReceivedTime.ToString('yyyy-MM-dd HH:mm')
  }
}
function Coucou-Inboxes {
  foreach ($s in $ns.Stores) {
    try { $f = $s.GetDefaultFolder(6); if ($f) { [pscustomobject]@{ store = $s; inbox = $f } } } catch {}
  }
}
function Coucou-Item($entryId, $storeId) { $ns.GetItemFromID($entryId, $storeId) }
"#;

fn script(body: &str) -> String {
    format!("{PRELUDE}\n{body}\n")
}

/// The unread count and the newest `per_inbox` messages of every account's inbox.
pub fn list_script(per_inbox: usize) -> String {
    script(&format!(
        r#"$rows = @(); $unread = 0
foreach ($b in (Coucou-Inboxes)) {{
  try {{ $unread += $b.inbox.UnReadItemCount }} catch {{}}
  $items = $b.inbox.Items
  $items.Sort('[ReceivedTime]', $true)
  $n = 0; $i = $items.GetFirst()
  while ($i -ne $null -and $n -lt {per_inbox}) {{
    if ($i.Class -eq 43) {{ $rows += (Coucou-Row $i $b.store); $n++ }}
    $i = $items.GetNext()
  }}
}}
[pscustomobject]@{{ unread = $unread; messages = @($rows) }} | ConvertTo-Json -Depth 4 -Compress"#
    ))
}

/// A DASL text test: `field LIKE '%value%'` (' doubled, % removed from the value).
fn like(field: &str, value: &str) -> String {
    let v = value.replace('%', "").replace('\'', "''");
    format!("\"{field}\" LIKE '%{v}%'")
}

const SUBJECT: &str = "urn:schemas:httpmail:subject";
const FROM_NAME: &str = "urn:schemas:httpmail:fromname";
const FROM_EMAIL: &str = "urn:schemas:httpmail:fromemail";

/// The `@SQL=` filter for a search and a quick filter, None when there is nothing to test.
pub fn dasl(q: &Query, filter: Filter) -> Option<String> {
    let mut parts = Vec::new();
    for w in &q.words {
        parts.push(format!("({} OR {} OR {})", like(SUBJECT, w), like(FROM_NAME, w), like(FROM_EMAIL, w)));
    }
    for f in &q.from {
        parts.push(format!("({} OR {})", like(FROM_NAME, f), like(FROM_EMAIL, f)));
    }
    for s in &q.subject {
        parts.push(like(SUBJECT, s));
    }
    match filter {
        Filter::All => {}
        Filter::Unread => parts.push("\"urn:schemas:httpmail:read\" = 0".into()),
        Filter::Flagged => parts.push("\"http://schemas.microsoft.com/mapi/proptag/0x10900003\" = 2".into()),
        Filter::Today => parts.push("%today(\"urn:schemas:httpmail:datereceived\")%".into()),
    }
    (!parts.is_empty()).then(|| format!("@SQL={}", parts.join(" AND ")))
}

/// Messages of every inbox matching a `dasl` filter, newest first, `limit` per inbox.
pub fn search_script(filter: &str, limit: usize) -> String {
    script(&format!(
        r#"$rows = @()
foreach ($b in (Coucou-Inboxes)) {{
  try {{
    $found = $b.inbox.Items.Restrict({filter})
    $found.Sort('[ReceivedTime]', $true)
    $n = 0; $i = $found.GetFirst()
    while ($i -ne $null -and $n -lt {limit}) {{
      if ($i.Class -eq 43) {{ $rows += (Coucou-Row $i $b.store); $n++ }}
      $i = $found.GetNext()
    }}
  }} catch {{}}
}}
[pscustomobject]@{{ unread = 0; messages = @($rows) }} | ConvertTo-Json -Depth 4 -Compress"#,
        filter = ps(filter)
    ))
}

/// What the action does to `$i` in its store `$st`. Moving returns the message's new
/// EntryID (Outlook gives a moved message a new one), which the journal keeps for Undo.
fn apply(action: &Action) -> String {
    match action {
        Action::Junk => "$m = $i.Move($st.GetDefaultFolder(23)); $new = $m.EntryID".into(),
        Action::Important => "$i.MarkAsTask(4); $i.Save(); $new = $i.EntryID".into(),
        Action::MarkRead => "$i.UnRead = $false; $i.Save(); $new = $i.EntryID".into(),
        Action::Move(name) => format!(
            r#"$inbox = $st.GetDefaultFolder(6); $dest = $null
try {{ $dest = $inbox.Folders.Item({n}) }} catch {{}}
if (-not $dest) {{ try {{ $dest = $st.GetRootFolder().Folders.Item({n}) }} catch {{}} }}
if (-not $dest) {{ $dest = $inbox.Folders.Add({n}) }}
$m = $i.Move($dest); $new = $m.EntryID"#,
            n = ps(name)
        ),
    }
}

/// Sorts one message; prints {"entryId": its id afterwards}.
pub fn apply_script(entry_id: &str, store_id: &str, action: &Action) -> String {
    script(&format!(
        r#"$i = Coucou-Item {e} {s}
$st = $ns.GetStoreFromID({s})
{body}
[pscustomobject]@{{ entryId = $new }} | ConvertTo-Json -Compress"#,
        e = ps(entry_id),
        s = ps(store_id),
        body = apply(action)
    ))
}

/// Puts back a message the journal shows as sorted (by the EntryID it had afterwards).
pub fn undo_script(entry_id: &str, store_id: &str, action: &Action) -> String {
    let body = match action {
        Action::Junk | Action::Move(_) => "$null = $i.Move($st.GetDefaultFolder(6))",
        Action::Important => "$i.ClearTaskFlag(); $i.Save()",
        Action::MarkRead => "$i.UnRead = $true; $i.Save()",
    };
    script(&format!(
        r#"$i = Coucou-Item {e} {s}
$st = $ns.GetStoreFromID({s})
{body}
Write-Output '{{"ok":true}}'"#,
        e = ps(entry_id),
        s = ps(store_id)
    ))
}

pub fn unflag_script(entry_id: &str, store_id: &str) -> String {
    script(&format!(
        "$i = Coucou-Item {} {}\n$i.ClearTaskFlag(); $i.Save()\nWrite-Output '{{\"ok\":true}}'",
        ps(entry_id),
        ps(store_id)
    ))
}

/// The message's text (`limit` characters) and its attachments' names.
pub fn detail_script(entry_id: &str, store_id: &str, limit: usize) -> String {
    script(&format!(
        r#"$i = Coucou-Item {e} {s}
$body = [string]$i.Body
if ($body.Length -gt {limit}) {{ $body = $body.Substring(0, {limit}) }}
$names = @(); foreach ($a in $i.Attachments) {{ $names += [string]$a.FileName }}
[pscustomobject]@{{ text = $body; attachments = @($names) }} | ConvertTo-Json -Depth 3 -Compress"#,
        e = ps(entry_id),
        s = ps(store_id)
    ))
}

/// Opens the message, or a reply to it with `body` on top, in Outlook's own window. Nothing
/// is sent: the user sends from Outlook.
pub fn open_script(entry_id: &str, store_id: &str, reply_body: Option<&str>) -> String {
    let body = match reply_body {
        None => "$i.Display()".to_string(),
        Some("") => "$r = $i.Reply(); $r.Display()".to_string(),
        Some(text) => format!("$r = $i.Reply(); $r.Body = {} + \"`r`n`r`n\" + $r.Body; $r.Display()", ps(text)),
    };
    script(&format!(
        "$i = Coucou-Item {} {}\n{body}\nWrite-Output '{{\"ok\":true}}'",
        ps(entry_id),
        ps(store_id)
    ))
}

/// Saves a message's attachments (only `only` when given) in `folder`; prints their names.
pub fn save_attachments_script(entry_id: &str, store_id: &str, folder: &str, only: Option<&str>) -> String {
    let test = only.map_or("$true".to_string(), |n| format!("$a.FileName -eq {}", ps(n)));
    script(&format!(
        r#"$i = Coucou-Item {e} {s}
$dir = {d}
$null = New-Item -ItemType Directory -Force -Path $dir
$saved = @()
foreach ($a in $i.Attachments) {{
  if ({test}) {{ $a.SaveAsFile((Join-Path $dir $a.FileName)); $saved += [string]$a.FileName }}
}}
[pscustomobject]@{{ saved = @($saved) }} | ConvertTo-Json -Depth 3 -Compress"#,
        e = ps(entry_id),
        s = ps(store_id),
        d = ps(folder)
    ))
}

/// Sends one message from Outlook (the default account), attachments as file paths.
pub fn send_script(to: &[String], cc: &[String], subject: &str, body: &str, attachments: &[String]) -> String {
    let mut s = String::from("$m = $ol.CreateItem(0)\n");
    s += &format!("$m.To = {}\n", ps(&to.join("; ")));
    if !cc.is_empty() {
        s += &format!("$m.CC = {}\n", ps(&cc.join("; ")));
    }
    s += &format!("$m.Subject = {}\n$m.Body = {}\n", ps(subject), ps(body));
    for a in attachments {
        s += &format!("$null = $m.Attachments.Add({})\n", ps(a));
    }
    s += "$m.Send()\nWrite-Output '{\"ok\":true}'";
    script(&s)
}

/// Every account: its name and address.
pub fn accounts_script() -> String {
    script(
        r#"$rows = @()
foreach ($a in $ns.Accounts) { $rows += [pscustomobject]@{ name = [string]$a.DisplayName; address = [string]$a.SmtpAddress } }
[pscustomobject]@{ accounts = @($rows) } | ConvertTo-Json -Depth 3 -Compress"#,
    )
}

#[derive(Debug, PartialEq, Eq)]
#[cfg_attr(not(windows), allow(dead_code))]
pub enum RunError {
    /// Outlook is not open (or is the new Outlook, which has no COM objects).
    NotRunning,
    /// Not on Windows.
    Unsupported,
    Failed(String),
}

impl std::fmt::Display for RunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunError::NotRunning => write!(f, "Outlook is not open"),
            RunError::Unsupported => write!(f, "Outlook is only reached on Windows"),
            RunError::Failed(e) => write!(f, "{e}"),
        }
    }
}

/// Reads a script's output: its JSON, or why it failed.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn parse_output(stdout: &str, stderr: &str, ok: bool) -> Result<serde_json::Value, RunError> {
    let text = stdout.trim().trim_start_matches('\u{feff}');
    if let Some(line) = text.lines().rev().find(|l| l.trim_start().starts_with('{')) {
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(line.trim()) {
            if v.get("error").and_then(|e| e.as_str()) == Some("notRunning") {
                return Err(RunError::NotRunning);
            }
            return Ok(v);
        }
    }
    let why = stderr.lines().find(|l| !l.trim().is_empty()).unwrap_or(if ok { "no answer" } else { "failed" });
    Err(RunError::Failed(why.trim().to_string()))
}

#[cfg(windows)]
static SCRIPT_SEQ: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

#[cfg(windows)]
pub fn unique_script_path() -> std::path::PathBuf {
    use std::sync::atomic::Ordering;
    use std::time::{SystemTime, UNIX_EPOCH};
    let pid = std::process::id();
    let seq = SCRIPT_SEQ.fetch_add(1, Ordering::Relaxed);
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.subsec_nanos())
        .unwrap_or(0);
    std::env::temp_dir().join(format!("coucou-outlook-{pid}-{seq}-{nanos}.ps1"))
}

#[cfg(windows)]
pub struct TempScript(pub std::path::PathBuf);

#[cfg(windows)]
impl Drop for TempScript {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// Runs a script with Windows PowerShell, `timeout` at most.
#[cfg(windows)]
pub async fn run(source: String, timeout: std::time::Duration) -> Result<serde_json::Value, RunError> {
    tauri::async_runtime::spawn_blocking(move || {
        use std::io::Write;
        use std::process::{Command, Stdio};
        let path = unique_script_path();
        let _guard = TempScript(path.clone());
        let mut file = std::fs::File::create(&path).map_err(|e| RunError::Failed(e.to_string()))?;
        // A BOM so Windows PowerShell 5.1 reads the script as UTF-8 (names, accents).
        file.write_all(b"\xEF\xBB\xBF")
            .and_then(|_| file.write_all(source.as_bytes()))
            .map_err(|e| RunError::Failed(e.to_string()))?;
        drop(file);
        let mut cmd = Command::new("powershell.exe");
        cmd.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File"])
            .arg(&path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        crate::platform::no_console(&mut cmd);
        let child = cmd.spawn().map_err(|e| RunError::Failed(e.to_string()))?;
        let out = wait(child, timeout)?;
        drop(_guard);
        parse_output(&String::from_utf8_lossy(&out.stdout), &String::from_utf8_lossy(&out.stderr), out.status.success())
    })
    .await
    .unwrap_or_else(|e| Err(RunError::Failed(e.to_string())))
}

#[cfg(windows)]
fn wait(mut child: std::process::Child, timeout: std::time::Duration) -> Result<std::process::Output, RunError> {
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(_)) => return child.wait_with_output().map_err(|e| RunError::Failed(e.to_string())),
            Ok(None) if start.elapsed() < timeout => std::thread::sleep(std::time::Duration::from_millis(50)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(RunError::Failed("Outlook did not answer in time".into()));
            }
            Err(e) => return Err(RunError::Failed(e.to_string())),
        }
    }
}

#[cfg(not(windows))]
pub async fn run(_source: String, _timeout: std::time::Duration) -> Result<serde_json::Value, RunError> {
    Err(RunError::Unsupported)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quotes_never_break_out() {
        assert_eq!(ps("it's"), "'it''s'");
        assert_eq!(ps("$env:x `n"), "'$env:x `n'", "single quotes expand nothing");
    }

    #[test]
    fn the_list_attaches_and_never_starts_outlook() {
        let s = list_script(12);
        assert!(s.contains("GetActiveObject('Outlook.Application')"));
        assert!(!s.contains("New-Object -ComObject"), "never starts Outlook");
        assert!(s.contains("$n -lt 12") && s.contains("GetDefaultFolder(6)") && s.contains("ConvertTo-Json"));
    }

    #[test]
    fn search_filters_are_dasl() {
        let q = Query::parse("de:dupont objet:\"devis mai\" facture");
        let f = dasl(&q, Filter::Unread).unwrap();
        assert!(f.starts_with("@SQL="));
        assert!(f.contains("\"urn:schemas:httpmail:subject\" LIKE '%facture%'"));
        assert!(f.contains("\"urn:schemas:httpmail:fromname\" LIKE '%dupont%'"));
        assert!(f.contains("\"urn:schemas:httpmail:subject\" LIKE '%devis mai%'"));
        assert!(f.ends_with("\"urn:schemas:httpmail:read\" = 0"));
        assert_eq!(dasl(&Query::default(), Filter::All), None);
        assert!(dasl(&Query::default(), Filter::Today).unwrap().contains("%today("));
        let tricky = dasl(&Query::parse("l'été"), Filter::All).unwrap();
        assert!(tricky.contains("'%l''été%'"));
        // The filter goes into the script as a PowerShell string: quotes doubled again.
        assert!(search_script(&tricky, 30).contains("Restrict('@SQL="));
        assert!(search_script(&tricky, 30).contains("l''''été"));
    }

    #[test]
    fn actions_move_flag_and_never_delete() {
        let junk = apply_script("E1", "S1", &Action::Junk);
        assert!(junk.contains("GetItemFromID($entryId, $storeId)") || junk.contains("Coucou-Item 'E1' 'S1'"));
        assert!(junk.contains("GetDefaultFolder(23)") && junk.contains("$new = $m.EntryID"));
        assert!(apply_script("E", "S", &Action::Important).contains("MarkAsTask(4)"));
        let mv = apply_script("E", "S", &Action::Move("Compta".into()));
        assert!(mv.contains("Folders.Item('Compta')") && mv.contains("Folders.Add('Compta')"));
        for a in [Action::Junk, Action::Important, Action::MarkRead, Action::Move("X".into())] {
            let s = apply_script("E", "S", &a) + &undo_script("E", "S", &a);
            assert!(!s.contains(".Delete("), "Coucou never deletes a message");
        }
        assert!(undo_script("E", "S", &Action::Junk).contains("Move($st.GetDefaultFolder(6))"));
        assert!(undo_script("E", "S", &Action::Important).contains("ClearTaskFlag()"));
    }

    #[test]
    fn sending_and_drafts() {
        let s = send_script(&["a@x.fr".into(), "b@x.fr".into()], &[], "Plan 'Lyon'", "Bonjour", &["C:\\p 1.pdf".into()]);
        assert!(s.contains("$m.To = 'a@x.fr; b@x.fr'"));
        assert!(s.contains("$m.Subject = 'Plan ''Lyon'''"));
        assert!(s.contains("$m.Attachments.Add('C:\\p 1.pdf')") && s.contains("$m.Send()"));
        let r = open_script("E", "S", Some("Merci"));
        assert!(r.contains("$i.Reply()") && r.contains("Display()") && !r.contains("Send()"));
        assert!(save_attachments_script("E", "S", "C:\\t", Some("plans.pdf")).contains("$a.FileName -eq 'plans.pdf'"));
    }

    #[test]
    fn outputs_are_read() {
        assert_eq!(parse_output("{\"error\":\"notRunning\"}", "", true), Err(RunError::NotRunning));
        let v = parse_output("\u{feff}WARNING x\n{\"unread\":3,\"messages\":[]}\n", "", true).unwrap();
        assert_eq!(v["unread"], 3);
        assert_eq!(parse_output("", "Exception: boom\n", false), Err(RunError::Failed("Exception: boom".into())));
        let listing: Listing = serde_json::from_str(
            r#"{"unread":2,"messages":[{"entryId":"E","storeId":"S","account":"a@b.fr","senderName":"Paul","address":"p@c.fr","subject":"Hi","date":1700000000000,"unread":true,"flagged":false}]}"#,
        ).unwrap();
        assert_eq!(listing.messages[0].id(), "S/E");
        assert!(listing.messages[0].unread);
    }

    #[test]
    #[cfg(windows)]
    fn unique_script_paths_are_distinct_and_clean_up() {
        let mut paths = std::collections::HashSet::new();
        for _ in 0..100 {
            let p = unique_script_path();
            assert!(paths.insert(p), "paths must be strictly unique");
        }
        let test_path = unique_script_path();
        std::fs::write(&test_path, b"test").unwrap();
        assert!(test_path.exists());
        {
            let _guard = TempScript(test_path.clone());
        }
        assert!(!test_path.exists(), "TempScript must delete the file on drop");
    }
}
