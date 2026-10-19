// What Coucou does to the words before pasting them, and the numbers of the
// Statistics page. Port of FlowText.swift; nothing here touches the OS, so it
// runs in the tests as it is.

use std::collections::{BTreeMap, HashSet};

use serde::{Deserialize, Serialize};

/// A word Coucou writes another way: "cloud code" → "Claude Code".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Replacement {
    #[serde(default = "new_id")]
    pub id: String,
    pub from: String,
    pub to: String,
}

/// Say the trigger, get the whole text: "my signature" → "Have a nice day,\nLouis".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Snippet {
    #[serde(default = "new_id")]
    pub id: String,
    pub trigger: String,
    pub text: String,
}

/// A fresh id for an entry: time and a counter, unique enough for one machine.
pub fn new_id() -> String {
    use std::sync::atomic::{AtomicU64, Ordering};
    static COUNTER: AtomicU64 = AtomicU64::new(0);
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("{:x}-{:x}", nanos, COUNTER.fetch_add(1, Ordering::Relaxed))
}

/// A dictation ready to paste, its snippets still set aside: each trigger heard
/// became a mark (⟦1⟧) so that nothing else (replacements, dictionary, Claude's
/// clean-up) touches the snippet's own text; `finish` puts the texts in at the end.
#[derive(Debug, Clone, PartialEq)]
pub struct Prepared {
    pub text: String,
    /// Mark → the snippet's text.
    pub snippets: BTreeMap<String, String>,
}

/// Snippet triggers set aside first (they are said as is), then the
/// replacements, then the dictionary's words get their exact spelling.
pub fn prepare(text: &str, words: &[String], replacements: &[Replacement], snippets: &[Snippet]) -> Prepared {
    let mut out = text.to_string();
    let mut marks = BTreeMap::new();
    for (index, snippet) in snippets.iter().enumerate() {
        if snippet.text.is_empty() {
            continue;
        }
        let mark = format!("⟦{}⟧", index + 1);
        let replaced = replacing(&snippet.trigger, &mark, &out);
        if replaced != out {
            marks.insert(mark, snippet.text.clone());
            out = replaced;
        }
    }
    for r in replacements {
        if !r.to.is_empty() {
            out = replacing(&r.from, &r.to, &out);
        }
    }
    for word in words {
        if is_plain_word(word) {
            out = replacing(word, word, &out);
        }
    }
    Prepared { text: out, snippets: marks }
}

/// The marks replaced by their snippets' text.
pub fn finish(text: &str, snippets: &BTreeMap<String, String>) -> String {
    let mut out = text.to_string();
    for (mark, value) in snippets {
        out = out.replace(mark.as_str(), value);
    }
    out
}

/// Whether a rewritten text still has every mark (otherwise the rewrite is not used).
pub fn keeps_marks(text: &str, snippets: &BTreeMap<String, String>) -> bool {
    snippets.keys().all(|m| text.contains(m.as_str()))
}

/// Everything done on this computer: snippets, replacements and the dictionary.
#[cfg(test)]
pub fn apply(text: &str, words: &[String], replacements: &[Replacement], snippets: &[Snippet]) -> String {
    let p = prepare(text, words, replacements, snippets);
    finish(&p.text, &p.snippets)
}

fn is_word_char(c: char) -> bool {
    c.is_alphanumeric()
}

/// The letters-and-digits runs of a phrase: "Rendez-vous !" → ["Rendez", "vous"].
pub fn tokens(s: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    for c in s.chars() {
        if is_word_char(c) {
            current.push(c);
        } else if !current.is_empty() {
            out.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

/// A run of word characters in a text, by char index.
struct Run {
    start: usize,
    end: usize,
    lower: String,
}

fn runs(chars: &[char]) -> Vec<Run> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if is_word_char(chars[i]) {
            let start = i;
            while i < chars.len() && is_word_char(chars[i]) {
                i += 1;
            }
            let lower: String = chars[start..i].iter().collect::<String>().to_lowercase();
            out.push(Run { start, end: i, lower });
        } else {
            i += 1;
        }
    }
    out
}

/// Every occurrence of `phrase`, ignoring case and what separates its words
/// ("rendez vous", "Rendez-vous"), but only as whole words: "art" never matches
/// in "partir".
pub fn replacing(phrase: &str, replacement: &str, text: &str) -> String {
    let wanted: Vec<String> = tokens(phrase).into_iter().map(|t| t.to_lowercase()).collect();
    if wanted.is_empty() {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let runs = runs(&chars);
    let mut out = String::with_capacity(text.len());
    let mut copied = 0; // char index copied up to
    let mut i = 0;
    while i + wanted.len() <= runs.len() {
        let matches = wanted.iter().enumerate().all(|(k, w)| runs[i + k].lower == *w);
        if matches {
            let start = runs[i].start;
            let end = runs[i + wanted.len() - 1].end;
            out.extend(&chars[copied..start]);
            out.push_str(replacement);
            copied = end;
            i += wanted.len();
        } else {
            i += 1;
        }
    }
    out.extend(&chars[copied..]);
    out
}

/// Only words made of letters, digits, spaces, hyphens and apostrophes get
/// their spelling fixed: "C++" would match every lone "c".
pub fn is_plain_word(word: &str) -> bool {
    let letters = word.chars().filter(|c| c.is_alphanumeric()).count();
    letters >= 2 && word.chars().all(|c| c.is_alphanumeric() || matches!(c, ' ' | '-' | '\'' | '’'))
}

/// Words as you would count them: "c'est" is one word, a lone "?" none.
pub fn word_count(s: &str) -> usize {
    s.split_whitespace().filter(|w| w.chars().any(|c| c.is_alphanumeric())).count()
}

// ── Numbers ───────────────────────────────────────────────────────────────────

/// Typing speed used to tell how much time dictating saved.
pub const TYPING_WORDS_PER_MINUTE: f64 = 45.0;

pub fn words_per_minute(words: u64, seconds: f64) -> u64 {
    if seconds < 1.0 || words == 0 {
        return 0;
    }
    (words as f64 / (seconds / 60.0)).round() as u64
}

/// Minutes saved: what typing the words would have taken, less the time spent speaking them.
pub fn minutes_saved(words: u64, seconds: f64) -> f64 {
    (words as f64 / TYPING_WORDS_PER_MINUTE - seconds / 60.0).max(0.0)
}

/// A calendar day, without a time zone.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct Day {
    pub year: i32,
    pub month: u32,
    pub day: u32,
}

impl Day {
    /// "2026-10-14".
    pub fn key(self) -> String {
        format!("{:04}-{:02}-{:02}", self.year, self.month, self.day)
    }

    #[cfg(test)]
    pub fn parse(key: &str) -> Option<Day> {
        let mut parts = key.split('-');
        let year = parts.next()?.parse().ok()?;
        let month = parts.next()?.parse().ok()?;
        let day = parts.next()?.parse().ok()?;
        Some(Day { year, month, day })
    }

    /// Days since 1970-01-01 (proleptic Gregorian).
    pub fn ordinal(self) -> i64 {
        let (y, m, d) = (self.year as i64, self.month as i64, self.day as i64);
        let y = if m <= 2 { y - 1 } else { y };
        let era = if y >= 0 { y } else { y - 399 } / 400;
        let yoe = y - era * 400;
        let mp = (m + 9) % 12;
        let doy = (153 * mp + 2) / 5 + d - 1;
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        era * 146097 + doe - 719468
    }

    pub fn from_ordinal(z: i64) -> Day {
        let z = z + 719468;
        let era = if z >= 0 { z } else { z - 146096 } / 146097;
        let doe = z - era * 146097;
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        let y = yoe + era * 400;
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        let mp = (5 * doy + 2) / 153;
        let d = doy - (153 * mp + 2) / 5 + 1;
        let m = if mp < 10 { mp + 3 } else { mp - 9 };
        Day { year: (if m <= 2 { y + 1 } else { y }) as i32, month: m as u32, day: d as u32 }
    }

    pub fn minus(self, days: i64) -> Day {
        Day::from_ordinal(self.ordinal() - days)
    }
}

/// Days in a row with at least one dictation, ending today (or yesterday, if
/// today has none yet).
pub fn streak(days: &HashSet<String>, today: Day) -> u32 {
    let mut day = today;
    if !days.contains(&day.key()) {
        day = day.minus(1);
    }
    let mut count = 0;
    while days.contains(&day.key()) {
        count += 1;
        day = day.minus(1);
    }
    count
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rep(from: &str, to: &str) -> Replacement {
        Replacement { id: new_id(), from: from.into(), to: to.into() }
    }

    fn snip(trigger: &str, text: &str) -> Snippet {
        Snippet { id: new_id(), trigger: trigger.into(), text: text.into() }
    }

    #[test]
    fn replacements_ignore_case_and_separators_but_keep_whole_words() {
        assert_eq!(replacing("cloud code", "Claude Code", "j'ouvre Cloud-Code ce matin"), "j'ouvre Claude Code ce matin");
        assert_eq!(replacing("rendez vous", "rendez-vous", "un Rendez vous demain"), "un rendez-vous demain");
        assert_eq!(replacing("art", "ART", "partir à l'art"), "partir à l'ART");
        assert_eq!(replacing("", "x", "rien"), "rien");
        assert_eq!(replacing("open ai", "x", "I use OpenAI and open-ai"), "I use OpenAI and x");
    }

    #[test]
    fn the_dictionary_fixes_the_spelling_of_plain_words_only() {
        let words = vec!["Supabase".to_string(), "C++".to_string(), "Next.js".to_string()];
        assert_eq!(apply("on passe sur supabase et c", &words, &[], &[]), "on passe sur Supabase et c");
        assert!(is_plain_word("Claude Code"));
        assert!(is_plain_word("aujourd'hui"));
        assert!(!is_plain_word("C++"));
        assert!(!is_plain_word("x"));
    }

    #[test]
    fn snippets_are_set_aside_from_everything_else() {
        let snippets = vec![snip("ma signature", "Belle journée,\nLouis Code")];
        let reps = vec![rep("code", "CODE")];
        let p = prepare("merci, ma signature", &[], &reps, &snippets);
        assert_eq!(p.text, "merci, ⟦1⟧");
        assert!(keeps_marks(&p.text, &p.snippets));
        assert!(!keeps_marks("merci", &p.snippets));
        assert_eq!(finish(&p.text, &p.snippets), "merci, Belle journée,\nLouis Code");
        // A snippet with no text is never a mark.
        let empty = vec![snip("vide", "")];
        assert_eq!(apply("c'est vide", &[], &[], &empty), "c'est vide");
    }

    #[test]
    fn words_are_counted_like_people_count_them() {
        assert_eq!(word_count("c'est  bon ? oui"), 3);
        assert_eq!(word_count(" ? ! "), 0);
        assert_eq!(tokens("Rendez-vous !"), vec!["Rendez", "vous"]);
    }

    #[test]
    fn the_numbers_of_the_statistics_page() {
        assert_eq!(words_per_minute(150, 60.0), 150);
        assert_eq!(words_per_minute(10, 0.5), 0);
        assert!((minutes_saved(450, 60.0) - 9.0).abs() < 1e-9);
        assert_eq!(minutes_saved(1, 600.0), 0.0);
    }

    #[test]
    fn days_go_back_across_months_and_years() {
        let d = Day { year: 2026, month: 3, day: 1 };
        assert_eq!(d.minus(1).key(), "2026-02-28");
        assert_eq!(Day { year: 2024, month: 3, day: 1 }.minus(1).key(), "2024-02-29");
        assert_eq!(Day { year: 2026, month: 1, day: 1 }.minus(1).key(), "2025-12-31");
        assert_eq!(Day::parse("2026-10-14"), Some(Day { year: 2026, month: 10, day: 14 }));
        assert_eq!(Day::from_ordinal(0).key(), "1970-01-01");
    }

    #[test]
    fn the_streak_counts_days_in_a_row_until_today_or_yesterday() {
        let today = Day { year: 2026, month: 10, day: 14 };
        let set = |keys: &[&str]| keys.iter().map(|s| s.to_string()).collect::<HashSet<_>>();
        assert_eq!(streak(&set(&["2026-10-14", "2026-10-13", "2026-10-11"]), today), 2);
        assert_eq!(streak(&set(&["2026-10-13", "2026-10-12"]), today), 2);
        assert_eq!(streak(&set(&["2026-10-12"]), today), 0);
        assert_eq!(streak(&set(&[]), today), 0);
    }
}
