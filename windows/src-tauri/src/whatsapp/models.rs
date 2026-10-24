// WhatsApp in the island: what Coucou keeps of the conversations, in memory
// only, and the rules that decide what reaches the pill. Port of
// WhatsAppModels.swift; pure Rust, tested below with the Mac's own checks.
// Nothing here is ever written to disk or to a log.

use std::collections::{HashMap, HashSet, VecDeque};

use serde::Serialize;

/// What a message holds besides text: only a label is shown, the media itself is never fetched.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Media {
    None,
    Image,
    Video,
    Audio { seconds: Option<u32> },
    Voice { seconds: Option<u32> },
    Document { name: Option<String> },
    Sticker,
    Location,
    Contact,
    Other,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Message {
    pub id: String,
    /// The conversation: a person (…@s.whatsapp.net, …@lid, …@c.us) or a group (…@g.us).
    pub chat: String,
    /// Who wrote it (in a group, the member; in a private chat, the chat itself).
    pub sender: String,
    pub sender_name: String,
    pub text: String,
    pub media: Media,
    /// Unix seconds.
    pub date: f64,
    pub from_me: bool,
    /// The message mentions this account (only meaningful in groups).
    pub mentions_me: bool,
    /// Set by the gateway when the chat name came with the message.
    #[serde(skip)]
    pub chat_name: Option<String>,
}

impl Message {
    pub fn new(id: &str, chat: &str, sender: &str, sender_name: &str, text: &str, date: f64) -> Message {
        Message {
            id: id.into(),
            chat: chat.into(),
            sender: sender.into(),
            sender_name: sender_name.into(),
            text: text.into(),
            media: Media::None,
            date,
            from_me: false,
            mentions_me: false,
            chat_name: None,
        }
    }

    /// One line for the pill: (the label's English key or "", the text).
    pub fn preview_key(&self) -> (&'static str, String) {
        match &self.media {
            Media::None => ("", self.text.clone()),
            Media::Image => ("Photo", self.text.clone()),
            Media::Video => ("Video", self.text.clone()),
            Media::Audio { seconds } | Media::Voice { seconds } => ("Voice message", seconds.map(duration).unwrap_or_default()),
            Media::Document { name } => ("Document", name.clone().unwrap_or_else(|| self.text.clone())),
            Media::Sticker => ("Sticker", String::new()),
            Media::Location => ("Location", String::new()),
            Media::Contact => ("Contact", String::new()),
            Media::Other => ("Message", self.text.clone()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    /// The chat JID.
    pub id: String,
    pub name: String,
    pub is_group: bool,
    /// Newest last, the last `Inbox::KEEP` only.
    pub messages: Vec<Message>,
    pub unread: u32,
    pub last_activity: f64,
}

/// What the user chose in Settings → WhatsApp.
#[derive(Debug, Clone, PartialEq)]
pub struct Filters {
    /// Groups stay quiet unless the message mentions you.
    pub mute_groups: bool,
    /// Chats never shown (JIDs).
    pub ignored: HashSet<String>,
}

impl Default for Filters {
    fn default() -> Self {
        Filters { mute_groups: true, ignored: HashSet::new() }
    }
}

// ── JIDs ──────────────────────────────────────────────────────────────────────

pub fn is_group(jid: &str) -> bool {
    jid.ends_with("@g.us")
}

/// Status updates (status@broadcast), broadcast lists and channels (…@newsletter)
/// arrive as messages too, but they are not conversations: a contact's Status
/// would become a chat named after them (upstream #901).
pub fn is_conversation(jid: &str) -> bool {
    !jid.ends_with("@broadcast") && !jid.ends_with("@newsletter")
}

/// "33612345678@s.whatsapp.net" → "+33612345678": the digits with a plus.
pub fn display_number(jid: &str) -> String {
    let user = jid.split('@').next().unwrap_or(jid);
    let digits = user.split(':').next().unwrap_or(user);
    if !digits.is_empty() && digits.chars().all(|c| c.is_ascii_digit()) { format!("+{digits}") } else { digits.to_string() }
}

/// Two letters for the avatar: "Marie Dupont" → "MD", "+33 6…" → "#".
pub fn initials(name: &str) -> String {
    let letters: String = name
        .split([' ', '-'])
        .filter(|w| w.chars().next().is_some_and(char::is_alphabetic))
        .take(2)
        .filter_map(|w| w.chars().next())
        .flat_map(char::to_uppercase)
        .collect();
    if letters.is_empty() { "#".into() } else { letters }
}

/// 12 → "0:12", 75 → "1:15".
pub fn duration(seconds: u32) -> String {
    format!("{}:{:02}", seconds / 60, seconds % 60)
}

/// The same person under its several forms: "33612345678:12@s.whatsapp.net" and
/// "33612345678@c.us" are one chat.
pub fn normalized(jid: &str) -> String {
    let Some((user, server)) = jid.split_once('@') else { return jid.to_string() };
    let user = user.split(':').next().unwrap_or(user);
    let server = if server == "c.us" { "s.whatsapp.net" } else { server };
    format!("{user}@{server}")
}

/// The user part's digits: "33612345678:3@s.whatsapp.net" → "33612345678".
pub fn digits(jid: &str) -> String {
    let user = jid.split('@').next().unwrap_or(jid);
    let base = user.split(':').next().unwrap_or(user);
    base.chars().filter(char::is_ascii_digit).collect()
}

/// Two ids of the same person, whatever their server part.
pub fn same_user(a: &str, b: &str) -> bool {
    let (x, y) = (digits(a), digits(b));
    !x.is_empty() && x == y
}

/// "@33612345678" in the text, for this account's number (how GOWA shows a mention of you).
pub fn text_mentions(text: &str, me: Option<&str>) -> bool {
    let Some(me) = me else { return false };
    let d = digits(me);
    d.len() >= 6 && text.contains(&format!("@{d}"))
}

// ── The inbox ─────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Duplicate,
    Ignored,
    Quiet,
    Notify,
}

/// The conversations, grouped by chat: one entry per conversation, never one per message.
#[derive(Debug, Default, Clone)]
pub struct Inbox {
    pub conversations: HashMap<String, Conversation>,
    seen: HashSet<String>,
    /// The same ids in arrival order, so the oldest are the ones forgotten.
    seen_order: VecDeque<String>,
}

impl Inbox {
    pub const KEEP: usize = 20;

    /// Newest activity first.
    pub fn sorted(&self) -> Vec<&Conversation> {
        let mut all: Vec<&Conversation> = self.conversations.values().collect();
        all.sort_by(|a, b| b.last_activity.partial_cmp(&a.last_activity).unwrap_or(std::cmp::Ordering::Equal));
        all
    }

    pub fn total_unread(&self) -> u32 {
        self.conversations.values().map(|c| c.unread).sum()
    }

    /// Adds a message to its conversation. `Notify` when it should reach you
    /// (Mochi reacts), `Quiet` when it is kept but silent (a muted group, your own
    /// message). `history`: an older message loaded on demand — kept, never
    /// unread, never announced.
    pub fn add(&mut self, message: Message, filters: &Filters, name: Option<&str>, history: bool) -> Outcome {
        if self.seen.contains(&message.id) {
            return Outcome::Duplicate;
        }
        let chat = normalized(&message.chat);
        if filters.ignored.contains(&chat) || !is_conversation(&chat) {
            return Outcome::Ignored;
        }
        self.seen.insert(message.id.clone());
        self.seen_order.push_back(message.id.clone());
        if self.seen_order.len() > 2_000 {
            for _ in 0..1_000 {
                if let Some(old) = self.seen_order.pop_front() {
                    self.seen.remove(&old);
                }
            }
        }

        let group = is_group(&chat);
        let number = display_number(&chat);
        // In a private chat the other person names it: never your own name on your own message.
        let person = (!group && !message.from_me && !message.sender_name.is_empty()).then(|| message.sender_name.clone());
        let given = name.map(String::from).or_else(|| message.chat_name.clone()).filter(|n| !n.is_empty());
        let conversation = self.conversations.entry(chat.clone()).or_insert_with(|| Conversation {
            id: chat.clone(),
            name: given.clone().or_else(|| person.clone()).unwrap_or_else(|| number.clone()),
            is_group: group,
            messages: Vec::new(),
            unread: 0,
            last_activity: message.date,
        });
        if let Some(n) = given {
            conversation.name = n;
        } else if conversation.name == number {
            if let Some(p) = person {
                conversation.name = p;
            }
        }
        let date = message.date;
        let from_me = message.from_me;
        let mentions = message.mentions_me;
        let mut msg = message;
        msg.chat = chat;
        conversation.messages.push(msg);
        conversation.messages.sort_by(|a, b| a.date.partial_cmp(&b.date).unwrap_or(std::cmp::Ordering::Equal));
        if conversation.messages.len() > Self::KEEP {
            let extra = conversation.messages.len() - Self::KEEP;
            conversation.messages.drain(..extra);
        }
        conversation.last_activity = conversation.last_activity.max(date);

        if history {
            Outcome::Quiet
        } else if from_me {
            // You answered from the phone: it is read there.
            conversation.unread = 0;
            Outcome::Quiet
        } else {
            conversation.unread += 1;
            if group && filters.mute_groups && !mentions { Outcome::Quiet } else { Outcome::Notify }
        }
    }

    /// The conversations the pill lists: muted groups without unread mentions stay out.
    pub fn visible(&self, filters: &Filters) -> Vec<&Conversation> {
        self.sorted()
            .into_iter()
            .filter(|c| {
                !filters.ignored.contains(&c.id)
                    && (!c.is_group || !filters.mute_groups || c.messages.iter().any(|m| m.mentions_me && !m.from_me))
            })
            .collect()
    }

    /// Unread messages in the conversations the pill shows.
    pub fn visible_unread(&self, filters: &Filters) -> u32 {
        self.visible(filters).iter().map(|c| c.unread).sum()
    }

    pub fn remove(&mut self, chat: &str) {
        self.conversations.remove(&normalized(chat));
    }

    pub fn mark_read(&mut self, chat: &str) {
        if let Some(c) = self.conversations.get_mut(&normalized(chat)) {
            c.unread = 0;
        }
    }

    pub fn rename(&mut self, chat: &str, name: &str) {
        if name.is_empty() {
            return;
        }
        if let Some(c) = self.conversations.get_mut(&normalized(chat)) {
            c.name = name.to_string();
        }
    }

    /// Everything goes (Coucou quits, WhatsApp turned off).
    pub fn clear(&mut self) {
        self.conversations.clear();
        self.seen.clear();
        self.seen_order.clear();
    }
}

// ── Replies ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    Empty,
    TooLong,
    NotAConversation,
}

/// The gateways' own cap (OpenWA's send-text takes 4,096 characters at most).
pub const MAX_REPLY: usize = 4096;

/// What may be sent: a reply, in a conversation already there, one at a time.
pub fn check_reply(text: &str, chat: &str, inbox: &Inbox) -> Option<Refusal> {
    let trimmed = text.trim();
    if trimmed.is_empty() {
        return Some(Refusal::Empty);
    }
    if trimmed.chars().count() > MAX_REPLY {
        return Some(Refusal::TooLong);
    }
    // Never a new chat, never a list of recipients: only a conversation that wrote to you.
    if !inbox.conversations.contains_key(&normalized(chat)) {
        return Some(Refusal::NotAConversation);
    }
    None
}

/// A few sends a minute at most, whatever is clicked: Coucou is no bulk sender.
#[derive(Debug, Clone)]
pub struct RateLimit {
    limit: usize,
    window: f64,
    sent: Vec<f64>,
}

impl RateLimit {
    pub fn new(limit: usize, window: f64) -> Self {
        RateLimit { limit, window, sent: Vec::new() }
    }

    pub fn allow(&mut self, now: f64) -> bool {
        let window = self.window;
        self.sent.retain(|t| now - t <= window);
        if self.sent.len() >= self.limit {
            return false;
        }
        self.sent.push(now);
        true
    }
}

// ── The webhook's HTTP request ────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub struct HttpRequest {
    pub method: String,
    pub path: String,
    /// Lowercased names.
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

#[derive(Debug, PartialEq)]
pub enum Parse {
    Incomplete,
    Invalid,
    Done(HttpRequest),
}

/// Parses what arrived so far; `Incomplete` until the whole body is there.
pub fn parse_request(data: &[u8], max_body: usize) -> Parse {
    let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") else {
        return if data.len() > 16_384 { Parse::Invalid } else { Parse::Incomplete };
    };
    let Ok(head) = std::str::from_utf8(&data[..end]) else { return Parse::Invalid };
    let mut lines = head.split("\r\n");
    let first: Vec<&str> = lines.next().unwrap_or("").split(' ').collect();
    if first.len() < 2 || first[0].is_empty() {
        return Parse::Invalid;
    }
    let mut headers = HashMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_lowercase(), value.trim().to_string());
        }
    }
    let length: i64 = headers.get("content-length").map_or(Ok(0), |v| v.parse()).unwrap_or(-1);
    if length < 0 || length as usize > max_body {
        return Parse::Invalid;
    }
    let start = end + 4;
    if data.len() - start < length as usize {
        return Parse::Incomplete;
    }
    Parse::Done(HttpRequest {
        method: first[0].to_string(),
        path: first[1].to_string(),
        headers,
        body: data[start..start + length as usize].to_vec(),
    })
}

pub fn response(status: u16, reason: &str) -> Vec<u8> {
    format!("HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").into_bytes()
}

pub fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Compares two strings in constant time (signatures).
pub fn constant_time_eq(a: &str, b: &str) -> bool {
    let (x, y) = (a.as_bytes(), b.as_bytes());
    if x.len() != y.len() {
        return false;
    }
    x.iter().zip(y).fold(0u8, |d, (p, q)| d | (p ^ q)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(id: &str, chat: &str, from: Option<&str>, at: f64, from_me: bool, mention: bool) -> Message {
        let mut m = Message::new(id, chat, from.unwrap_or(chat), "Marie", "hi", 1_800_000_000.0 + at);
        m.from_me = from_me;
        m.mentions_me = mention;
        m
    }

    fn add(inbox: &mut Inbox, m: Message, f: &Filters) -> Outcome {
        inbox.add(m, f, None, false)
    }

    #[test]
    fn one_conversation_per_chat() {
        let mut inbox = Inbox::default();
        let f = Filters::default();
        assert_eq!(add(&mut inbox, msg("1", "33600000001@s.whatsapp.net", None, 0.0, false, false), &f), Outcome::Notify);
        add(&mut inbox, msg("2", "33600000001@s.whatsapp.net", None, 5.0, false, false), &f);
        add(&mut inbox, msg("3", "33600000002@s.whatsapp.net", None, 3.0, false, false), &f);
        assert_eq!(inbox.conversations.len(), 2, "grouped by chat");
        assert_eq!(inbox.conversations["33600000001@s.whatsapp.net"].unread, 2, "unread counted");
        assert_eq!(inbox.sorted()[0].id, "33600000001@s.whatsapp.net", "newest first");
        assert_eq!(add(&mut inbox, msg("2", "33600000001@s.whatsapp.net", None, 0.0, false, false), &f), Outcome::Duplicate);
        assert_eq!(add(&mut inbox, msg("4", "33600000001:7@c.us", None, 9.0, false, false), &f), Outcome::Notify);
        assert_eq!(inbox.conversations.len(), 2, "the same person under another form");
        inbox.mark_read("33600000001@s.whatsapp.net");
        assert_eq!(inbox.conversations["33600000001@s.whatsapp.net"].unread, 0);
        assert_eq!(inbox.total_unread(), 1);
        assert_eq!(add(&mut inbox, msg("5", "33600000002@s.whatsapp.net", None, 10.0, true, false), &f), Outcome::Quiet);
        assert_eq!(inbox.conversations["33600000002@s.whatsapp.net"].unread, 0, "my own message reads the chat");
    }

    #[test]
    fn status_updates_and_channels_are_not_chats() {
        let mut inbox = Inbox::default();
        let f = Filters::default();
        assert_eq!(add(&mut inbox, msg("s1", "status@broadcast", Some("33600000001@s.whatsapp.net"), 0.0, false, false), &f), Outcome::Ignored);
        assert_eq!(add(&mut inbox, msg("n1", "120363000000000009@newsletter", None, 1.0, false, false), &f), Outcome::Ignored);
        assert!(inbox.conversations.is_empty(), "no chat for a Status or a channel");
        assert_eq!(add(&mut inbox, msg("m1", "33600000001@s.whatsapp.net", None, 2.0, false, false), &f), Outcome::Notify);
        assert_eq!(inbox.conversations.len(), 1, "a real message still makes its chat");
    }

    #[test]
    fn filters() {
        let mut inbox = Inbox::default();
        let mut f = Filters::default();
        let group = "120363000000000001@g.us";
        assert_eq!(add(&mut inbox, msg("g1", group, Some("336@s.whatsapp.net"), 0.0, false, false), &f), Outcome::Quiet);
        assert!(inbox.visible(&f).is_empty(), "hidden from the pill");
        assert_eq!(add(&mut inbox, msg("g2", group, Some("336@s.whatsapp.net"), 0.0, false, true), &f), Outcome::Notify);
        assert_eq!(inbox.visible(&f).len(), 1, "then it shows");
        f.ignored.insert("33600000009@s.whatsapp.net".into());
        assert_eq!(add(&mut inbox, msg("i1", "33600000009@s.whatsapp.net", None, 0.0, false, false), &f), Outcome::Ignored);
        f.mute_groups = false;
        assert_eq!(add(&mut inbox, msg("g3", group, Some("336@s.whatsapp.net"), 0.0, false, false), &f), Outcome::Notify);
    }

    #[test]
    fn only_the_last_messages_are_kept() {
        let mut inbox = Inbox::default();
        let f = Filters::default();
        for i in 0..30 {
            add(&mut inbox, msg(&format!("m{i}"), "1@s.whatsapp.net", None, i as f64, false, false), &f);
        }
        let c = &inbox.conversations["1@s.whatsapp.net"];
        assert_eq!((c.messages.len(), c.messages.last().unwrap().id.as_str()), (20, "m29"));
        let mut big = Inbox::default();
        for i in 0..2_500 {
            add(&mut big, msg(&format!("b{i}"), "2@s.whatsapp.net", None, i as f64, false, false), &f);
        }
        assert_eq!(add(&mut big, msg("b2499", "2@s.whatsapp.net", None, 0.0, false, false), &f), Outcome::Duplicate);
        let mut groups = Inbox::default();
        add(&mut groups, msg("q1", "120363000000000009@g.us", Some("33@s.whatsapp.net"), 0.0, false, false), &f);
        assert_eq!(groups.visible_unread(&f), 0, "a muted group's quiet messages don't count");
        groups.remove("120363000000000009@g.us");
        assert!(groups.conversations.is_empty());
        inbox.clear();
        assert!(inbox.conversations.is_empty());
    }

    #[test]
    fn labels() {
        assert_eq!((initials("Marie Dupont").as_str(), initials("+33 6").as_str()), ("MD", "#"));
        assert_eq!(display_number("33612345678@s.whatsapp.net"), "+33612345678");
        assert!(is_group("1203@g.us") && !is_group("33@s.whatsapp.net"));
        let mut v = Message::new("v", "c", "c", "", "", 0.0);
        v.media = Media::Voice { seconds: Some(12) };
        assert_eq!(v.preview_key(), ("Voice message", "0:12".to_string()));
    }

    #[test]
    fn rate_limit() {
        let mut limit = RateLimit::new(3, 60.0);
        assert!(limit.allow(0.0) && limit.allow(0.0) && limit.allow(0.0), "three in a minute");
        assert!(!limit.allow(0.0), "not four");
        assert!(limit.allow(61.0), "again a minute later");
    }

    #[test]
    fn replies() {
        let mut inbox = Inbox::default();
        add(&mut inbox, msg("r1", "33600000001@s.whatsapp.net", None, 0.0, false, false), &Filters::default());
        assert_eq!(check_reply("ok !", "33600000001@s.whatsapp.net", &inbox), None);
        assert_eq!(check_reply("ok", "33600000001@c.us", &inbox), None, "under its other form too");
        assert_eq!(check_reply("hi", "33699999999@s.whatsapp.net", &inbox), Some(Refusal::NotAConversation));
        assert_eq!(check_reply("  \n ", "33600000001@s.whatsapp.net", &inbox), Some(Refusal::Empty));
        assert_eq!(check_reply(&"a".repeat(4097), "33600000001@s.whatsapp.net", &inbox), Some(Refusal::TooLong));
    }

    #[test]
    fn the_webhooks_http_request() {
        let body = r#"{"event":"message"}"#;
        let raw = format!(
            "POST /whatsapp HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nX-Hub-Signature-256: sha256=ab\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        );
        match parse_request(raw.as_bytes(), 1_000_000) {
            Parse::Done(r) => {
                assert_eq!((r.method.as_str(), r.path.as_str()), ("POST", "/whatsapp"));
                assert_eq!(r.headers.get("x-hub-signature-256").map(String::as_str), Some("sha256=ab"));
                assert_eq!(r.body, body.as_bytes());
            }
            other => panic!("parsed: {other:?}"),
        }
        assert_eq!(parse_request(&raw.as_bytes()[..raw.len() - 3], 1_000_000), Parse::Incomplete);
        assert_eq!(parse_request(b"POST / HTTP/1.1\r\nHost: x", 1_000_000), Parse::Incomplete);
        assert_eq!(parse_request(b"\r\n\r\n", 1_000_000), Parse::Invalid);
        assert!(constant_time_eq("abc", "abc") && !constant_time_eq("abc", "abd"));
    }
}
