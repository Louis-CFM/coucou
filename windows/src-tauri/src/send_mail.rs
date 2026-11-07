// "Send by email" for a file dropped on the island — port of MailView
// (IslandViewContent.swift). Through Resend when its key and sender address are
// set (the file attached); otherwise the default mail app opens, filled in, with
// the file shown in Explorer to attach (Windows has no Apple Mail to script).

use std::path::Path;
use std::time::Duration;

use serde::Serialize;
use serde_json::json;

use crate::i18n::t;

/// Resend's own cap is 40 MB for the whole message once encoded.
const MAX_ATTACHMENT: u64 = 25 * 1024 * 1024;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Sent {
    /// Resend took it.
    Resend,
    /// The mail app was opened; the user sends it there.
    MailApp,
}

/// One address, the way people type them: something@domain.tld, no spaces.
pub fn plausible_address(to: &str) -> bool {
    let to = to.trim();
    let Some((user, domain)) = to.split_once('@') else { return false };
    !user.is_empty()
        && domain.contains('.')
        && !domain.starts_with('.')
        && !domain.ends_with('.')
        && to.len() <= 254
        && !to.chars().any(|c| c.is_whitespace() || matches!(c, ',' | ';' | '<' | '>' | '"'))
        && to.matches('@').count() == 1
}

/// Percent-encoding for a mailto: link (RFC 6068): spaces as %20, not "+".
fn encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

pub fn mailto(to: &str, subject: &str, body: &str) -> String {
    // The address keeps its "@": mail apps read it as is.
    let address = to.trim().split('@').map(encode).collect::<Vec<_>>().join("@");
    format!("mailto:{address}?subject={}&body={}", encode(subject), encode(&body.replace('\n', "\r\n")))
}

/// Only the island's own copy of a dropped file may be attached.
fn dropped_file(path: &str) -> Option<std::path::PathBuf> {
    let p = Path::new(path).canonicalize().ok()?;
    let inbox = crate::files::inbox_dir().canonicalize().ok()?;
    (p.starts_with(&inbox) && p.is_file()).then_some(p)
}

#[tauri::command]
pub async fn mail_send(to: String, subject: String, body: String, path: Option<String>) -> Result<Sent, String> {
    let to = to.trim().to_string();
    if to.is_empty() {
        return Err(t("Missing recipient."));
    }
    if !plausible_address(&to) {
        return Err(t("Invalid address format."));
    }
    let file = path.as_deref().and_then(dropped_file);
    let subject = if subject.trim().is_empty() {
        file.as_ref().and_then(|f| f.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| t("File"))
    } else {
        subject.trim().to_string()
    };

    let key = crate::secrets::get("resend-api-key");
    let from = crate::secrets::get("resend-from");
    match (key, from) {
        (Some(key), Some(from)) => {
            let mut payload = json!({
                "from": from,
                "to": [to],
                "subject": subject,
                "text": if body.is_empty() { " ".to_string() } else { body },
            });
            if let Some(f) = &file {
                let size = std::fs::metadata(f).map(|m| m.len()).unwrap_or(u64::MAX);
                if size > MAX_ATTACHMENT {
                    return Err(t("This file is too large to send by email."));
                }
                let bytes = std::fs::read(f).map_err(|e| e.to_string())?;
                let name = f.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                payload["attachments"] = json!([{ "filename": name, "content": crate::claude::base64_for(&bytes) }]);
            }
            let client = reqwest::Client::builder().timeout(Duration::from_secs(60)).build().unwrap_or_default();
            let res = client
                .post("https://api.resend.com/emails")
                .bearer_auth(key)
                .json(&payload)
                .send()
                .await
                .map_err(|_| t("Resend error — check API key & sender."))?;
            if matches!(res.status().as_u16(), 200 | 201) {
                Ok(Sent::Resend)
            } else {
                crate::log::line(format!("mail: Resend HTTP {}", res.status().as_u16()));
                Err(t("Resend error — check API key & sender."))
            }
        }
        // A key but no sender: say so rather than going around it.
        (Some(_), None) => Err(t("Set sender address in Settings.")),
        _ => {
            crate::platform::open_url(&mailto(&to, &subject, &body));
            if let Some(f) = &file {
                // The mail app can't be handed an attachment by a link: the file, ready to drag in.
                #[cfg(windows)]
                let _ = std::process::Command::new("explorer").arg(format!("/select,{}", f.display())).spawn();
                #[cfg(not(windows))]
                crate::platform::reveal_folder(&f.parent().unwrap_or(f).to_string_lossy());
            }
            Ok(Sent::MailApp)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_address_needs_one_at_and_a_domain() {
        assert!(plausible_address("marie@example.com"));
        assert!(plausible_address("  a.b+c@mail.example.org "));
        assert!(!plausible_address("marie"));
        assert!(!plausible_address("marie@example"));
        assert!(!plausible_address("a@b@example.com"));
        assert!(!plausible_address("marie @example.com"));
    }

    #[test]
    fn mailto_links_encode_everything_but_the_safe_characters() {
        assert_eq!(
            mailto("a@b.co", "Report & notes", "Hi\nthere"),
            "mailto:a@b.co?subject=Report%20%26%20notes&body=Hi%0D%0Athere"
        );
    }
}
