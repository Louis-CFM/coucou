// Making a call's transcript right — port of the Mac's NoteModels.swift
// additions (Notetaker, Mac 0.5.0): the echo found word by word, a voice the
// diarizer cut in two put back together, Claude fixing misheard words (checked
// so it can only fix a line, never rewrite it), and the words your own
// corrections teach for the next calls. Pure functions, tested below.

use std::collections::{HashMap, HashSet};

use serde_json::Value;

use super::builder::{tokens, Line, Speaker, TimedWord, Turn};

// ── The echo, word by word ────────────────────────────────────────────────────

/// Three or more of your words in a row that the others said in the same order
/// at the same moment (one word heard differently, or missed, does not break
/// it). Catches what the sound check lets through, when the speakers are loud.
pub fn removing_echo_words(mine: &[TimedWord], others: &[TimedWord]) -> Vec<TimedWord> {
    const WINDOW: f64 = 1.2;
    const MIN_RUN: usize = 3;
    let a: Vec<String> = mine.iter().map(|w| tokens(&w.text).concat()).collect();
    let b: Vec<String> = others.iter().map(|w| tokens(&w.text).concat()).collect();
    let mut echo = vec![false; mine.len()];
    let mut i = 0;
    while i < mine.len() {
        let mut span = 0;
        if !a[i].is_empty() {
            for j in 0..others.len() {
                if b[j] != a[i] || (others[j].start - mine[i].start).abs() > WINDOW {
                    continue;
                }
                let (mut x, mut y, mut run) = (i + 1, j + 1, 1);
                while x < mine.len() && y < others.len() {
                    if a[x] == b[y] {
                        run += 1;
                        x += 1;
                        y += 1;
                    } else if y + 1 < others.len() && a[x] == b[y + 1] {
                        y += 1; // a word the microphone missed
                    } else if x + 1 < mine.len() && a[x + 1] == b[y] {
                        x += 1; // a word the microphone heard in more
                    } else if x + 1 < mine.len() && y + 1 < others.len() && a[x + 1] == b[y + 1] {
                        x += 1; // a word heard differently
                        y += 1;
                    } else {
                        break;
                    }
                }
                if run < MIN_RUN {
                    continue;
                }
                // The rest of their sentence, heard too differently to match, is the
                // echo as well: your words that follow without a pause while they speak.
                let mut k = j.max(y.saturating_sub(1));
                while k + 1 < others.len() && others[k + 1].start - others[k].end < 0.6 {
                    k += 1;
                }
                let until = others[k.min(others.len() - 1)].end + 0.3;
                while x < mine.len() && mine[x].start <= until && mine[x].start - mine[x - 1].end < 0.6 {
                    x += 1;
                }
                span = span.max(x - i);
            }
        }
        if span > 0 {
            for e in echo.iter_mut().skip(i).take(span) {
                *e = true;
            }
            i += span;
        } else {
            i += 1;
        }
    }
    mine.iter().zip(echo).filter(|(_, e)| !e).map(|(w, _)| w.clone()).collect()
}

// ── One voice cut in two ──────────────────────────────────────────────────────

/// A voice is real once it speaks this long in a row.
const FRAGMENT_LONGEST: f64 = 3.0;

fn turn_distance(t: f64, turn: &Turn) -> f64 {
    if t < turn.start {
        turn.start - t
    } else if t > turn.end {
        t - turn.end
    } else {
        0.0
    }
}

fn normalized(v: &[f32]) -> Vec<f32> {
    let norm = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm > 0.0 { v.iter().map(|x| x / norm).collect() } else { v.to_vec() }
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    if a.len() != b.len() {
        return -1.0;
    }
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}

/// A voice heard only in short bits ("Yeah.", "Sure.", the end of a sentence)
/// is almost always someone already there: such bits are too short for the
/// diarizer to recognise, and it makes a new person of them. Each bit goes to
/// the closest real voice — by its voice print when there are prints
/// (`embeddings[i]` for `turns[i]`, empty when unknown), else the nearest in
/// time. A voice is real once it speaks 3 s in a row, or long enough overall.
pub fn merging_fragments(turns: &[Turn], embeddings: &[Vec<f32>]) -> Vec<Turn> {
    let print = |i: usize| embeddings.get(i).filter(|e| !e.is_empty());
    let mut total: HashMap<&str, f64> = HashMap::new();
    let mut longest: HashMap<&str, f64> = HashMap::new();
    for t in turns {
        let len = t.end - t.start;
        *total.entry(&t.speaker).or_default() += len;
        let l = longest.entry(&t.speaker).or_default();
        *l = l.max(len);
    }
    if total.len() <= 1 {
        return turns.to_vec();
    }
    let all: f64 = total.values().sum();
    let solid: HashSet<&str> = total
        .keys()
        .copied()
        .filter(|s| longest[s] >= FRAGMENT_LONGEST || total[s] >= (all * 0.1).max(20.0))
        .collect();
    if solid.is_empty() || solid.len() == total.len() {
        return turns.to_vec();
    }

    // Each real voice's print: the mean of its turns', longer turns counting more.
    let mut centroids: HashMap<&str, Vec<f32>> = HashMap::new();
    for &speaker in &solid {
        let mut sum: Vec<f32> = Vec::new();
        for (i, t) in turns.iter().enumerate() {
            let Some(e) = print(i) else { continue };
            if t.speaker != speaker {
                continue;
            }
            let unit = normalized(e);
            if sum.is_empty() {
                sum = vec![0.0; unit.len()];
            }
            if unit.len() != sum.len() {
                continue;
            }
            let weight = (t.end - t.start) as f32;
            for (s, u) in sum.iter_mut().zip(&unit) {
                *s += u * weight;
            }
        }
        if !sum.is_empty() {
            centroids.insert(speaker, normalized(&sum));
        }
    }
    let solid_turns: Vec<&Turn> = turns.iter().filter(|t| solid.contains(t.speaker.as_str())).collect();
    turns
        .iter()
        .enumerate()
        .map(|(i, t)| {
            if solid.contains(t.speaker.as_str()) {
                return t.clone();
            }
            let mut t = t.clone();
            if let Some(e) = print(i) {
                if centroids.len() == solid.len() {
                    let unit = normalized(e);
                    if let Some((best, _)) = centroids
                        .iter()
                        .max_by(|a, b| dot(&unit, a.1).partial_cmp(&dot(&unit, b.1)).unwrap_or(std::cmp::Ordering::Equal))
                    {
                        t.speaker = best.to_string();
                        return t;
                    }
                }
            }
            let mid = (t.start + t.end) / 2.0;
            if let Some(nearest) = solid_turns
                .iter()
                .min_by(|a, b| turn_distance(mid, a).partial_cmp(&turn_distance(mid, b)).unwrap_or(std::cmp::Ordering::Equal))
            {
                t.speaker = nearest.speaker.clone();
            }
            t
        })
        .collect()
}

// ── Claude corrects the transcript ────────────────────────────────────────────

pub const CORRECTION_INSTRUCTIONS: &str = "You fix the speech-recognition errors in the transcript of a call. The recognizer often mishears \
names, brands, technical terms, numbers, and accented or non-native speech: \"UG charging\" for \
\"EV charging\", \"elemental codes\" for \"Elementor shortcodes\".
Each line is \"[n] Speaker: words\". For each line that needs it, write it as the person actually said it:
- fix the misheard words, using the whole conversation, its topic and the vocabulary given;
- remove hesitations (uh, um, euh) and words repeated by accident (the the);
- keep the speaker's own words, grammar and language, even when imperfect or mixed: never rephrase, \
translate, shorten, complete or tidy up a sentence;
- never invent a name, number, address or link: when one is unclear, keep what was heard;
- when a passage stays impossible to understand, keep it and add [?] after it.
Also give the real name of a speaker when the call makes it certain (they say their own name, or \
are called by it); otherwise leave them out.
Reply ONLY with JSON, no code block, in this shape: \
{\"lines\": {\"n\": \"the corrected words, without the speaker\"}, \"speakers\": {\"Speaker as written\": \"Name\"}}
Put only the lines you changed.";

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Correction {
    /// Line number in the request → the line as it was said.
    pub lines: HashMap<usize, String>,
    /// Name shown in the transcript ("Person 2") → the person's name.
    pub speakers: HashMap<String, String>,
}

/// Hesitations, left out when comparing a line with its correction.
const FILLERS: &[&str] = &["uh", "um", "umm", "uhm", "er", "erm", "ah", "eh", "hmm", "mmm", "mm", "euh", "bah", "hum"];

/// Lines of the transcript cut in parts of about `words` words, for long calls.
pub fn batches(lines: &[Line], words: usize) -> Vec<std::ops::Range<usize>> {
    let mut out = Vec::new();
    let (mut start, mut count) = (0, 0);
    for (index, line) in lines.iter().enumerate() {
        count += line.text.split(' ').filter(|w| !w.is_empty()).count();
        if count >= words {
            out.push(start..index + 1);
            start = index + 1;
            count = 0;
        }
    }
    if start < lines.len() {
        out.push(start..lines.len());
    }
    out
}

/// "[12] Person 2: words", one per line.
pub fn numbered_transcript(lines: &[Line], speakers: &[Speaker], range: std::ops::Range<usize>) -> String {
    range
        .map(|i| {
            let line = &lines[i];
            let name = speakers.iter().find(|s| s.id == line.speaker).map_or(line.speaker.as_str(), |s| s.name.as_str());
            format!("[{i}] {name}: {}", line.text)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// Reads {"lines": {"12": "…"}, "speakers": {"Person 2": "Pratap"}}, even with text around it.
pub fn parse_correction(reply: &str) -> Option<Correction> {
    let open = reply.find('{')?;
    let close = reply.rfind('}')?;
    if open >= close {
        return None;
    }
    let json: Value = serde_json::from_str(&reply[open..=close]).ok()?;
    let mut c = Correction::default();
    if let Some(lines) = json.get("lines").and_then(Value::as_object) {
        for (key, value) in lines {
            let digits: String = key.chars().filter(char::is_ascii_digit).collect();
            let (Ok(index), Some(text)) = (digits.parse::<usize>(), value.as_str()) else { continue };
            let text = text.trim();
            if !text.is_empty() {
                c.lines.insert(index, text.to_string());
            }
        }
    }
    if let Some(speakers) = json.get("speakers").and_then(Value::as_object) {
        for (key, value) in speakers {
            let Some(name) = value.as_str().map(str::trim).filter(|n| !n.is_empty()) else { continue };
            c.speakers.insert(key.clone(), name.to_string());
        }
    }
    Some(c)
}

pub fn edit_distance(a: &[char], b: &[char]) -> usize {
    if a.is_empty() {
        return b.len();
    }
    if b.is_empty() {
        return a.len();
    }
    let mut previous: Vec<usize> = (0..=b.len()).collect();
    let mut current = vec![0; b.len() + 1];
    for i in 1..=a.len() {
        current[0] = i;
        for j in 1..=b.len() {
            current[j] = if a[i - 1] == b[j - 1] {
                previous[j - 1]
            } else {
                1 + previous[j - 1].min(previous[j]).min(current[j - 1])
            };
        }
        std::mem::swap(&mut previous, &mut current);
    }
    previous[b.len()]
}

/// Whether a corrected line is still the same line: a few words fixed,
/// hesitations gone, not something else written instead.
pub fn plausible_fix(original: &str, fixed: &str) -> bool {
    let before: Vec<char> = tokens(original)
        .into_iter()
        .filter(|t| !FILLERS.contains(&t.as_str()))
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .collect();
    let after: Vec<char> = tokens(fixed).join(" ").chars().collect();
    if after.is_empty() {
        return false;
    }
    if before.is_empty() {
        return after.len() <= 12;
    }
    let longest = before.len().max(after.len());
    edit_distance(&before, &after) as f64 <= (longest as f64 * 0.45).max(6.0)
}

/// The lines with the plausible fixes (what was heard kept in `raw`), and the
/// people named where the call says who they are. A speaker you renamed keeps
/// your name; a name must be said somewhere in the call. Returns how many lines
/// were fixed.
pub fn applying(
    c: &Correction,
    lines: &mut [Line],
    speakers: &mut [Speaker],
    person_name: impl Fn(usize) -> String,
) -> usize {
    let mut fixed = 0;
    for (&index, text) in &c.lines {
        let Some(line) = lines.get_mut(index) else { continue };
        if *text == line.text || !plausible_fix(&line.text, text) {
            continue;
        }
        if line.raw.is_none() {
            line.raw = Some(line.text.clone());
        }
        line.text = text.clone();
        fixed += 1;
    }
    let spoken = format!(
        "{} {}",
        lines.iter().map(|l| l.raw.as_deref().unwrap_or(&l.text)).collect::<Vec<_>>().join(" "),
        lines.iter().map(|l| l.text.as_str()).collect::<Vec<_>>().join(" ")
    )
    .to_lowercase();
    for (shown, name) in &c.speakers {
        let lower = name.to_lowercase();
        if name.chars().count() > 40 || name.split(' ').filter(|w| !w.is_empty()).count() > 3 || !spoken.contains(&lower) {
            continue;
        }
        if speakers.iter().any(|s| s.name.to_lowercase() == lower) {
            continue;
        }
        let Some(s) = speakers.iter_mut().find(|s| s.name == *shown && !s.is_me) else { continue };
        // Only "Person 2" and the like: never a name you gave.
        let Ok(number) = s.id.trim_start_matches('p').parse::<usize>() else { continue };
        if s.name != person_name(number) {
            continue;
        }
        s.name = name.clone();
    }
    fixed
}

/// The words a correction of yours brought in, worth remembering for the next
/// calls: names, brands, acronyms, technical words ("UG charging" → "EV
/// charging" teaches "EV").
pub fn new_terms(old: &str, new: &str) -> Vec<String> {
    let before: HashSet<String> = tokens(old).into_iter().collect();
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for raw in new.split_whitespace() {
        let word = raw.trim_matches(|c: char| c.is_ascii_punctuation() && c != '+' && c != '#');
        let key = tokens(word).concat();
        if key.is_empty() || before.contains(&key) || FILLERS.contains(&key.as_str()) || !seen.insert(key) {
            continue;
        }
        let distinctive = word.chars().any(|c| c.is_uppercase() || c.is_ascii_digit())
            || word.contains('.')
            || word.chars().count() >= 7;
        if distinctive && word.chars().count() >= 2 {
            out.push(word.to_string());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str, from: f64) -> Vec<TimedWord> {
        text.split(' ')
            .enumerate()
            .map(|(i, w)| TimedWord { text: w.into(), start: from + i as f64 * 0.4, end: from + i as f64 * 0.4 + 0.3 })
            .collect()
    }

    fn turn(speaker: &str, start: f64, end: f64) -> Turn {
        Turn { speaker: speaker.into(), start, end }
    }

    fn person(n: usize) -> String {
        format!("Personne {n}")
    }

    fn line(speaker: &str, text: &str) -> Line {
        Line { id: format!("{speaker}-{text}"), speaker: speaker.into(), start: 0.0, end: 1.0, text: text.into(), raw: None }
    }

    #[test]
    fn echo_word_by_word_their_sentence_inside_one_of_my_lines() {
        let mut mine = words("so what do you need", 0.0);
        mine.extend(words("currently we start with one page on this requirement", 10.0));
        mine.extend(words("okay perfect", 15.0));
        let theirs = words("currently we start with one page for this particular category", 9.9);
        let kept = removing_echo_words(&mine, &theirs);
        let text: Vec<&str> = kept.iter().map(|w| w.text.as_str()).collect();
        assert_eq!(text.join(" "), "so what do you need okay perfect", "my words stay");
        let lone = removing_echo_words(&words("yeah sure", 3.0), &words("yeah", 3.0));
        assert_eq!(lone.len(), 2, "two words in common are not an echo");
    }

    #[test]
    fn one_voice_cut_in_two_by_the_diarizer() {
        let turns = vec![turn("S1", 0.0, 20.0), turn("S2", 21.0, 21.8), turn("S3", 23.0, 40.0), turn("S2", 41.0, 41.5)];
        let prints = vec![vec![1.0, 0.0, 0.1], vec![0.9, 0.1, 0.2], vec![0.0, 1.0, 0.0], vec![0.1, 0.8, 0.0]];
        let merged: Vec<String> = merging_fragments(&turns, &prints).into_iter().map(|t| t.speaker).collect();
        assert_eq!(merged, ["S1", "S1", "S3", "S3"], "the bits go to the closest voice");
        let plain: Vec<String> = merging_fragments(&[turn("A", 0.0, 30.0), turn("B", 30.2, 31.0)], &[])
            .into_iter()
            .map(|t| t.speaker)
            .collect();
        assert_eq!(plain, ["A", "A"], "without prints, the nearest in time");
        let two: HashSet<String> = merging_fragments(&[turn("A", 0.0, 10.0), turn("B", 11.0, 20.0)], &[])
            .into_iter()
            .map(|t| t.speaker)
            .collect();
        assert_eq!(two.len(), 2, "two real voices stay two");
    }

    #[test]
    fn correcting_the_transcript() {
        let mut speakers = vec![
            Speaker { id: "me".into(), name: "Moi".into(), color: 0, is_me: true },
            Speaker { id: "p2".into(), name: "Personne 2".into(), color: 1, is_me: false },
        ];
        let mut lines = vec![
            line("p2", "uh we manufacture the EU charges primarily"),
            line("p2", "I built it with few other elemental codes right"),
            line("me", "okay perfect Pratap"),
            line("p2", "the price is fine"),
        ];
        assert!(numbered_transcript(&lines, &speakers, 0..2).starts_with("[0] Personne 2: uh we"));
        let reply = r#"{"lines": {"0": "We manufacture the EV chargers primarily.", "[1]": "I built it with a few Elementor shortcodes, right.",
             "3": "We will pay you one million dollars tomorrow morning."}, "speakers": {"Personne 2": "Pratap", "Moi": "Louis"}}"#;
        let c = parse_correction(reply).expect("parsed");
        assert_eq!(c.lines.len(), 3);
        assert_eq!(c.speakers.get("Personne 2").map(String::as_str), Some("Pratap"));

        let untouched = (lines.clone(), speakers.clone());
        let fixed = applying(&c, &mut lines, &mut speakers, person);
        assert_eq!(lines[0].text, "We manufacture the EV chargers primarily.");
        assert_eq!(lines[1].text, "I built it with a few Elementor shortcodes, right.");
        assert_eq!(lines[0].raw.as_deref(), Some("uh we manufacture the EU charges primarily"), "what was heard is kept");
        assert_eq!((lines[3].text.as_str(), fixed), ("the price is fine", 2), "a rewritten line is refused");
        let names: Vec<&str> = speakers.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, ["Moi", "Pratap"], "the person is named, me stays me");

        let (mut l2, mut s2) = untouched.clone();
        let invented = Correction { lines: HashMap::new(), speakers: [("Personne 2".to_string(), "Rahul".to_string())].into() };
        applying(&invented, &mut l2, &mut s2, person);
        assert_eq!(s2[1].name, "Personne 2", "a name never said is not given");

        let (mut l3, mut s3) = untouched;
        s3[1].name = "Client".into();
        applying(&c, &mut l3, &mut s3, person);
        assert_eq!(s3[1].name, "Client", "your name is kept");

        assert_eq!(batches(&lines, 10), vec![0..2, 2..4]);
    }

    #[test]
    fn words_learnt_from_your_corrections() {
        assert_eq!(
            new_terms("the UG charging with elemental codes", "the EV charging with Elementor shortcodes"),
            ["EV", "Elementor", "shortcodes"]
        );
        assert!(new_terms("it is fine", "it was fine").is_empty(), "small common words are not learnt");
        assert_eq!(new_terms("it's teslaws.com", "it's teslasvolt.com"), ["teslasvolt.com"]);
    }
}
