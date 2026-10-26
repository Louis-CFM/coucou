// WhatsApp in the island: what Coucou keeps of the conversations, in memory only, and the
// rules that decide what reaches the pill. Port of WhatsAppModels.swift (the Mac's spec):
// same rules, same limits. Nothing here is ever written to disk or to a log.

use std::collections::{BTreeSet, HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use serde::Serialize;

/// What a message holds besides text: only a label is shown, the media itself is never fetched.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
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

#[derive(Clone, Debug, PartialEq, Serialize)]
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
    /// Milliseconds since 1970.
    pub date: i64,
    pub from_me: bool,
    /// The message mentions this account (only meaningful in groups).
    pub mentions_me: bool,
    /// Set by the gateway when the chat name came with the message.
    #[serde(skip)]
    pub chat_name: Option<String>,
}

impl Message {
    pub fn new(id: &str, chat: &str, sender: &str, text: &str, date: i64) -> Self {
        Message {
            id: id.into(),
            chat: chat.into(),
            sender: sender.into(),
            sender_name: String::new(),
            text: text.into(),
            media: Media::None,
            date,
            from_me: false,
            mentions_me: false,
            chat_name: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Conversation {
    /// The chat JID.
    pub id: String,
    pub name: String,
    pub is_group: bool,
    /// Newest last, the last `Inbox::KEEP` only.
    pub messages: Vec<Message>,
    pub unread: u32,
    pub last_activity: i64,
}

/// What the user chose in Settings → WhatsApp.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Filters {
    /// Groups stay quiet unless the message mentions you.
    pub mute_groups: bool,
    /// Chats never shown (JIDs).
    pub ignored: BTreeSet<String>,
}

impl Default for Filters {
    fn default() -> Self {
        Filters { mute_groups: true, ignored: BTreeSet::new() }
    }
}

// ── JIDs ──────────────────────────────────────────────────────────────────────

pub fn is_group(jid: &str) -> bool {
    jid.ends_with("@g.us")
}

/// Status updates (status@broadcast), broadcast lists and channels (…@newsletter) come in as
/// messages too, but they are not conversations: a contact's Status would become a chat named after them.
pub fn is_conversation(jid: &str) -> bool {
    !jid.ends_with("@broadcast") && !jid.ends_with("@newsletter")
}

fn user_part(jid: &str) -> &str {
    let user = jid.split('@').next().unwrap_or(jid);
    user.split(':').next().unwrap_or(user)
}

/// "33612345678@s.whatsapp.net" → "+33612345678": the digits with a plus.
pub fn display_number(jid: &str) -> String {
    let digits = user_part(jid);
    if !digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit()) {
        format!("+{digits}")
    } else {
        digits.to_string()
    }
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
    user_part(jid).chars().filter(char::is_ascii_digit).collect()
}

/// Two ids of the same person, whatever their server part (@c.us, @s.whatsapp.net, a bare number).
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Outcome {
    Duplicate,
    Ignored,
    Quiet,
    Notify,
}

/// The conversations, grouped by chat: one entry per conversation, never one per message.
#[derive(Default)]
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
        let mut list: Vec<&Conversation> = self.conversations.values().collect();
        list.sort_by(|a, b| b.last_activity.cmp(&a.last_activity).then_with(|| a.id.cmp(&b.id)));
        list
    }

    #[cfg(test)]
    pub fn total_unread(&self) -> u32 {
        self.conversations.values().map(|c| c.unread).sum()
    }

    /// Adds a message to its conversation. `Notify` when it should reach you (Mochi reacts),
    /// `Quiet` when it is kept but stays silent (a muted group, your own message).
    /// `history`: an older message loaded on demand: kept, never counted as unread, never announced.
    pub fn add(&mut self, message: Message, filters: &Filters, name: Option<&str>, history: bool) -> Outcome {
        if self.seen.contains(&message.id) {
            return Outcome::Duplicate;
        }
        let chat = normalized(&message.chat);
        if !is_conversation(&chat) || filters.ignored.contains(&chat) {
            return Outcome::Ignored;
        }
        self.seen.insert(message.id.clone());
        self.seen_order.push_back(message.id.clone());
        if self.seen_order.len() > 2_000 {
            for _ in 0..1_000 {
                if let Some(id) = self.seen_order.pop_front() {
                    self.seen.remove(&id);
                }
            }
        }

        let group = is_group(&chat);
        let number = display_number(&chat);
        // In a private chat the other person names it: never your own name on your own message.
        let person_name = if group || message.from_me || message.sender_name.is_empty() {
            None
        } else {
            Some(message.sender_name.clone())
        };
        let given = name.map(str::to_string).or_else(|| message.chat_name.clone()).filter(|n| !n.is_empty());
        let mut conversation = self.conversations.remove(&chat).unwrap_or_else(|| Conversation {
            id: chat.clone(),
            name: given.clone().or_else(|| person_name.clone()).unwrap_or_else(|| number.clone()),
            is_group: group,
            messages: Vec::new(),
            unread: 0,
            last_activity: message.date,
        });
        if let Some(n) = given {
            conversation.name = n;
        } else if conversation.name == number {
            if let Some(p) = person_name {
                conversation.name = p;
            }
        }
        let date = message.date;
        let from_me = message.from_me;
        let mentions = message.mentions_me;
        let mut msg = message;
        msg.chat = chat.clone();
        conversation.messages.push(msg);
        conversation.messages.sort_by_key(|m| m.date);
        if conversation.messages.len() > Self::KEEP {
            let extra = conversation.messages.len() - Self::KEEP;
            conversation.messages.drain(0..extra);
        }
        conversation.last_activity = conversation.last_activity.max(date);

        let outcome = if history {
            Outcome::Quiet
        } else if from_me {
            // You answered from the phone: it is read there.
            conversation.unread = 0;
            Outcome::Quiet
        } else {
            conversation.unread += 1;
            if group && filters.mute_groups && !mentions {
                Outcome::Quiet
            } else {
                Outcome::Notify
            }
        };
        self.conversations.insert(chat, conversation);
        outcome
    }

    /// The conversations the pill lists: muted groups without unread mentions stay out of it.
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

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Refusal {
    Empty,
    TooLong,
    NotAConversation,
}

/// The gateways' own cap (OpenWA's send-text takes 4,096 characters at most).
pub const MAX_REPLY: usize = 4096;

/// What may be sent from the island: a reply, in a conversation already there, one at a time.
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
pub struct RateLimit {
    limit: usize,
    window: Duration,
    sent: VecDeque<Instant>,
}

impl RateLimit {
    pub fn new(limit: usize, window: Duration) -> Self {
        RateLimit { limit, window, sent: VecDeque::new() }
    }

    pub fn allow(&mut self, now: Instant) -> bool {
        while self.sent.front().is_some_and(|t| now.duration_since(*t) > self.window) {
            self.sent.pop_front();
        }
        if self.sent.len() >= self.limit {
            return false;
        }
        self.sent.push_back(now);
        true
    }
}

impl Default for RateLimit {
    fn default() -> Self {
        RateLimit::new(6, Duration::from_secs(60))
    }
}

// ── The webhook's HTTP request ────────────────────────────────────────────────

/// One HTTP request read from the local socket: enough of HTTP/1.1 for a gateway's webhook.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HttpRequest {
    pub method: String,
    pub path: String,
    /// Lowercased names.
    pub headers: HashMap<String, String>,
    pub body: Vec<u8>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Parse {
    Incomplete,
    Invalid,
    Done(HttpRequest),
}

pub const MAX_HEAD: usize = 16_384;
pub const MAX_BODY: usize = 1_000_000;

/// Parses what arrived so far; `Incomplete` until the whole body is there.
pub fn parse_request(data: &[u8], max_body: usize) -> Parse {
    let Some(end) = data.windows(4).position(|w| w == b"\r\n\r\n") else {
        return if data.len() > MAX_HEAD { Parse::Invalid } else { Parse::Incomplete };
    };
    let Ok(head) = std::str::from_utf8(&data[..end]) else { return Parse::Invalid };
    let mut lines = head.split("\r\n");
    let first: Vec<&str> = lines.next().unwrap_or("").split(' ').filter(|s| !s.is_empty()).collect();
    if first.len() < 2 {
        return Parse::Invalid;
    }
    let mut headers = HashMap::new();
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            headers.insert(name.trim().to_ascii_lowercase(), value.trim().to_string());
        }
    }
    let length = match headers.get("content-length") {
        None => 0usize,
        Some(v) => match v.parse::<usize>() {
            Ok(n) => n,
            Err(_) => return Parse::Invalid,
        },
    };
    if length > max_body {
        return Parse::Invalid;
    }
    let start = end + 4;
    if data.len() - start < length {
        return Parse::Incomplete;
    }
    Parse::Done(HttpRequest {
        method: first[0].to_string(),
        path: first[1].to_string(),
        headers,
        body: data[start..start + length].to_vec(),
    })
}

pub fn response(status: u16, reason: &str) -> Vec<u8> {
    format!("HTTP/1.1 {status} {reason}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").into_bytes()
}

/// Compares two strings in constant time (signatures).
pub fn constant_time_eq(a: &str, b: &str) -> bool {
    let (x, y) = (a.as_bytes(), b.as_bytes());
    if x.len() != y.len() {
        return false;
    }
    x.iter().zip(y).fold(0u8, |acc, (p, q)| acc | (p ^ q)) == 0
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(id: &str, chat: &str, at: i64) -> Message {
        let mut m = Message::new(id, chat, chat, "hi", 1_800_000_000_000 + at * 1000);
        m.sender_name = "Marie".into();
        m
    }

    #[test]
    fn status_updates_and_channels_are_not_conversations() {
        let mut inbox = Inbox::default();
        let f = Filters::default();
        let mut status = Message::new("1", "status@broadcast", "33600000001@s.whatsapp.net", "https://vm.tiktok.com/x", 0);
        status.sender_name = "David".into();
        assert_eq!(inbox.add(status, &f, None, false), Outcome::Ignored);
        assert_eq!(inbox.add(msg("2", "120363000000000001@newsletter", 0), &f, None, false), Outcome::Ignored);
        assert!(inbox.conversations.is_empty());
        assert_eq!(inbox.total_unread(), 0);
        assert!(is_conversation("33600000001@s.whatsapp.net") && is_conversation("120363@g.us") && is_conversation("251556368777322@lid"));
    }

    #[test]
    fn one_conversation_per_chat() {
        let mut inbox = Inbox::default();
        let f = Filters::default();
        assert_eq!(inbox.add(msg("1", "33600000001@s.whatsapp.net", 0), &f, None, false), Outcome::Notify);
        inbox.add(msg("2", "33600000001@s.whatsapp.net", 5), &f, None, false);
        inbox.add(msg("3", "33600000002@s.whatsapp.net", 3), &f, None, false);
        assert_eq!(inbox.conversations.len(), 2);
        assert_eq!(inbox.conversations["33600000001@s.whatsapp.net"].unread, 2);
        assert_eq!(inbox.sorted()[0].id, "33600000001@s.whatsapp.net");
        assert_eq!(inbox.add(msg("2", "33600000001@s.whatsapp.net", 0), &f, None, false), Outcome::Duplicate);
        // The same person under another form.
        assert_eq!(inbox.add(msg("4", "33600000001:7@c.us", 9), &f, None, false), Outcome::Notify);
        assert_eq!(inbox.conversations.len(), 2);
        inbox.mark_read("33600000001@s.whatsapp.net");
        assert_eq!(inbox.conversations["33600000001@s.whatsapp.net"].unread, 0);
        assert_eq!(inbox.total_unread(), 1);
        let mut mine = msg("5", "33600000002@s.whatsapp.net", 10);
        mine.from_me = true;
        assert_eq!(inbox.add(mine, &f, None, false), Outcome::Quiet);
        assert_eq!(inbox.conversations["33600000002@s.whatsapp.net"].unread, 0, "my own message reads the chat");
    }

    #[test]
    fn groups_stay_quiet_unless_they_mention_me_and_ignored_chats_never_come_in() {
        let mut inbox = Inbox::default();
        let mut f = Filters::default();
        let group = "120363000000000001@g.us";
        let mut g1 = msg("g1", group, 0);
        g1.sender = "336@s.whatsapp.net".into();
        assert_eq!(inbox.add(g1, &f, None, false), Outcome::Quiet);
        assert!(inbox.visible(&f).is_empty());
        let mut g2 = msg("g2", group, 1);
        g2.mentions_me = true;
        assert_eq!(inbox.add(g2, &f, None, false), Outcome::Notify);
        assert_eq!(inbox.visible(&f).len(), 1);
        f.ignored.insert("33600000009@s.whatsapp.net".into());
        assert_eq!(inbox.add(msg("i1", "33600000009@s.whatsapp.net", 0), &f, None, false), Outcome::Ignored);
        f.mute_groups = false;
        assert_eq!(inbox.add(msg("g3", group, 2), &f, None, false), Outcome::Notify);
    }

    #[test]
    fn only_the_last_twenty_messages_are_kept() {
        let mut inbox = Inbox::default();
        for i in 0..30 {
            inbox.add(msg(&format!("m{i}"), "1@s.whatsapp.net", i), &Filters::default(), None, false);
        }
        let c = &inbox.conversations["1@s.whatsapp.net"];
        assert_eq!(c.messages.len(), 20);
        assert_eq!(c.messages.last().unwrap().id, "m29");
    }

    #[test]
    fn the_other_person_names_a_private_chat_and_history_stays_quiet() {
        let mut inbox = Inbox::default();
        let f = Filters::default();
        let chat = "33600000003@s.whatsapp.net";
        let mut mine = Message::new("o1", chat, "me", "yo", 1);
        mine.sender_name = "Louis".into();
        mine.from_me = true;
        inbox.add(mine, &f, None, false);
        assert_eq!(inbox.conversations[chat].name, "+33600000003");
        let mut theirs = Message::new("o2", chat, "x", "yo", 2);
        theirs.sender_name = "Marie".into();
        inbox.add(theirs, &f, None, false);
        assert_eq!(inbox.conversations[chat].name, "Marie");
        let before = inbox.conversations[chat].unread;
        let old = Message::new("h1", chat, "x", "old", 0);
        assert_eq!(inbox.add(old, &f, None, true), Outcome::Quiet);
        assert_eq!(inbox.conversations[chat].unread, before);
        assert_eq!(inbox.conversations[chat].messages[0].id, "h1");
    }

    #[test]
    fn ids_and_mentions() {
        assert!(same_user("628@c.us", "628:4@s.whatsapp.net"));
        assert!(!same_user("1@c.us", "2@c.us"));
        assert!(text_mentions("hey @33612345678!", Some("33612345678@s.whatsapp.net")));
        assert!(!text_mentions("hey @336", Some("33612345678@s.whatsapp.net")));
        assert!(!text_mentions("hey @33612345678", None));
        assert_eq!(display_number("33612345678:3@s.whatsapp.net"), "+33612345678");
        assert_eq!(display_number("abc@lid"), "abc");
        assert_eq!(normalized("33612345678:12@c.us"), "33612345678@s.whatsapp.net");
        assert_eq!(normalized("nojid"), "nojid");
    }

    #[test]
    fn replies_only_to_a_conversation_and_a_few_a_minute() {
        let mut inbox = Inbox::default();
        inbox.add(msg("1", "33600000001@s.whatsapp.net", 0), &Filters::default(), None, false);
        assert_eq!(check_reply("  ", "33600000001@s.whatsapp.net", &inbox), Some(Refusal::Empty));
        assert_eq!(check_reply(&"a".repeat(4097), "33600000001@s.whatsapp.net", &inbox), Some(Refusal::TooLong));
        assert_eq!(check_reply("ok", "33600000099@s.whatsapp.net", &inbox), Some(Refusal::NotAConversation));
        assert_eq!(check_reply("ok", "33600000001@c.us", &inbox), None);
        let mut rate = RateLimit::new(2, Duration::from_secs(60));
        let now = Instant::now();
        assert!(rate.allow(now));
        assert!(rate.allow(now));
        assert!(!rate.allow(now));
        assert!(rate.allow(now + Duration::from_secs(61)));
    }

    #[test]
    fn the_webhook_request_is_read_whole_and_bounded() {
        let req = b"POST /whatsapp HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Hub-Signature-256: sha256=ab\r\nContent-Length: 5\r\n\r\nhello";
        match parse_request(req, MAX_BODY) {
            Parse::Done(r) => {
                assert_eq!(r.method, "POST");
                assert_eq!(r.path, "/whatsapp");
                assert_eq!(r.headers["x-hub-signature-256"], "sha256=ab");
                assert_eq!(r.body, b"hello");
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(parse_request(&req[..req.len() - 2], MAX_BODY), Parse::Incomplete);
        assert_eq!(parse_request(b"POST / HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n", MAX_BODY), Parse::Invalid);
        assert_eq!(parse_request(b"POST / HTTP/1.1\r\nContent-Length: -1\r\n\r\n", MAX_BODY), Parse::Invalid);
        assert_eq!(parse_request(&vec![b'a'; MAX_HEAD + 1], MAX_BODY), Parse::Invalid);
        assert_eq!(parse_request(b"GARBAGE\r\n\r\n", MAX_BODY), Parse::Invalid);
        assert!(constant_time_eq("abc", "abc"));
        assert!(!constant_time_eq("abc", "abd"));
        assert!(!constant_time_eq("abc", "ab"));
    }
}
