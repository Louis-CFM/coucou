//! Spoken routing and inactivity policy. No microphone, network or desktop.
use std::time::{Duration, Instant};

#[derive(Clone, Copy, Debug, Eq, Hash, PartialEq)]
pub enum Pet {
    Codex,
    Gravity,
    Claude,
    Gemini,
    Ollama,
}

impl Pet {
    pub const ALL: [Self; 5] = [Self::Codex, Self::Gravity, Self::Claude, Self::Gemini, Self::Ollama];
    pub fn from_provider(provider: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|p| p.provider() == provider)
    }
    pub fn provider(self) -> &'static str {
        match self {
            Self::Codex => "codex",
            Self::Gravity => "antigravity",
            Self::Claude => "claude-cli",
            Self::Gemini => "gemini-cli",
            Self::Ollama => "ollama",
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::Codex => "Codex",
            Self::Gravity => "Gravity",
            Self::Claude => "Claude",
            Self::Gemini => "Gemini",
            Self::Ollama => "Ollama",
        }
    }
    pub fn pill(self) -> &'static str {
        match self {
            Self::Codex => "agent_codex",
            Self::Gravity => "agent_antigravity",
            Self::Claude => "integration_claude",
            Self::Gemini => "agent_gemini",
            Self::Ollama => "ai_ollama",
        }
    }
}

#[derive(Debug, PartialEq)]
pub enum Command {
    Select(Pet, String),
    Stop,
    Dictate,
    Message(String),
}

pub fn parse(text: &str) -> Command {
    let normalized = super::wake::normalize(text);
    if matches!(
        normalized.as_str(),
        "parar conversa"
            | "terminar conversa"
            | "desligar microfone"
            | "stop conversation"
            | "stop listening"
    ) {
        return Command::Stop;
    }
    if matches!(normalized.as_str(), "ditado" | "ditar" | "dictation") {
        return Command::Dictate;
    }
    let words: Vec<&str> = text.split_whitespace().collect();
    let norm: Vec<String> = words.iter().map(|w| super::wake::normalize(w)).collect();
    let mut start = 0;
    // Only an address at the beginning selects a pet. Mentioning Codex inside
    // a question must not switch provider or lose the start of the question.
    if norm
        .first()
        .is_some_and(|w| matches!(w.as_str(), "ola" | "hey" | "ok"))
    {
        start = 1;
    }
    let prefixes: &[&[&str]] = &[
        &["chama", "o"],
        &["chama"],
        &["muda", "para"],
        &["troca", "para"],
        &["falar", "com"],
    ];
    for prefix in prefixes {
        if norm[start..]
            .iter()
            .map(String::as_str)
            .take(prefix.len())
            .eq(prefix.iter().copied())
        {
            start += prefix.len();
            break;
        }
    }
    let Some(first) = norm.get(start).map(String::as_str) else {
        return Command::Message(text.trim().into());
    };
    let (pet, count) = match (first, norm.get(start + 1).map(String::as_str)) {
        ("codex", _) => (Pet::Codex, 1),
        ("gravity" | "antigravity" | "antigravidade", _) => (Pet::Gravity, 1),
        ("anti", Some("gravity" | "gravidade")) => (Pet::Gravity, 2),
        ("claude", _) => (Pet::Claude, 1),
        ("gemini", _) => (Pet::Gemini, 1),
        ("ollama" | "olama", _) => (Pet::Ollama, 1),
        _ => return Command::Message(text.trim().into()),
    };
    let question = words[start + count..]
        .join(" ")
        .trim_start_matches(|c: char| c.is_ascii_punctuation() || c.is_whitespace())
        .to_string();
    Command::Select(pet, question)
}

/// Learned spellings are matched at word boundaries, longest first. A spelling
/// shared by two pets is ambiguous and never routes a request automatically.
pub fn parse_with_aliases(
    text: &str,
    aliases: &std::collections::BTreeMap<String, Vec<String>>,
) -> Command {
    let builtin = parse(text);
    if !matches!(builtin, Command::Message(_)) {
        return builtin;
    }
    let words: Vec<&str> = text.split_whitespace().collect();
    for count in (1..=words.len()).rev() {
        let prefix = super::wake::normalize(&words[..count].join(" "));
        let matches: Vec<Pet> = Pet::ALL
            .into_iter()
            .filter(|pet| {
                aliases.get(pet.provider()).is_some_and(|names| {
                    names
                        .iter()
                        .any(|name| !prefix.is_empty() && super::wake::normalize(name) == prefix)
                })
            })
            .collect();
        if matches.len() == 1 {
            return Command::Select(matches[0], words[count..].join(" "));
        }
        if matches.len() > 1 {
            return builtin;
        }
    }
    builtin
}

/// Only time waiting for the user counts. Model execution and speech may take
/// longer than this interval; the next listening window starts after the reply.
pub struct Idle {
    touched: Instant,
    limit: Duration,
}
impl Idle {
    pub fn new(now: Instant, seconds: u64) -> Self {
        Self {
            touched: now,
            limit: Duration::from_secs(seconds.clamp(15, 600)),
        }
    }
    pub fn touch(&mut self, now: Instant) {
        self.touched = now;
    }
    pub fn expired(&self, now: Instant) -> bool {
        now.saturating_duration_since(self.touched) >= self.limit
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn names_switch_and_preserve_the_question() {
        assert_eq!(parse("Codex."), Command::Select(Pet::Codex, String::new()));
        assert_eq!(
            parse("Olá Codex, abre o Firefox."),
            Command::Select(Pet::Codex, "abre o Firefox.".into())
        );
        assert_eq!(
            parse("chama o Gravity"),
            Command::Select(Pet::Gravity, String::new())
        );
        assert_eq!(
            parse("Anti Gravity, vê esta pasta"),
            Command::Select(Pet::Gravity, "vê esta pasta".into())
        );
        assert_eq!(
            parse("Gemini conta uma história"),
            Command::Select(Pet::Gemini, "conta uma história".into())
        );
    }
    #[test]
    fn ordinary_mentions_and_followups_are_messages() {
        for text in [
            "explica o Codex",
            "e depois?",
            "gravityfield",
            "troca para",
            "",
        ] {
            assert_eq!(parse(text), Command::Message(text.into()));
        }
        assert_eq!(parse("desligar microfone"), Command::Stop);
        assert_eq!(
            parse("parar o servidor"),
            Command::Message("parar o servidor".into())
        );
        assert_eq!(parse("ditado"), Command::Dictate);
    }
    #[test]
    fn inactivity_resets_after_speech_and_replies_and_is_bounded() {
        let now = Instant::now();
        let mut idle = Idle::new(now, 60);
        assert!(!idle.expired(now + Duration::from_secs(59)));
        assert!(idle.expired(now + Duration::from_secs(60)));
        idle.touch(now + Duration::from_secs(200)); // slow model finished
        assert!(!idle.expired(now + Duration::from_secs(259)));
        assert!(idle.expired(now + Duration::from_secs(260)));
        assert!(!Idle::new(now, 0).expired(now + Duration::from_secs(14)));
        assert!(Idle::new(now, u64::MAX).expired(now + Duration::from_secs(600)));
    }
    #[test]
    fn learned_pronunciations_are_local_and_unambiguous() {
        let mut aliases = std::collections::BTreeMap::from([(
            "codex".into(),
            vec!["códex".into(), "co dex".into()],
        )]);
        assert_eq!(
            parse_with_aliases("Co dex abre a pasta", &aliases),
            Command::Select(Pet::Codex, "abre a pasta".into())
        );
        assert_eq!(
            parse_with_aliases("co dexter", &aliases),
            Command::Message("co dexter".into())
        );
        aliases.insert("antigravity".into(), vec!["co dex".into()]);
        assert_eq!(
            parse_with_aliases("co dex", &aliases),
            Command::Message("co dex".into())
        );
    }
}
