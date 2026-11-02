// Mail triage: the rules, the banned words and the VIPs of the Mail section, and the
// search of the Mail pill. Port of MailTriage.swift; pure, so it is tested on any machine.

use serde::{Deserialize, Serialize};

/// What a rule looks at. `contains` everywhere, ignoring case and accents; `domain` is the
/// end of the sender's address.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub enum Field {
    Sender,
    Domain,
    Subject,
    Text,
    Account,
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug)]
pub struct Condition {
    pub field: Field,
    pub value: String,
}

/// What a rule does to a message. Coucou never deletes a message.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Hash, Debug)]
#[serde(tag = "kind", content = "mailbox", rename_all = "camelCase")]
pub enum Action {
    Junk,
    Important,
    MarkRead,
    Move(String),
}

#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Rule {
    pub id: String,
    pub name: String,
    #[serde(default = "yes")]
    pub enabled: bool,
    pub conditions: Vec<Condition>,
    pub action: Action,
}

fn yes() -> bool {
    true
}

/// Everything the Mail section lets the user set for the triage.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Sort the messages that arrive from now on.
    pub auto_sort: bool,
    /// When the automatic sorting was turned on (ms since 1970): older messages are never touched.
    pub auto_sort_since: Option<i64>,
    /// Words, phrases or addresses: a message holding one goes to Junk.
    pub banned: Vec<String>,
    /// Addresses or domains ("@client.fr"): always important, never moved by a rule.
    pub vip: Vec<String>,
    pub rules: Vec<Rule>,
}

/// What the triage knows about a message when it decides.
#[derive(Clone, Debug, Default)]
pub struct Facts {
    pub sender_name: String,
    pub address: String,
    pub subject: String,
    pub account: String,
    /// The text, when it was read (banned words and text rules need it).
    pub text: Option<String>,
}

impl Facts {
    /// "Name <address>", what the sender rules look at.
    pub fn sender(&self) -> String {
        if self.sender_name.is_empty() {
            self.address.clone()
        } else {
            format!("{} <{}>", self.sender_name, self.address)
        }
    }
}

/// Why a message was sorted the way it was: shown in the journal.
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Debug)]
#[serde(tag = "kind", content = "value", rename_all = "camelCase")]
pub enum Reason {
    Vip(String),
    Banned(String),
    Rule(String),
    /// The user's own click in the Mail pill or the chat.
    Manual,
}

#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Decision {
    pub action: Action,
    pub reason: Reason,
}

/// Lowercased, without accents: "Réunion" and "reunion" are the same word.
pub fn normalize(s: &str) -> String {
    s.trim().chars().flat_map(|c| c.to_lowercase()).map(fold).collect()
}

/// The accented Latin letters most mail is written with, without their accent.
fn fold(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ã' | 'ä' | 'å' | 'ā' | 'ă' | 'ą' => 'a',
        'ç' | 'ć' | 'č' => 'c',
        'ď' | 'đ' => 'd',
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ė' | 'ę' | 'ě' => 'e',
        'ğ' => 'g',
        'ì' | 'í' | 'î' | 'ï' | 'ī' | 'į' | 'ı' => 'i',
        'ł' | 'ľ' => 'l',
        'ñ' | 'ń' | 'ň' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ö' | 'ø' | 'ō' | 'ő' => 'o',
        'ř' => 'r',
        'ś' | 'š' | 'ş' | 'ș' => 's',
        'ť' | 'ţ' | 'ț' => 't',
        'ù' | 'ú' | 'û' | 'ü' | 'ū' | 'ů' | 'ű' | 'ų' => 'u',
        'ý' | 'ÿ' => 'y',
        'ź' | 'ż' | 'ž' => 'z',
        other => other,
    }
}

/// `needle` in `haystack` as a whole word or phrase ("sale" is not found in "salesforce").
/// An address or anything with "@" or "." is matched as plain text.
pub fn contains_word(haystack: &str, needle: &str) -> bool {
    let h = normalize(haystack);
    let n = normalize(needle);
    if n.is_empty() {
        return false;
    }
    if n.contains('@') || n.contains('.') {
        return h.contains(&n);
    }
    let edge = |c: Option<char>| c.map_or(true, |c| !c.is_alphanumeric());
    let mut start = 0;
    while let Some(pos) = h[start..].find(&n) {
        let at = start + pos;
        let before = h[..at].chars().next_back();
        let after = h[at + n.len()..].chars().next();
        if edge(before) && edge(after) {
            return true;
        }
        start = at + h[at..].chars().next().map_or(1, char::len_utf8);
    }
    false
}

fn domain_matches(address: &str, domain: &str) -> bool {
    let domain = domain.strip_prefix('@').unwrap_or(domain);
    address.ends_with(&format!("@{domain}")) || address.ends_with(&format!(".{domain}"))
}

pub fn matches(c: &Condition, f: &Facts) -> bool {
    let v = normalize(&c.value);
    if v.is_empty() {
        return false;
    }
    match c.field {
        Field::Sender => normalize(&f.sender()).contains(&v),
        Field::Domain => domain_matches(&normalize(&f.address), &v),
        Field::Subject => normalize(&f.subject).contains(&v),
        Field::Text => f.text.as_deref().is_some_and(|t| normalize(t).contains(&v)),
        Field::Account => normalize(&f.account).contains(&v),
    }
}

/// A VIP entry: a whole address, or a domain ("@client.fr" or "client.fr").
pub fn vip_hit(f: &Facts, vip: &[String]) -> Option<String> {
    let address = normalize(&f.address);
    vip.iter()
        .find(|entry| {
            let e = normalize(entry);
            if e.is_empty() {
                false
            } else if e.contains('@') && !e.starts_with('@') {
                address == e
            } else {
                domain_matches(&address, &e)
            }
        })
        .cloned()
}

/// The first banned word found in the sender, the subject or the text.
pub fn banned_hit(f: &Facts, banned: &[String]) -> Option<String> {
    let sender = f.sender();
    banned
        .iter()
        .filter(|w| !normalize(w).is_empty())
        .find(|w| {
            contains_word(&sender, w)
                || contains_word(&f.subject, w)
                || f.text.as_deref().is_some_and(|t| contains_word(t, w))
        })
        .cloned()
}

/// Whether deciding needs the message's text (a banned word or a text rule).
pub fn needs_text(s: &Settings) -> bool {
    !s.banned.is_empty()
        || s.rules.iter().any(|r| r.enabled && r.conditions.iter().any(|c| c.field == Field::Text))
}

/// VIPs first (never moved), then banned words, then the rules in order. None: left alone.
pub fn decide(f: &Facts, s: &Settings) -> Option<Decision> {
    if let Some(v) = vip_hit(f, &s.vip) {
        return Some(Decision { action: Action::Important, reason: Reason::Vip(v) });
    }
    if let Some(w) = banned_hit(f, &s.banned) {
        return Some(Decision { action: Action::Junk, reason: Reason::Banned(w) });
    }
    s.rules
        .iter()
        .filter(|r| r.enabled && !r.conditions.is_empty())
        .find(|r| r.conditions.iter().all(|c| matches(c, f)))
        .map(|r| Decision { action: r.action.clone(), reason: Reason::Rule(r.name.clone()) })
}

// ── Search ───────────────────────────────────────────────────────────────────

/// The search of the Mail pill: free words, plus "de:" / "from:" and "objet:" / "subject:".
#[derive(Clone, PartialEq, Eq, Debug, Default)]
pub struct Query {
    pub from: Vec<String>,
    pub subject: Vec<String>,
    pub words: Vec<String>,
}

const FROM_KEYS: [&str; 4] = ["de:", "from:", "von:", "da:"];
const SUBJECT_KEYS: [&str; 6] = ["objet:", "subject:", "asunto:", "betreff:", "assunto:", "oggetto:"];

impl Query {
    #[allow(dead_code)]
    pub fn is_empty(&self) -> bool {
        self.from.is_empty() && self.subject.is_empty() && self.words.is_empty()
    }

    /// `de:dupont objet:"devis mai" facture` → from dupont, subject "devis mai", word facture.
    pub fn parse(text: &str) -> Query {
        let mut tokens = Vec::new();
        let (mut current, mut quoted) = (String::new(), false);
        for c in text.chars() {
            if c == '"' {
                quoted = !quoted;
            } else if c.is_whitespace() && !quoted {
                if !current.is_empty() {
                    tokens.push(std::mem::take(&mut current));
                }
            } else {
                current.push(c);
            }
        }
        if !current.is_empty() {
            tokens.push(current);
        }
        let mut q = Query::default();
        let mut pending: Option<bool> = None; // Some(true) = from, Some(false) = subject
        for token in tokens {
            let lower = token.to_lowercase();
            let key = FROM_KEYS.iter().map(|k| (k, true)).chain(SUBJECT_KEYS.iter().map(|k| (k, false)))
                .find(|(k, _)| lower.starts_with(**k));
            if let Some((k, is_from)) = key {
                let rest: String = token.chars().skip(k.chars().count()).collect();
                if rest.is_empty() {
                    pending = Some(is_from);
                } else if is_from {
                    q.from.push(rest);
                } else {
                    q.subject.push(rest);
                }
                continue;
            }
            match pending.take() {
                Some(true) => q.from.push(token),
                Some(false) => q.subject.push(token),
                None => q.words.push(token),
            }
        }
        q
    }
}

/// The quick filters of the Mail pill.
#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub enum Filter {
    #[default]
    All,
    Unread,
    Flagged,
    Today,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(address: &str, subject: &str, text: Option<&str>) -> Facts {
        Facts {
            sender_name: "Paul".into(),
            address: address.into(),
            subject: subject.into(),
            account: "Pro".into(),
            text: text.map(String::from),
        }
    }

    #[test]
    fn words_are_whole_and_without_accents() {
        assert_eq!(normalize("  Réunion ÉTÉ "), "reunion ete");
        assert!(contains_word("Big SALE today", "sale"));
        assert!(!contains_word("Salesforce update", "sale"));
        assert!(contains_word("Promo d'été -50%", "promo"));
        assert!(contains_word("Votre facture du mois", "facture du mois"));
        assert!(contains_word("from news@shop.com", "news@shop.com"));
        assert!(contains_word("bonjour, réunion demain", "reunion"));
        assert!(!contains_word("anything", " "));
    }

    #[test]
    fn vips_then_banned_words_then_rules() {
        let mut s = Settings::default();
        let paul = facts("paul@client.fr", "Devis mai", None);
        assert_eq!(decide(&paul, &s), None);
        s.vip = vec!["@client.fr".into()];
        s.banned = vec!["devis".into()];
        assert_eq!(decide(&paul, &s).unwrap().reason, Reason::Vip("@client.fr".into()));
        s.vip = vec!["client.fr".into()];
        assert_eq!(decide(&facts("x@mail.client.fr", "Devis", None), &s).unwrap().action, Action::Important);
        assert_eq!(decide(&facts("x@notclient.fr", "Devis", None), &s).unwrap().reason, Reason::Banned("devis".into()));
        s.vip = vec![];
        s.banned = vec!["unsubscribe".into()];
        assert_eq!(decide(&facts("a@b.fr", "Hi", Some("Click to UNSUBSCRIBE")), &s).unwrap().action, Action::Junk);
        assert_eq!(decide(&facts("a@b.fr", "Hi", None), &s), None);
        assert!(needs_text(&s));
        s.banned = vec![];
        s.rules = vec![
            Rule { id: "1".into(), name: "Off".into(), enabled: false,
                   conditions: vec![Condition { field: Field::Sender, value: "paul".into() }], action: Action::Junk },
            Rule { id: "2".into(), name: "Clients".into(), enabled: true,
                   conditions: vec![Condition { field: Field::Domain, value: "@client.fr".into() },
                                    Condition { field: Field::Subject, value: "devis".into() }],
                   action: Action::Move("Clients".into()) },
        ];
        let d = decide(&paul, &s).unwrap();
        assert_eq!(d.action, Action::Move("Clients".into()));
        assert_eq!(d.reason, Reason::Rule("Clients".into()));
        assert_eq!(decide(&facts("paul@client.fr", "Bonjour", None), &s), None);
    }

    #[test]
    fn settings_and_actions_round_trip_as_the_island_reads_them() {
        let s = Settings { auto_sort: true, rules: vec![Rule { id: "a".into(), name: "n".into(), enabled: true,
            conditions: vec![], action: Action::Move("X".into()) }], ..Default::default() };
        let json = serde_json::to_string(&s).unwrap();
        assert!(json.contains("\"autoSort\":true"));
        assert!(json.contains("{\"kind\":\"move\",\"mailbox\":\"X\"}"));
        assert_eq!(serde_json::to_string(&Action::Junk).unwrap(), "{\"kind\":\"junk\"}");
        assert_eq!(serde_json::from_str::<Settings>(&json).unwrap(), s);
        assert_eq!(serde_json::from_str::<Settings>("{}").unwrap(), Settings::default());
    }

    #[test]
    fn search_reads_from_and_subject() {
        let q = Query::parse("de:dupont objet:\"devis mai\" facture urgent");
        assert_eq!(q.from, vec!["dupont"]);
        assert_eq!(q.subject, vec!["devis mai"]);
        assert_eq!(q.words, vec!["facture", "urgent"]);
        assert_eq!(Query::parse("from: anne").from, vec!["anne"]);
        assert!(Query::parse("   ").is_empty());
    }
}
