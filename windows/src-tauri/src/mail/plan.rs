// The chat's mail actions: the plan the AI writes (a ```coucou-mail JSON block in its
// answer), what Coucou tells the AI, and the matching of PDF pages to recipients. Port of
// MailPlan.swift; pure, tested on any machine. Nothing in a plan happens until the user
// clicks Run on its card (mod.rs).

use serde::Serialize;
use serde_json::Value;

use super::triage::{contains_word, normalize, Action};

#[derive(Serialize, Clone, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Outgoing {
    pub to: Vec<String>,
    pub cc: Vec<String>,
    pub subject: String,
    pub body: String,
    /// Forward the attachments of this message (its number in the list sent to the AI).
    pub attachments_from: Option<usize>,
    /// Files on this computer.
    pub files: Vec<String>,
}

#[derive(Serialize, Clone, PartialEq, Eq, Debug)]
pub struct Recipient {
    pub email: String,
    pub name: String,
    /// What the recipient's page holds ("Bordeaux"), and the {key} of the templates.
    pub key: String,
}

/// One message per recipient, each with its own page of a PDF.
#[derive(Serialize, Clone, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Merge {
    pub from_message: Option<usize>,
    /// The PDF among that message's attachments (None: the first PDF).
    pub attachment: Option<String>,
    pub split_pages: bool,
    /// Pages go to the recipient whose key they contain; false: in order.
    pub match_by_key: bool,
    pub recipients: Vec<Recipient>,
    pub subject: String,
    pub body: String,
    /// A PDF on this computer, instead of a message's.
    pub file: Option<String>,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Step {
    Sort(Action, Vec<usize>),
    Reply(usize, String),
    Send(Outgoing),
    Merge(Merge),
    SaveAttachments(usize, String),
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Plan {
    pub summary: String,
    pub steps: Vec<Step>,
}

pub const FENCE: &str = "```coucou-mail";

/// The answer without its plan block, the plan, and why the block could not be read.
pub fn extract(text: &str) -> (String, Option<Plan>, Option<String>) {
    let Some(start) = text.find(FENCE) else { return (text.to_string(), None, None) };
    let after = &text[start + FENCE.len()..];
    let end = after.find("```");
    let json = end.map_or(after, |e| &after[..e]);
    let mut prose = text[..start].to_string();
    if let Some(e) = end {
        prose.push_str(&after[e + 3..]);
    }
    let prose = prose.trim().to_string();
    if end.is_none() {
        return (prose, None, None); // still streaming
    }
    match decode(json) {
        Ok(plan) => (prose, Some(plan), None),
        Err(e) => (prose, None, Some(e)),
    }
}

fn int(v: Option<&Value>) -> Option<usize> {
    match v? {
        Value::Number(n) => n.as_u64().map(|n| n as usize).or_else(|| n.as_f64().map(|f| f as usize)),
        Value::String(s) => s.trim_matches(|c: char| c == '[' || c == ']' || c == ' ').parse().ok(),
        _ => None,
    }
}

fn ints(v: Option<&Value>) -> Vec<usize> {
    match v {
        Some(Value::Array(a)) => a.iter().filter_map(|x| int(Some(x))).collect(),
        other => int(other).into_iter().collect(),
    }
}

fn strings(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::String(s)) => s.split(',').map(|x| x.trim().to_string()).filter(|x| !x.is_empty()).collect(),
        Some(Value::Array(a)) => a.iter().filter_map(|x| x.as_str()).filter(|x| !x.is_empty()).map(String::from).collect(),
        _ => Vec::new(),
    }
}

fn text(a: &Value, key: &str) -> String {
    a.get(key).and_then(Value::as_str).unwrap_or("").to_string()
}

pub fn decode(json: &str) -> Result<Plan, String> {
    let root: Value = serde_json::from_str(json.trim()).map_err(|_| "not a JSON object".to_string())?;
    let list = root.get("actions").and_then(Value::as_array).cloned().unwrap_or_default();
    let mut steps = Vec::new();
    for (i, a) in list.iter().enumerate() {
        let index = i + 1;
        let kind = a.get("type").and_then(Value::as_str).ok_or(format!("action {index} has no type"))?.to_lowercase();
        let need = |key: &str| -> Result<String, String> {
            let v = text(a, key);
            if v.trim().is_empty() { Err(format!("action {index} ({kind}) needs \"{key}\"")) } else { Ok(v) }
        };
        let message = || int(a.get("message")).ok_or(format!("action {index} ({kind}) needs \"message\""));
        let step = match kind.as_str() {
            "flag" | "important" | "junk" | "read" | "mark_read" | "move" => {
                let messages = ints(a.get("messages").or_else(|| a.get("message")));
                if messages.is_empty() {
                    return Err(format!("action {index} ({kind}) needs \"messages\""));
                }
                let action = match kind.as_str() {
                    "junk" => Action::Junk,
                    "read" | "mark_read" => Action::MarkRead,
                    "move" => Action::Move(need("mailbox")?),
                    _ => Action::Important,
                };
                Step::Sort(action, messages)
            }
            "reply" => Step::Reply(message()?, need("body")?),
            "send" => {
                let to = strings(a.get("to"));
                if to.is_empty() {
                    return Err(format!("action {index} (send) needs \"to\""));
                }
                Step::Send(Outgoing {
                    to,
                    cc: strings(a.get("cc")),
                    subject: text(a, "subject"),
                    body: text(a, "body"),
                    attachments_from: int(a.get("attachments_from")),
                    files: strings(a.get("files")),
                })
            }
            "merge" | "mail_merge" => {
                let recipients: Vec<Recipient> = a.get("recipients").and_then(Value::as_array).cloned().unwrap_or_default()
                    .iter()
                    .filter_map(|r| {
                        let email = r.get("email")?.as_str()?.to_string();
                        (!email.is_empty()).then(|| Recipient {
                            email,
                            name: text(r, "name"),
                            key: r.get("key").or_else(|| r.get("city")).and_then(Value::as_str).unwrap_or("").to_string(),
                        })
                    })
                    .collect();
                if recipients.is_empty() {
                    return Err(format!("action {index} (merge) needs \"recipients\""));
                }
                Step::Merge(Merge {
                    from_message: int(a.get("from_message").or_else(|| a.get("message"))),
                    attachment: a.get("attachment").and_then(Value::as_str).map(String::from),
                    split_pages: a.get("split_pages").and_then(Value::as_bool).unwrap_or(true),
                    match_by_key: a.get("match").and_then(Value::as_str).unwrap_or("key").to_lowercase() != "order",
                    recipients,
                    subject: text(a, "subject"),
                    body: text(a, "body"),
                    file: a.get("file").and_then(Value::as_str).map(String::from),
                })
            }
            "save_attachments" | "save" => Step::SaveAttachments(message()?, need("folder")?),
            other => return Err(format!("action {index} has an unknown type \"{other}\"")),
        };
        steps.push(step);
    }
    if steps.is_empty() {
        return Err("no actions".into());
    }
    Ok(Plan { summary: text(&root, "summary"), steps })
}

// ── Mail merge ───────────────────────────────────────────────────────────────

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Assignment {
    pub recipient: Recipient,
    /// The page (0-based) for this recipient, None when none was found.
    pub page: Option<usize>,
    /// More than one page held the key: the first free one was taken.
    pub ambiguous: bool,
}

/// Gives each recipient a page: the one whose text holds its key as a whole word, or the
/// page in the same order. A page goes to one recipient only.
pub fn assign(pages: &[String], recipients: &[Recipient], by_key: bool) -> Vec<Assignment> {
    if !by_key {
        return recipients
            .iter()
            .enumerate()
            .map(|(i, r)| Assignment { recipient: r.clone(), page: (i < pages.len()).then_some(i), ambiguous: false })
            .collect();
    }
    let mut taken = std::collections::HashSet::new();
    recipients
        .iter()
        .map(|r| {
            let key = r.key.trim();
            if key.is_empty() {
                return Assignment { recipient: r.clone(), page: None, ambiguous: false };
            }
            let hits: Vec<usize> = (0..pages.len()).filter(|&p| contains_word(&pages[p], key)).collect();
            let page = hits.iter().copied().find(|p| !taken.contains(p));
            if let Some(p) = page {
                taken.insert(p);
            }
            Assignment { recipient: r.clone(), page, ambiguous: page.is_some() && hits.len() > 1 }
        })
        .collect()
}

/// {name}, {key} (and {city}, {email}) filled in.
pub fn fill(template: &str, r: &Recipient) -> String {
    template
        .replace("{name}", &r.name)
        .replace("{key}", &r.key)
        .replace("{city}", &r.key)
        .replace("{email}", &r.email)
}

/// A file name for a recipient's page: "Plans - Bordeaux.pdf".
pub fn page_file_name(base: &str, key: &str, page: usize) -> String {
    let stem = base.strip_suffix(".pdf").or_else(|| base.strip_suffix(".PDF")).unwrap_or(base);
    let label = if key.is_empty() { format!("p{}", page + 1) } else { key.to_string() };
    let name: String = format!("{stem} - {label}")
        .chars()
        .map(|c| if matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') { '-' } else { c })
        .collect();
    format!("{name}.pdf")
}

/// A plain address check: something@something.something, no spaces.
pub fn valid_address(s: &str) -> bool {
    let t = s.trim();
    let Some(at) = t.find('@') else { return false };
    let domain = &t[at + 1..];
    at > 0 && !t.contains(' ') && domain.contains('.') && !domain.starts_with('.') && !domain.ends_with('.') && !domain.contains('@')
}

// ── What the AI is told ──────────────────────────────────────────────────────

/// Added to the chat's system prompt while the chat's Mail switch is on (same text as the Mac's).
pub const INSTRUCTIONS: &str = "

The user turned on Mail: you can act on their Outlook through Coucou. Their latest messages are listed under their request, each with a number [n]; some come with their text and attachments.
When they ask you to DO something with their mail, answer in one or two short sentences, then give ONE plan in a fenced code block tagged coucou-mail, holding JSON:
{\"summary\": \"what the plan does, in the user's language\", \"actions\": [ ... ]}
Actions:
- {\"type\": \"flag\" | \"junk\" | \"read\" | \"move\", \"messages\": [n, ...], \"mailbox\": \"only for move\"}
- {\"type\": \"reply\", \"message\": n, \"body\": \"...\"} : a reply draft opened in Outlook, not sent
- {\"type\": \"send\", \"to\": [\"address\"], \"cc\": [], \"subject\": \"...\", \"body\": \"...\", \"attachments_from\": n (optional: that message's attachments), \"files\": [\"C:\\\\path\"] (optional)}
- {\"type\": \"merge\", \"from_message\": n, \"attachment\": \"name of a PDF in that message\", \"split_pages\": true, \"match\": \"key\" or \"order\", \"recipients\": [{\"email\": \"...\", \"name\": \"...\", \"key\": \"what is written on their page, like a city\"}], \"subject\": \"... {key} ...\", \"body\": \"Hello {name}, ...\"} : one mail per recipient, each with the PDF page that contains their key (or the page in the same order)
- {\"type\": \"save_attachments\", \"message\": n, \"folder\": \"C:\\\\Users\\\\...\"}
Rules: nothing happens until the user clicks Run under your plan, so never say it is done. Never invent an address: use only addresses the user gave, found in their messages, or in a file they shared. If something is missing (the recipients' addresses, which message), ask instead of writing a plan. A question about their mail gets an answer, without a plan. Plain text bodies, in the user's language.";

pub struct Line {
    pub number: usize,
    pub sender: String,
    pub subject: String,
    /// "2026-10-30 14:05", the computer's local time.
    pub date: String,
    pub unread: bool,
    pub account: String,
    pub attachments: Vec<String>,
    pub text: Option<String>,
}

/// The list sent under the user's request.
pub fn snapshot(lines: &[Line], accounts: &[(String, String)]) -> String {
    let mut out = String::from("\n\n<mail>\n");
    if !accounts.is_empty() {
        let list: Vec<String> = accounts.iter().map(|(n, a)| format!("{n} <{a}>")).collect();
        out += &format!("Accounts: {}\n", list.join(", "));
    }
    for l in lines {
        out += &format!(
            "[{}] {} · {} · {} · from {} · \"{}\"",
            l.number, l.date, if l.unread { "unread" } else { "read" }, l.account, l.sender, l.subject
        );
        if !l.attachments.is_empty() {
            out += &format!(" · attachments: {}", l.attachments.join(", "));
        }
        out.push('\n');
        if let Some(t) = l.text.as_deref().filter(|t| !t.trim().is_empty()) {
            let one: String = t.replace(['\r', '\n'], " ").chars().take(3000).collect();
            out += &format!("    text: {one}\n");
        }
    }
    out += "</mail>";
    out
}

/// The messages a request names (a sender or a subject word of four letters or more),
/// best first: their text goes to the AI.
pub fn mentioned(query: &str, senders: &[String], subjects: &[String], limit: usize) -> Vec<usize> {
    let words: Vec<String> = query
        .split(|c: char| !c.is_alphanumeric() && c != '@' && c != '.')
        .map(normalize)
        .filter(|w| w.chars().count() >= 4)
        .collect();
    if words.is_empty() {
        return Vec::new();
    }
    let mut scored: Vec<(usize, usize)> = senders
        .iter()
        .zip(subjects)
        .enumerate()
        .filter_map(|(i, (s, sub))| {
            let (s, sub) = (normalize(s), normalize(sub));
            let score: usize = words.iter().map(|w| (if s.contains(w) { 2 } else { 0 }) + usize::from(sub.contains(w))).sum();
            (score > 0).then_some((i, score))
        })
        .collect();
    scored.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
    scored.into_iter().take(limit).map(|(i, _)| i).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plans_are_read_from_the_answer() {
        let answer = "Je prépare les envois.\n\n```coucou-mail\n{\"summary\": \"3 mails\", \"actions\": [\n\
            {\"type\": \"junk\", \"messages\": [2, 3]},\n\
            {\"type\": \"move\", \"messages\": 4, \"mailbox\": \"Compta\"},\n\
            {\"type\": \"reply\", \"message\": 1, \"body\": \"Merci !\"},\n\
            {\"type\": \"send\", \"to\": \"a@b.fr, c@d.fr\", \"subject\": \"Hi\", \"body\": \"Yo\", \"attachments_from\": \"5\"},\n\
            {\"type\": \"merge\", \"from_message\": 1, \"attachment\": \"plans.pdf\", \"recipients\": [{\"email\": \"bx@f.fr\", \"name\": \"Léa\", \"key\": \"Bordeaux\"}, {\"email\": \"ly@f.fr\", \"city\": \"Lyon\"}], \"subject\": \"Plan {key}\", \"body\": \"Bonjour {name}\"},\n\
            {\"type\": \"save_attachments\", \"message\": 1, \"folder\": \"C:\\\\Plans\"}\n]}\n```\nClique sur Lancer.";
        let (prose, plan, error) = extract(answer);
        assert_eq!(error, None);
        assert!(prose.starts_with("Je prépare") && prose.ends_with("Clique sur Lancer.") && !prose.contains("coucou-mail"));
        let plan = plan.unwrap();
        assert_eq!(plan.summary, "3 mails");
        assert_eq!(plan.steps[0], Step::Sort(Action::Junk, vec![2, 3]));
        assert_eq!(plan.steps[1], Step::Sort(Action::Move("Compta".into()), vec![4]));
        assert_eq!(plan.steps[2], Step::Reply(1, "Merci !".into()));
        let Step::Send(s) = &plan.steps[3] else { panic!() };
        assert_eq!(s.to, vec!["a@b.fr", "c@d.fr"]);
        assert_eq!(s.attachments_from, Some(5));
        let Step::Merge(m) = &plan.steps[4] else { panic!() };
        assert_eq!(m.recipients[1].key, "Lyon");
        assert!(m.match_by_key && m.split_pages);
        assert_eq!(plan.steps[5], Step::SaveAttachments(1, "C:\\Plans".into()));
        // Still streaming, broken, and an action that does not exist.
        assert_eq!(extract("Ok\n```coucou-mail\n{\"actions\": ["), ("Ok".into(), None, None));
        assert!(extract("```coucou-mail\n{\"actions\": [{\"type\": \"send\"}]}\n```").2.unwrap().contains("needs \"to\""));
        assert!(extract("```coucou-mail\n{\"actions\": [{\"type\": \"delete\", \"messages\": [1]}]}\n```").2.unwrap().contains("unknown type"));
    }

    #[test]
    fn each_recipient_gets_its_page() {
        let pages: Vec<String> = ["Plan — BORDEAUX — RDC", "Plan Lyon 3e", "Plan Bordeaux annexe", "Marseille"].map(String::from).to_vec();
        let r = |e: &str, k: &str| Recipient { email: e.into(), name: e.into(), key: k.into() };
        let rs = vec![r("a@x.fr", "Bordeaux"), r("b@x.fr", "Lyon"), r("c@x.fr", "Nice"), r("d@x.fr", "Bordeaux")];
        let a = assign(&pages, &rs, true);
        assert_eq!(a.iter().map(|x| x.page).collect::<Vec<_>>(), vec![Some(0), Some(1), None, Some(2)]);
        assert!(a[0].ambiguous && !a[1].ambiguous);
        let o = assign(&pages, &[rs.clone(), rs.clone()].concat(), false);
        assert_eq!(o.iter().map(|x| x.page).collect::<Vec<_>>(), vec![Some(0), Some(1), Some(2), Some(3), None, None, None, None]);
        assert_eq!(fill("Plan {key} pour {name}", &rs[0]), "Plan Bordeaux pour a@x.fr");
        assert_eq!(page_file_name("Plans.pdf", "Lyon", 1), "Plans - Lyon.pdf");
        assert_eq!(page_file_name("a:b.pdf", "", 4), "a-b - p5.pdf");
        assert!(valid_address("lea@franchise.fr"));
        for bad in ["lea", "lea@", "@x.fr", "lea@x", "le a@x.fr", "lea@x.fr."] {
            assert!(!valid_address(bad), "{bad}");
        }
    }

    #[test]
    fn the_ai_gets_a_numbered_list() {
        let lines = vec![Line { number: 1, sender: "Martin <m@archi.fr>".into(), subject: "Plans".into(), date: "2026-10-30 09:00".into(),
            unread: true, account: "Pro".into(), attachments: vec!["plans.pdf".into()], text: Some("Voici\nles plans".into()) }];
        let s = snapshot(&lines, &[("Pro".into(), "louis@pro.fr".into())]);
        assert!(s.contains("Accounts: Pro <louis@pro.fr>") && s.contains("[1] 2026-10-30 09:00 · unread"));
        assert!(s.contains("attachments: plans.pdf") && s.contains("text: Voici les plans") && s.ends_with("</mail>"));
        assert!(INSTRUCTIONS.contains("coucou-mail") && INSTRUCTIONS.contains("Never invent an address"));
        let hits = mentioned("le mail de Martin avec les plans", &["Anne <a@x.fr>".into(), "Martin <m@archi.fr>".into(), "Paul".into()],
            &["Plans".into(), "Plans franchisés".into(), "Hello".into()], 3);
        assert_eq!(hits, vec![1, 0]);
    }
}
