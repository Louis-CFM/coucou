// Email pills (Gmail + Outlook) over plain IMAP — no OAuth app, no consent
// screen, no API token dance. The user creates an *app password* once
// (Google Account → Security → 2-Step → App passwords;
// Microsoft Account → Security → Advanced → App passwords) and Coucou polls
// INBOX for UNSEEN, reporting the count plus the newest subjects.
//
// Why IMAP and not Graph/Gmail API: both vendors gate API access behind an
// OAuth client registration, which a local companion app cannot ship without
// a backend. App passwords keep every credential on this machine, inside the
// Windows Credential Manager, exactly like every other key here.
//
// The `imap` calls block, so pollers run them inside `spawn_blocking` and the
// async runtime never stalls. Anything that fails (no creds, bad password,
// offline) is a quiet card state, never an exception in the island.

use serde::Serialize;

#[derive(Clone, Copy)]
pub struct Account {
    pub host: &'static str,
    pub email_key: &'static str,
    pub pass_key: &'static str,
}

pub const GMAIL: Account = Account {
    host: "imap.gmail.com",
    email_key: "gmail-email",
    pass_key: "gmail-app-password",
};

pub const OUTLOOK: Account = Account {
    host: "outlook.office365.com",
    email_key: "outlook-email",
    pass_key: "outlook-app-password",
};

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct MailItem {
    pub from: String,
    pub subject: String,
}

#[derive(Serialize, Clone, Default)]
#[serde(rename_all = "camelCase")]
pub struct MailboxState {
    pub unread: u32,
    pub latest: Vec<MailItem>,
}

/// Clear, user-facing failures. Returned as Err so the card can show them.
pub fn check(account: &Account) -> Result<MailboxState, String> {
    let email = crate::secrets::get(account.email_key).filter(|v| !v.is_empty());
    let pass = crate::secrets::get(account.pass_key).filter(|v| !v.is_empty());
    let (email, pass) = match (email, pass) {
        (Some(e), Some(p)) => (e, p),
        _ => return Err("missing".into()),
    };

    let tls = native_tls::TlsConnector::new().map_err(|e| format!("TLS: {e}"))?;
    let client =
        imap::connect((account.host, 993), account.host, &tls).map_err(|e| format!("connect: {e}"))?;
    // NOTE: login fails with (Error, Client) — the tuple has no Display.
    let mut session = client
        .login(&email, &pass)
        .map_err(|(e, _)| format!("login failed — check the app password ({e:?})"))?;

    let result = (|| {
        session.select("INBOX").map_err(|e| format!("inbox: {e}"))?;
        let unseen = session.search("UNSEEN").map_err(|e| format!("search: {e}"))?;

        // Subjects: prefer the newest unseen, else the newest overall.
        // Sequence numbers ascend with arrival, so larger == newer.
        let mut ids: Vec<u32> = unseen.iter().copied().collect();
        if ids.len() < 3 {
            let all = session.search("ALL").map_err(|e| format!("search: {e}"))?;
            let mut rest: Vec<u32> = all.difference(&unseen).copied().collect();
            rest.sort_unstable_by(|a, b| b.cmp(a));
            for id in rest.into_iter().take(3 - ids.len()) {
                ids.push(id);
            }
        }
        ids.sort_unstable_by(|a, b| b.cmp(a));
        let ids: Vec<u32> = ids.into_iter().take(3).collect();

        let mut latest = Vec::new();
        if !ids.is_empty() {
            let seq: Vec<String> = ids.iter().map(|i| i.to_string()).collect();
            let fetched = session
                .fetch(seq.join(","), "ENVELOPE")
                .map_err(|e| format!("fetch: {e}"))?;
            // Fetches come back in sequence order; newest first for the card.
            let mut items: Vec<(u32, MailItem)> = Vec::new();
            for msg in fetched.iter() {
                let seq_no = msg.message;
                if let Some(env) = msg.envelope() {
                    let subject = env
                        .subject
                        .as_ref()
                        .map(|s| String::from_utf8_lossy(s).into_owned())
                        .unwrap_or_else(|| "(no subject)".into());
                    let from = env
                        .from
                        .as_ref()
                        .and_then(|addrs| addrs.first())
                        .map(|a| {
                            a.name
                                .as_ref()
                                .map(|n| String::from_utf8_lossy(n).into_owned())
                                .or_else(|| {
                                    a.mailbox.as_ref().map(|m| {
                                        let m = String::from_utf8_lossy(m);
                                        match &a.host {
                                            Some(h) => format!(
                                                "{}@{}",
                                                m,
                                                String::from_utf8_lossy(h)
                                            ),
                                            None => m.into_owned(),
                                        }
                                    })
                                })
                                .unwrap_or_else(|| "?".into())
                        })
                        .unwrap_or_else(|| "?".into());
                    items.push((seq_no, MailItem { from, subject }));
                }
            }
            items.sort_by_key(|(seq, _)| std::cmp::Reverse(*seq));
            latest = items.into_iter().map(|(_, item)| item).collect();
        }

        Ok(MailboxState { unread: unseen.len() as u32, latest })
    })();

    let _ = session.logout();
    result
}
