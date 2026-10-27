// Email sending for dropped files: Resend API if configured, otherwise default system mail client.
// Port of MailView from IslandViewContent.swift.

use serde::Deserialize;
use tauri::command;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SendEmailRequest {
    pub to: String,
    pub subject: String,
    pub body: String,
    pub file_path: Option<String>,
}

fn percent_encode(s: &str) -> String {
    let mut out = String::new();
    for b in s.as_bytes() {
        match *b {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(*b as char),
            b' ' => out.push_str("%20"),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

#[command]
pub async fn send_email(req: SendEmailRequest) -> Result<(), String> {
    let to = req.to.trim();
    if to.is_empty() {
        return Err("Missing recipient.".into());
    }

    let api_key = crate::secrets::get("resend-api-key");
    let from_addr = crate::secrets::get("resend-from");

    if let Some(key) = api_key {
        // Prefer Resend API
        let from = from_addr.unwrap_or_else(|| "onboarding@resend.dev".into());
        let client = reqwest::Client::new();

        let mut payload = serde_json::json!({
            "from": from,
            "to": [to],
            "subject": if req.subject.trim().is_empty() { "File" } else { req.subject.trim() },
            "text": if req.body.trim().is_empty() { " " } else { req.body.trim() },
        });

        if let Some(ref path) = req.file_path {
            let p = std::path::Path::new(path);
            if p.is_file() {
                if let Ok(bytes) = std::fs::read(p) {
                    let filename = p.file_name().and_then(|n| n.to_str()).unwrap_or("attachment");
                    let b64 = crate::whatsapp::gateway::base64(&bytes);
                    payload["attachments"] = serde_json::json!([{
                        "filename": filename,
                        "content": b64,
                    }]);
                }
            }
        }

        let resp = client
            .post("https://api.resend.com/emails")
            .bearer_auth(key)
            .json(&payload)
            .send()
            .await
            .map_err(|e| format!("Resend error: {e}"))?;

        if !resp.status().is_success() {
            let status = resp.status();
            let body = resp.text().await.unwrap_or_default();
            return Err(format!("Resend error ({status}): {body}"));
        }

        Ok(())
    } else {
        // Fallback: Default email client via mailto: URL
        let mut body_text = req.body.clone();
        if let Some(ref path) = req.file_path {
            if !body_text.is_empty() {
                body_text.push_str("\n\n");
            }
            body_text.push_str(&format!("[Attachment: {}]", path));
        }

        let to_enc = percent_encode(to);
        let subj_enc = percent_encode(if req.subject.trim().is_empty() { "File" } else { req.subject.trim() });
        let body_enc = percent_encode(&body_text);
        let mailto = format!("mailto:{}?subject={}&body={}", to_enc, subj_enc, body_enc);

        crate::platform::open_url(&mailto);
        Ok(())
    }
}
