// The Notetaker: records a call (your microphone, and what the computer plays
// for the other people), shows a live transcript, then writes the whole
// transcript person by person with Parakeet and the diarizer, and a summary
// with the to-dos. Port of NoteTaker.swift for Windows and Linux.
//
// Everything is stored in the app's folder (Notes/<id>/note.json); the audio is
// deleted once the transcript is written. No bot joins the call: the other
// people should be told it is recorded.

pub mod builder;
pub mod echo;
pub mod repair;

use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State};

use crate::flow::{pill, store::SummaryEngine};
use crate::i18n::{t, tf};
use crate::speech::{self, audio};
use builder::{Line, Speaker, TimedWord, Todo};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Recording,
    Processing,
    Ready,
    Failed,
}

/// A call noted by the Notetaker.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub title: String,
    /// Set once you rename the note: the summary then keeps your title.
    #[serde(default)]
    pub title_edited: bool,
    /// Milliseconds since 1970.
    pub start: u64,
    #[serde(default)]
    pub end: Option<u64>,
    /// The app in front when the recording started ("Teams", "Firefox").
    #[serde(default)]
    pub app: Option<String>,
    pub status: Status,
    #[serde(default)]
    pub speakers: Vec<Speaker>,
    #[serde(default)]
    pub lines: Vec<Line>,
    #[serde(default)]
    pub summary: Option<String>,
    #[serde(default)]
    pub key_points: Vec<String>,
    #[serde(default)]
    pub todos: Vec<Todo>,
    #[serde(default)]
    pub error: Option<String>,
    /// The start written out in local time ("2026-10-14 22:31"), for the Markdown.
    #[serde(default)]
    pub start_local: String,
}

/// One side of the call being written to disk, with what the live transcript
/// has not taken yet.
struct Channel {
    writer: Option<audio::WavWriter>,
    /// When the recording started. Set for the computer's sound: WASAPI's loopback
    /// sends nothing while nothing plays, so the silence it skipped is written in,
    /// and both recordings share one clock (the echo and the order of the lines
    /// line up). The Mac's ChannelRecorder does the same for its late start.
    origin: Option<std::time::Instant>,
    /// Samples since the last live chunk.
    live: Vec<f32>,
    /// Where `live` starts, in samples from the start of the recording.
    live_start: usize,
    total: usize,
}

impl Channel {
    fn new(path: &std::path::Path) -> std::io::Result<Channel> {
        Ok(Channel { writer: Some(audio::WavWriter::create(path)?), origin: None, live: Vec::new(), live_start: 0, total: 0 })
    }

    fn clocked(path: &std::path::Path, origin: std::time::Instant) -> std::io::Result<Channel> {
        let mut c = Channel::new(path)?;
        c.origin = Some(origin);
        Ok(c)
    }

    fn push(&mut self, samples: &[f32]) {
        if let Some(origin) = self.origin {
            let rate = speech::SAMPLE_RATE as f64;
            let expected = (origin.elapsed().as_secs_f64() * rate) as usize;
            let have = self.total + samples.len();
            // More than 200 ms short: the device was silent, not late. At most a minute at once.
            if expected > have + (rate * 0.2) as usize {
                let gap = (expected - have).min((rate * 60.0) as usize);
                self.write(&vec![0.0; gap]);
            }
        }
        self.write(samples);
    }

    fn write(&mut self, samples: &[f32]) {
        if let Some(w) = self.writer.as_mut() {
            let _ = w.write(samples);
        }
        self.live.extend_from_slice(samples);
        self.total += samples.len();
    }

    /// A stretch ending on a pause (or a long one) for the live transcript.
    fn take_chunk(&mut self) -> Option<(f64, Vec<f32>)> {
        let rate = speech::SAMPLE_RATE as usize;
        if self.live.len() < rate * 3 / 2 {
            return None;
        }
        let tail = &self.live[self.live.len().saturating_sub(rate / 2)..];
        let quiet = tail.iter().fold(0.0f32, |m, &s| m.max(s.abs())) < 0.01;
        if !quiet && self.live.len() < rate * 12 {
            return None;
        }
        let start = self.live_start as f64 / rate as f64;
        let chunk = std::mem::take(&mut self.live);
        self.live_start = self.total;
        let peak = chunk.iter().fold(0.0f32, |m, &s| m.max(s.abs()));
        if peak < 0.01 {
            return None;
        }
        Some((start, chunk))
    }

    fn close(&mut self) {
        if let Some(w) = self.writer.take() {
            let _ = w.finish();
        }
    }
}

struct Recording {
    id: String,
    mic: audio::Capture,
    system: Option<audio::Capture>,
    mic_channel: Arc<Mutex<Channel>>,
    system_channel: Option<Arc<Mutex<Channel>>>,
    stop_live: Arc<AtomicBool>,
}

pub struct NoteTaker {
    notes: Mutex<Vec<Note>>,
    recording: Mutex<Option<Recording>>,
    /// Notes whose transcript or summary is being written.
    working: Mutex<Vec<String>>,
    starting: AtomicBool,
}

pub fn folder() -> PathBuf {
    crate::settings::local_dir().join("Notes")
}

fn note_dir(id: &str) -> PathBuf {
    folder().join(id)
}

fn get(app: &AppHandle) -> Option<Arc<NoteTaker>> {
    app.try_state::<Arc<NoteTaker>>().map(|s| s.inner().clone())
}

pub fn is_recording(app: &AppHandle) -> bool {
    get(app).is_some_and(|n| n.recording.lock().unwrap().is_some())
}

fn now_ms() -> u64 {
    crate::flow::store::now_ms()
}

fn local_stamp() -> String {
    let t = crate::platform::local_time();
    format!("{:04}-{:02}-{:02} {:02}:{:02}", t.year, t.month, t.day, t.hour, t.minute)
}

fn person_name(n: usize) -> String {
    tf("Person {0}", &[("0", &n.to_string())])
}

impl NoteTaker {
    fn save(&self, note: &Note) {
        let dir = note_dir(&note.id);
        if crate::platform::ensure_private_dir(&dir).is_err() {
            return;
        }
        if let Ok(text) = serde_json::to_string_pretty(note) {
            let tmp = dir.join("note.json.tmp");
            if std::fs::write(&tmp, text).is_ok() {
                let _ = std::fs::rename(tmp, dir.join("note.json"));
            }
        }
    }

    fn note(&self, id: &str) -> Option<Note> {
        self.notes.lock().unwrap().iter().find(|n| n.id == id).cloned()
    }

    /// Writes a change onto the note as it is now (it may have been renamed meanwhile).
    fn change(&self, app: &AppHandle, id: &str, f: impl FnOnce(&mut Note)) -> Option<Note> {
        let updated = {
            let mut notes = self.notes.lock().unwrap();
            let note = notes.iter_mut().find(|n| n.id == id)?;
            f(note);
            note.clone()
        };
        self.save(&updated);
        let _ = app.emit_to(crate::HUB_LABEL, "notes-changed", &updated.id);
        Some(updated)
    }
}

pub fn setup(app: &AppHandle) {
    let mut notes: Vec<Note> = Vec::new();
    if let Ok(entries) = std::fs::read_dir(folder()) {
        for entry in entries.flatten() {
            if let Ok(text) = std::fs::read_to_string(entry.path().join("note.json")) {
                if let Ok(note) = serde_json::from_str::<Note>(&text) {
                    notes.push(note);
                }
            }
        }
    }
    notes.sort_by(|a, b| b.start.cmp(&a.start));
    // A call left recording or being written when Coucou last quit: written now.
    let unfinished: Vec<String> = notes
        .iter()
        .filter(|n| matches!(n.status, Status::Recording | Status::Processing))
        .map(|n| n.id.clone())
        .collect();
    for n in notes.iter_mut().filter(|n| n.status == Status::Recording) {
        n.status = Status::Processing;
        n.end.get_or_insert(n.start);
    }
    let taker = Arc::new(NoteTaker {
        notes: Mutex::new(notes),
        recording: Mutex::new(None),
        working: Mutex::new(Vec::new()),
        starting: AtomicBool::new(false),
    });
    app.manage(taker.clone());
    for id in unfinished {
        let app = app.clone();
        std::thread::spawn(move || process(&app, &id));
    }
}

/// The pill's record button: starts or stops, and says what is missing.
pub fn toggle(app: &AppHandle) {
    if is_recording(app) {
        stop(app);
    } else if let Err(err) = start(app) {
        let (text, action) = if err == "models" {
            (t("Download the voice model first, in Coucou → Settings → Recognition."), Some((t("Open Settings"), "openSettings")))
        } else {
            (err, None)
        };
        pill::announce(app, "error", "#FF6B6B", text, action, 8);
    }
}

pub fn start(app: &AppHandle) -> Result<String, String> {
    let taker = get(app).ok_or("not ready")?;
    if taker.recording.lock().unwrap().is_some() || taker.starting.swap(true, Ordering::Relaxed) {
        return Err("already recording".into());
    }
    let result = start_inner(app, &taker);
    taker.starting.store(false, Ordering::Relaxed);
    result
}

fn start_inner(app: &AppHandle, taker: &Arc<NoteTaker>) -> Result<String, String> {
    if !speech::is_ready() {
        return Err("models".into());
    }
    let now = now_ms();
    let stamp = local_stamp();
    let id = crate::flow::text::new_id();
    let note = Note {
        id: id.clone(),
        title: tf("Call · {0}", &[("0", stamp.get(5..).unwrap_or(&stamp))]),
        title_edited: false,
        start: now,
        end: None,
        app: crate::flow::os::foreground_app().filter(|(id, _)| !crate::flow::is_shell(id)).map(|(_, name)| name),
        status: Status::Recording,
        speakers: Vec::new(),
        lines: Vec::new(),
        summary: None,
        key_points: Vec::new(),
        todos: Vec::new(),
        error: None,
        start_local: stamp,
    };
    let dir = note_dir(&id);
    crate::platform::ensure_private_dir(&dir).map_err(|e| e.to_string())?;
    // One clock for both recordings, so the computer's sound lines up with the microphone.
    let origin = std::time::Instant::now();
    let mic_channel = Arc::new(Mutex::new(Channel::new(&dir.join("mic.wav")).map_err(|e| e.to_string())?));
    let mic_pref = crate::flow::get(app).map(|f| f.store.lock().unwrap().prefs.mic.clone()).unwrap_or_default();
    let sink = mic_channel.clone();
    let mic = audio::Capture::start(audio::Source::Mic(if mic_pref.is_empty() { None } else { Some(mic_pref) }), move |s| {
        sink.lock().unwrap().push(s)
    })
    .map_err(|err| {
        crate::log::line(format!("notes: microphone: {err}"));
        let _ = std::fs::remove_dir_all(&dir);
        t("Coucou can't hear you: the microphone is not allowed or not available.")
    })?;
    // Without the computer's sound, the call is noted from the microphone alone.
    let (system, system_channel) = match Channel::clocked(&dir.join("system.wav"), origin) {
        Ok(channel) => {
            let channel = Arc::new(Mutex::new(channel));
            let sink = channel.clone();
            match audio::Capture::start(audio::Source::System, move |s| sink.lock().unwrap().push(s)) {
                Ok(capture) => (Some(capture), Some(channel)),
                Err(err) => {
                    crate::log::line(format!("notes: system sound unavailable: {err}"));
                    let _ = std::fs::remove_file(dir.join("system.wav"));
                    (None, None)
                }
            }
        }
        Err(_) => (None, None),
    };
    let stop_live = Arc::new(AtomicBool::new(false));
    taker.notes.lock().unwrap().insert(0, note.clone());
    taker.save(&note);
    *taker.recording.lock().unwrap() = Some(Recording {
        id: id.clone(),
        mic,
        system,
        mic_channel: mic_channel.clone(),
        system_channel: system_channel.clone(),
        stop_live: stop_live.clone(),
    });
    speech::preload();
    spawn_live(app.clone(), taker.clone(), id.clone(), mic_channel, system_channel, stop_live);
    pill::update(app, |s| s.note_started_at = Some(note.start));
    let _ = app.emit_to(crate::HUB_LABEL, "notes-changed", &id);
    crate::log::line("notes: recording");
    Ok(id)
}

/// Every second while recording: the stretches ending on a pause go to
/// Parakeet for the live transcript (the final one is written again from the
/// whole recording).
fn spawn_live(
    app: AppHandle,
    taker: Arc<NoteTaker>,
    id: String,
    mic: Arc<Mutex<Channel>>,
    system: Option<Arc<Mutex<Channel>>>,
    stop: Arc<AtomicBool>,
) {
    std::thread::spawn(move || {
        while !stop.load(Ordering::Relaxed) {
            std::thread::sleep(Duration::from_secs(1));
            let mut channels = vec![(mic.clone(), builder::ME)];
            if let Some(s) = &system {
                channels.push((s.clone(), "others"));
            }
            for (channel, speaker) in channels {
                let chunk = channel.lock().unwrap().take_chunk();
                let Some((start, samples)) = chunk else { continue };
                let Some(transcript) = speech::transcribe(&samples) else { continue };
                let text = transcript.text.trim().to_string();
                if text.is_empty() || stop.load(Ordering::Relaxed) {
                    continue;
                }
                let end = start + samples.len() as f64 / speech::SAMPLE_RATE as f64;
                taker.change(&app, &id, |n| {
                    n.lines.push(Line { id: crate::flow::text::new_id(), speaker: speaker.into(), start, end, text, raw: None });
                    n.lines.sort_by(|a, b| a.start.partial_cmp(&b.start).unwrap_or(std::cmp::Ordering::Equal));
                });
            }
        }
    });
}

pub fn stop(app: &AppHandle) {
    let Some(taker) = get(app) else { return };
    let Some(mut rec) = taker.recording.lock().unwrap().take() else { return };
    rec.stop_live.store(true, Ordering::Relaxed);
    rec.mic.stop();
    if let Some(s) = rec.system.as_mut() {
        s.stop();
    }
    rec.mic_channel.lock().unwrap().close();
    if let Some(c) = &rec.system_channel {
        c.lock().unwrap().close();
    }
    taker.change(app, &rec.id, |n| {
        n.end = Some(now_ms());
        n.status = Status::Processing;
    });
    pill::update(app, |s| s.note_started_at = None);
    let app = app.clone();
    let id = rec.id.clone();
    std::thread::spawn(move || process(&app, &id));
}

/// Coucou quits during a call: the recordings are closed properly, and the
/// transcript is written at the next launch.
pub fn shutdown(app: &AppHandle) {
    let Some(taker) = get(app) else { return };
    let Some(mut rec) = taker.recording.lock().unwrap().take() else { return };
    rec.stop_live.store(true, Ordering::Relaxed);
    rec.mic.stop();
    if let Some(s) = rec.system.as_mut() {
        s.stop();
    }
    rec.mic_channel.lock().unwrap().close();
    if let Some(c) = &rec.system_channel {
        c.lock().unwrap().close();
    }
    taker.change(app, &rec.id, |n| {
        n.end = Some(now_ms());
        n.status = Status::Processing;
    });
}

fn words_in(path: &std::path::Path) -> Result<(Vec<TimedWord>, Vec<f32>), String> {
    if !path.exists() {
        return Ok((Vec::new(), Vec::new()));
    }
    let samples = audio::read_wav(path).map_err(|e| e.to_string())?;
    let transcript = speech::transcribe(&samples).ok_or_else(|| t("Download the voice model first, in Coucou → Settings → Recognition."))?;
    Ok((transcript.words, samples))
}

/// Writes the transcript from the recordings, then the summary, then deletes the audio.
fn process(app: &AppHandle, id: &str) {
    let Some(taker) = get(app) else { return };
    {
        let mut working = taker.working.lock().unwrap();
        if working.iter().any(|w| w == id) {
            return;
        }
        working.push(id.to_string());
    }
    let _ = app.emit_to(crate::HUB_LABEL, "notes-changed", id);
    let result = transcript(app, &taker, id);
    if let Err(err) = &result {
        crate::log::line(format!("notes: transcript failed: {err}"));
        taker.change(app, id, |n| {
            n.status = Status::Failed;
            n.error = Some(err.clone());
        });
    }
    taker.working.lock().unwrap().retain(|w| w != id);
    if result.is_ok() {
        let engine = crate::flow::get(app).map(|f| f.store.lock().unwrap().prefs.summary_engine).unwrap_or_default();
        if engine == SummaryEngine::Claude && crate::flow::cleanup::has_key() {
            correct(app, id);
            summarize(app, id);
        }
        let title = taker.note(id).map(|n| n.title).unwrap_or_default();
        pill::announce(
            app,
            "check",
            "#34D399",
            tf("Notes ready: {0}", &[("0", &title)]),
            Some((t("See"), "openNotes")),
            12,
        );
    }
    let _ = app.emit_to(crate::HUB_LABEL, "notes-changed", id);
}

fn transcript(app: &AppHandle, taker: &Arc<NoteTaker>, id: &str) -> Result<(), String> {
    let dir = note_dir(id);
    let mic_path = dir.join("mic.wav");
    let system_path = dir.join("system.wav");
    if !mic_path.exists() {
        return Err(t("The recording of this call is gone."));
    }
    let me = t("Me");
    let (mut mine, mic_samples) = words_in(&mic_path)?;
    let (theirs, system_samples) = words_in(&system_path)?;
    let built = if theirs.len() >= 5 {
        // A call: you on the microphone, the others on the computer's sound. Without
        // headphones the others also come back into the microphone: that echo is
        // taken out of your words, by the sound, then word by word (NoteEcho.swift).
        let heard = mine.len();
        let rate = speech::SAMPLE_RATE as f64;
        let (by_ear, _) = echo::removing(&mine, echo::levels(&mic_samples, rate), echo::levels(&system_samples, rate));
        mine = repair::removing_echo_words(&by_ear, &theirs);
        crate::log::line(format!("notes: echo: {} of {heard} microphone words were the others", heard - mine.len()));
        let turns = repair::merging_fragments(&speech::diarize(&system_samples), &[]);
        builder::build(&mine, &theirs, &turns, &me, person_name)
    } else if mine.len() >= 20 {
        // People around the computer: one recording, the voices told apart.
        let turns = repair::merging_fragments(&speech::diarize(&mic_samples), &[]);
        let voices: std::collections::HashSet<&str> = turns.iter().map(|t| t.speaker.as_str()).collect();
        if voices.len() > 1 {
            builder::build_room(&mine, &turns, person_name)
        } else {
            builder::build(&mine, &[], &[], &me, person_name)
        }
    } else {
        builder::build(&mine, &theirs, &[], &me, person_name)
    };
    let (speakers, lines) = built;
    let count = lines.len();
    taker.change(app, id, |n| {
        n.speakers = speakers;
        n.lines = lines;
        n.status = Status::Ready;
        n.error = None;
    });
    let _ = std::fs::remove_file(&mic_path);
    let _ = std::fs::remove_file(&system_path);
    crate::log::line(format!("notes: transcript of {count} lines"));
    Ok(())
}

fn plain_transcript(note: &Note) -> String {
    note.lines
        .iter()
        .map(|l| {
            let name = note.speakers.iter().find(|s| s.id == l.speaker).map(|s| s.name.clone()).unwrap_or_else(|| l.speaker.clone());
            format!("{name}: {}", l.text)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

// ── Correcting the transcript (NoteTaker.correct, Mac 0.5.0) ──────────────────

fn claude_model(app: &AppHandle) -> String {
    app.try_state::<crate::Shared>()
        .map(|s| s.settings.lock().unwrap().model.clone())
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| crate::claude::DEFAULT_MODEL.to_string())
}

fn vocabulary_path() -> PathBuf {
    folder().join("vocabulary.json")
}

/// Words and names learnt from your corrections, newest first: Claude gets them
/// with every transcript to correct, so a word fixed once is heard right next time.
pub fn vocabulary() -> Vec<String> {
    std::fs::read(vocabulary_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn learn(terms: Vec<String>) {
    let mut words = vocabulary();
    let fresh: Vec<String> = terms
        .into_iter()
        .filter(|t| !words.iter().any(|w| w.to_lowercase() == t.to_lowercase()))
        .collect();
    if fresh.is_empty() {
        return;
    }
    words.splice(0..0, fresh);
    words.truncate(300);
    let _ = crate::platform::ensure_private_dir(&folder());
    if let Err(err) = serde_json::to_vec(&words).map_err(|e| e.to_string()).and_then(|b| std::fs::write(vocabulary_path(), b).map_err(|e| e.to_string())) {
        crate::log::line(format!("notes: could not save the vocabulary: {err}"));
    }
}

/// Claude fixes the words the speech recognition got wrong (with the Claude key,
/// when Claude writes the summaries). What was heard stays in each line's `raw`.
fn correct(app: &AppHandle, id: &str) {
    let Some(taker) = get(app) else { return };
    let Some(note) = taker.note(id) else { return };
    if note.lines.is_empty() || !crate::flow::cleanup::has_key() {
        return;
    }
    taker.working.lock().unwrap().push(id.to_string());
    let _ = app.emit_to(crate::HUB_LABEL, "notes-changed", id);
    let model = claude_model(app);
    let mut seen = std::collections::HashSet::new();
    let dictionary = crate::flow::get(app).map(|f| f.store.lock().unwrap().words.words.clone()).unwrap_or_default();
    let terms: Vec<String> = vocabulary()
        .into_iter()
        .chain(dictionary)
        .filter(|w| seen.insert(w.to_lowercase()))
        .take(400)
        .collect();
    let mut total = repair::Correction::default();
    for range in repair::batches(&note.lines, 2_500) {
        let mut request = String::new();
        if !terms.is_empty() {
            request.push_str(&format!("<vocabulary>\n{}\n</vocabulary>\n", terms.join(", ")));
        }
        request.push_str(&format!("<transcript>\n{}\n</transcript>", repair::numbered_transcript(&note.lines, &note.speakers, range.clone())));
        let reply = tauri::async_runtime::block_on(async {
            match crate::claude::complete(&model, repair::CORRECTION_INSTRUCTIONS, &request, 8_000, Duration::from_secs(180)).await {
                Ok(text) => Some(text),
                Err(_) if model != crate::flow::cleanup::MODEL => crate::claude::complete(
                    crate::flow::cleanup::MODEL, repair::CORRECTION_INSTRUCTIONS, &request, 8_000, Duration::from_secs(180),
                )
                .await
                .ok(),
                Err(_) => None,
            }
        });
        let Some(c) = reply.as_deref().and_then(repair::parse_correction) else { continue };
        total.lines.extend(c.lines.into_iter().filter(|(i, _)| range.contains(i)));
        for (k, v) in c.speakers {
            total.speakers.entry(k).or_insert(v);
        }
    }
    taker.working.lock().unwrap().retain(|w| w != id);
    let mut fixed = 0;
    taker.change(app, id, |n| {
        // Edited, reassigned or deleted meanwhile: only the lines still as they were are fixed.
        let same = n.lines.iter().map(|l| &l.id).eq(note.lines.iter().map(|l| &l.id));
        if !same {
            return;
        }
        total.lines.retain(|i, _| n.lines[*i].text == note.lines[*i].text);
        fixed = repair::applying(&total, &mut n.lines, &mut n.speakers, person_name);
    });
    crate::log::line(format!("notes: correction: {fixed} of {} lines fixed", note.lines.len()));
}

/// Writes (or writes again) the summary, key points and to-dos of a note.
fn summarize(app: &AppHandle, id: &str) {
    let Some(taker) = get(app) else { return };
    let Some(note) = taker.note(id) else { return };
    if note.lines.is_empty() {
        return;
    }
    taker.working.lock().unwrap().push(id.to_string());
    let _ = app.emit_to(crate::HUB_LABEL, "notes-changed", id);
    let model = app
        .try_state::<crate::Shared>()
        .map(|s| s.settings.lock().unwrap().model.clone())
        .filter(|m| !m.is_empty())
        .unwrap_or_else(|| crate::claude::DEFAULT_MODEL.to_string());
    let mut transcript = plain_transcript(&note);
    if transcript.len() > 400_000 {
        let mut cut = 400_000;
        while !transcript.is_char_boundary(cut) {
            cut -= 1;
        }
        transcript.truncate(cut);
    }
    let user = format!("<transcript>\n{transcript}\n</transcript>");
    let reply = tauri::async_runtime::block_on(async {
        match crate::claude::complete(&model, builder::SUMMARY_INSTRUCTIONS, &user, 2048, Duration::from_secs(120)).await {
            Ok(text) => Some(text),
            Err(_) => crate::claude::complete(crate::flow::cleanup::MODEL, builder::SUMMARY_INSTRUCTIONS, &user, 2048, Duration::from_secs(120))
                .await
                .ok(),
        }
    });
    taker.working.lock().unwrap().retain(|w| w != id);
    let Some(reply) = reply else {
        let _ = app.emit_to(crate::HUB_LABEL, "notes-changed", id);
        return;
    };
    taker.change(app, id, |n| match builder::parse_summary(&reply) {
        Some(parsed) => {
            if let Some(title) = parsed.title.filter(|_| !n.title_edited) {
                n.title = title;
            }
            n.summary = Some(parsed.summary);
            n.key_points = parsed.key_points;
            n.todos = parsed.todos;
        }
        None => n.summary = Some(reply.trim().to_string()),
    });
}

/// The note as Markdown: title, date, summary, key points, to-dos, then the transcript.
pub fn markdown(note: &Note) -> String {
    let mut out = format!("# {}\n\n", note.title);
    let minutes = (((note.end.unwrap_or(note.start).saturating_sub(note.start)) as f64 / 60_000.0).round() as u64).max(1);
    out += &format!("_{} · {} min_", note.start_local, minutes);
    if !note.speakers.is_empty() {
        out += &format!("  \n_{}_", note.speakers.iter().map(|s| s.name.as_str()).collect::<Vec<_>>().join(", "));
    }
    out += "\n\n";
    if let Some(summary) = note.summary.as_ref().filter(|s| !s.is_empty()) {
        out += &format!("## {}\n\n{summary}\n\n", t("Summary"));
    }
    if !note.key_points.is_empty() {
        out += &format!("## {}\n\n", t("Key points"));
        out += &note.key_points.iter().map(|p| format!("- {p}")).collect::<Vec<_>>().join("\n");
        out += "\n\n";
    }
    if !note.todos.is_empty() {
        out += &format!("## {}\n\n", t("To do"));
        let lines: Vec<String> = note
            .todos
            .iter()
            .map(|todo| {
                let mut line = format!("- [{}] {}", if todo.done { "x" } else { " " }, todo.text);
                let extra: Vec<&str> = [todo.owner.as_deref(), todo.due.as_deref()].into_iter().flatten().filter(|s| !s.is_empty()).collect();
                if !extra.is_empty() {
                    line += &format!(" ({})", extra.join(", "));
                }
                line
            })
            .collect();
        out += &lines.join("\n");
        out += "\n\n";
    }
    if !note.lines.is_empty() {
        out += &format!("## {}\n\n", t("Transcript"));
        let lines: Vec<String> = note
            .lines
            .iter()
            .map(|l| {
                let name = note.speakers.iter().find(|s| s.id == l.speaker).map(|s| s.name.as_str()).unwrap_or(&l.speaker);
                format!("**{name}** ({}) : {}", builder::clock(l.start), l.text)
            })
            .collect();
        out += &lines.join("\n\n");
        out += "\n";
    }
    out
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NotesState {
    notes: Vec<Note>,
    recording: Option<String>,
    working: Vec<String>,
}

#[tauri::command]
pub fn notes_state(taker: State<Arc<NoteTaker>>) -> NotesState {
    NotesState {
        notes: taker.notes.lock().unwrap().clone(),
        recording: taker.recording.lock().unwrap().as_ref().map(|r| r.id.clone()),
        working: taker.working.lock().unwrap().clone(),
    }
}

#[tauri::command]
pub async fn notes_start(app: AppHandle) -> Result<String, String> {
    tauri::async_runtime::spawn_blocking(move || {
        start(&app).map_err(|e| if e == "models" { t("Download the voice model first, in Coucou → Settings → Recognition.") } else { e })
    })
    .await
    .map_err(|e| e.to_string())?
}

#[tauri::command]
pub fn notes_stop(app: AppHandle) {
    stop(&app);
}

#[tauri::command]
pub fn notes_rename(app: AppHandle, taker: State<Arc<NoteTaker>>, id: String, title: String) {
    let title = title.trim().to_string();
    if title.is_empty() {
        return;
    }
    taker.change(&app, &id, |n| {
        n.title = title;
        n.title_edited = true;
    });
}

#[tauri::command]
pub fn notes_rename_speaker(app: AppHandle, taker: State<Arc<NoteTaker>>, id: String, speaker: String, name: String) {
    let name = name.trim().to_string();
    if name.is_empty() {
        return;
    }
    let mut learnt = false;
    taker.change(&app, &id, |n| {
        let Some(index) = n.speakers.iter().position(|s| s.id == speaker) else { return };
        let is_me = n.speakers[index].is_me;
        // Given the name of another person of the call, the two are one: the
        // diarizer had cut one voice in two, and their lines are put together.
        let other = (!is_me)
            .then(|| n.speakers.iter().find(|s| s.id != speaker && !s.is_me && s.name.to_lowercase() == name.to_lowercase()))
            .flatten()
            .map(|s| s.id.clone());
        match other {
            Some(other) => {
                for l in n.lines.iter_mut().filter(|l| l.speaker == speaker) {
                    l.speaker = other.clone();
                }
                n.speakers.remove(index);
            }
            None => n.speakers[index].name = name.clone(),
        }
        learnt = !is_me;
    });
    if learnt {
        learn(vec![name]);
    }
}

/// You fix a line: the words you brought in are learnt for the next calls.
#[tauri::command]
pub fn notes_edit_line(app: AppHandle, taker: State<Arc<NoteTaker>>, id: String, line: String, text: String) {
    let text = text.trim().to_string();
    if text.is_empty() {
        return;
    }
    let mut terms = Vec::new();
    taker.change(&app, &id, |n| {
        let Some(l) = n.lines.iter_mut().find(|l| l.id == line) else { return };
        if l.text == text {
            return;
        }
        terms = repair::new_terms(&l.text, &text);
        if l.raw.is_none() {
            l.raw = Some(l.text.clone());
        }
        l.text = text;
    });
    learn(terms);
}

/// A line said by someone else than shown (an echo left, a voice taken for another).
#[tauri::command]
pub fn notes_assign_line(app: AppHandle, taker: State<Arc<NoteTaker>>, id: String, line: String, speaker: String) {
    taker.change(&app, &id, |n| {
        if !n.speakers.iter().any(|s| s.id == speaker) {
            return;
        }
        if let Some(l) = n.lines.iter_mut().find(|l| l.id == line) {
            l.speaker = speaker;
        }
    });
}

#[tauri::command]
pub fn notes_delete_line(app: AppHandle, taker: State<Arc<NoteTaker>>, id: String, line: String) {
    taker.change(&app, &id, |n| n.lines.retain(|l| l.id != line));
}

/// Correct the transcript again, then the summary from it.
#[tauri::command]
pub fn notes_correct_again(app: AppHandle, id: String) {
    std::thread::spawn(move || {
        correct(&app, &id);
        let engine = crate::flow::get(&app).map(|f| f.store.lock().unwrap().prefs.summary_engine).unwrap_or_default();
        if engine != SummaryEngine::Off {
            summarize(&app, &id);
        }
    });
}

#[tauri::command]
pub fn notes_toggle_todo(app: AppHandle, taker: State<Arc<NoteTaker>>, id: String, todo: String) {
    taker.change(&app, &id, |n| {
        if let Some(t) = n.todos.iter_mut().find(|t| t.id == todo) {
            t.done = !t.done;
        }
    });
}

#[tauri::command]
pub fn notes_delete(app: AppHandle, taker: State<Arc<NoteTaker>>, id: String) {
    if taker.recording.lock().unwrap().as_ref().is_some_and(|r| r.id == id) {
        return;
    }
    taker.notes.lock().unwrap().retain(|n| n.id != id);
    let _ = std::fs::remove_dir_all(note_dir(&id));
    let _ = app.emit_to(crate::HUB_LABEL, "notes-changed", &id);
}

#[tauri::command]
pub fn notes_summarize(app: AppHandle, id: String) {
    std::thread::spawn(move || summarize(&app, &id));
}

#[tauri::command]
pub fn notes_retry(app: AppHandle, id: String) {
    std::thread::spawn(move || process(&app, &id));
}

#[tauri::command]
pub fn notes_markdown(taker: State<Arc<NoteTaker>>, id: String) -> Option<String> {
    taker.note(&id).map(|n| markdown(&n))
}

/// Saves the note as Markdown in Documents (or the home folder) and shows it.
#[tauri::command]
pub fn notes_export(taker: State<Arc<NoteTaker>>, id: String) -> Result<String, String> {
    let note = taker.note(&id).ok_or("no such note")?;
    let home = crate::platform::home_dir();
    let dir = [home.join("Documents"), home.clone()].into_iter().find(|d| d.is_dir()).unwrap_or(home);
    let safe: String = note
        .title
        .chars()
        .map(|c| if c.is_alphanumeric() || c == ' ' || c == '-' { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let mut path = dir.join(format!("{}.md", if safe.is_empty() { "Coucou notes".to_string() } else { safe.clone() }));
    let mut n = 2;
    while path.exists() {
        path = dir.join(format!("{} ({n}).md", if safe.is_empty() { "Coucou notes" } else { &safe }));
        n += 1;
    }
    std::fs::write(&path, markdown(&note)).map_err(|e| e.to_string())?;
    crate::platform::reveal_folder(&dir.to_string_lossy());
    Ok(path.to_string_lossy().to_string())
}
