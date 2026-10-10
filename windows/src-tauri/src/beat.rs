// Mochi's dance follows the music: the tempo and the beat of what the speakers
// play, found by listening to the system's own output (PipeWire's monitor of
// the default sink, read through `pw-record`). Linux only, off by default
// ("Dance to the beat" in Settings → General), and only while Spotify plays.
//
// Nothing is kept or sent anywhere: the samples are read in memory, reduced to
// a one-number-per-10-ms "how much new sound started" curve, and dropped. The
// island gets `beat` events: the tempo, and the moment of one beat to count on
// from.

use std::collections::VecDeque;
#[cfg(target_os = "linux")]
use std::{
    io::Read,
    process::{Child, Command, Stdio},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
};

use serde::Serialize;
#[cfg(target_os = "linux")]
use tauri::{AppHandle, Emitter, State};

pub const RATE: usize = 11_025;
/// One onset value per HOP samples: about 100 a second.
const HOP: usize = 110;
const FPS: f64 = RATE as f64 / HOP as f64;
/// How much of the past the tempo is read from.
const WINDOW_SECS: f64 = 8.0;
/// No estimate before this much sound has been heard.
const MIN_SECS: f64 = 4.0;
/// The tempo is looked for between these.
const MIN_BPM: f64 = 70.0;
const MAX_BPM: f64 = 190.0;
/// The tempo he dances at is folded into this range.
const DANCE_MIN_BPM: f64 = 80.0;
const DANCE_MAX_BPM: f64 = 160.0;
/// How often a new estimate is made.
const ESTIMATE_EVERY: usize = FPS as usize;
/// An estimate whose peak is not this much above the average is not trusted.
const MIN_CONFIDENCE: f64 = 1.5;
/// The held tempo stays while its score is at least this share of the best's.
const HOLD_RATIO: f64 = 0.7;

/// What the island is told.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Beat {
    pub bpm: f64,
    /// Seconds ago the last beat was, when the estimate was made.
    pub last_beat_ago: f64,
    pub confidence: f64,
}

/// Reduces sound to onsets and reads the tempo and the beat from them.
pub struct BeatTracker {
    /// Left over from the last chunk, less than a hop.
    pending: Vec<i16>,
    low: f32,
    prev_low: f32,
    prev_high: f32,
    onsets: VecDeque<f32>,
    frames_since_estimate: usize,
    /// The tempo (as a lag in frames, before folding) the last estimate chose.
    held_lag: Option<f64>,
}

impl Default for BeatTracker {
    fn default() -> Self {
        Self::new()
    }
}

impl BeatTracker {
    pub fn new() -> Self {
        BeatTracker {
            pending: Vec::new(),
            low: 0.0,
            prev_low: 0.0,
            prev_high: 0.0,
            onsets: VecDeque::new(),
            frames_since_estimate: 0,
            held_lag: None,
        }
    }

    /// Feeds mono samples; returns an estimate about once a second.
    pub fn push(&mut self, samples: &[i16]) -> Option<Beat> {
        self.pending.extend_from_slice(samples);
        let mut estimate = None;
        let mut used = 0;
        while self.pending.len() - used >= HOP {
            let frame: Vec<i16> = self.pending[used..used + HOP].to_vec();
            used += HOP;
            self.frame(&frame);
            self.frames_since_estimate += 1;
            if self.frames_since_estimate >= ESTIMATE_EVERY {
                self.frames_since_estimate = 0;
                if let Some(beat) = self.estimate() {
                    estimate = Some(beat);
                }
            }
        }
        self.pending.drain(..used);
        estimate
    }

    /// One hop: the new energy in the low band (kick, bass) and in the rest
    /// (snare, hats, chords), in a log scale so a quiet song and a loud one look
    /// alike, kept as how much it rose since the hop before.
    fn frame(&mut self, frame: &[i16]) {
        let (mut low_e, mut high_e) = (0f32, 0f32);
        for &s in frame {
            let x = s as f32 / 32768.0;
            // One-pole low-pass near 200 Hz at 11 kHz.
            self.low += 0.1 * (x - self.low);
            let high = x - self.low;
            low_e += self.low * self.low;
            high_e += high * high;
        }
        let n = frame.len() as f32;
        let low = (1.0 + 4000.0 * low_e / n).ln();
        let high = (1.0 + 4000.0 * high_e / n).ln();
        let onset = (low - self.prev_low).max(0.0) + 0.6 * (high - self.prev_high).max(0.0);
        self.prev_low = low;
        self.prev_high = high;
        self.onsets.push_back(onset);
        let cap = (WINDOW_SECS * FPS) as usize;
        while self.onsets.len() > cap {
            self.onsets.pop_front();
        }
    }

    /// Tempo by autocorrelation of the onset curve, beat by the best comb.
    fn estimate(&mut self) -> Option<Beat> {
        if (self.onsets.len() as f64) < MIN_SECS * FPS {
            return None;
        }
        // Take out the slow level so only the pulses are left.
        let raw: Vec<f32> = self.onsets.iter().copied().collect();
        let n = raw.len();
        let half = (FPS * 0.25) as usize;
        let mut env = vec![0f32; n];
        for i in 0..n {
            let lo = i.saturating_sub(half);
            let hi = (i + half + 1).min(n);
            let mean = raw[lo..hi].iter().sum::<f32>() / (hi - lo) as f32;
            env[i] = (raw[i] - mean).max(0.0);
        }
        if env.iter().all(|&v| v < 1e-4) {
            return None; // silence
        }

        let min_lag = (60.0 * FPS / MAX_BPM).floor() as usize;
        let max_lag = (60.0 * FPS / MIN_BPM).ceil() as usize;
        let ac = |lag: usize| -> f64 {
            if lag >= n {
                return 0.0;
            }
            let mut sum = 0f64;
            for i in lag..n {
                sum += (env[i] * env[i - lag]) as f64;
            }
            sum / (n - lag) as f64
        };
        let mut scores = Vec::with_capacity(max_lag - min_lag + 1);
        for lag in min_lag..=max_lag {
            // A beat repeats at twice its period too: count that in, so the
            // true tempo beats its half and its double.
            let tempo = 60.0 * FPS / lag as f64;
            let prior = (-(tempo / 125.0).log2().powi(2) / (2.0 * 0.7 * 0.7)).exp();
            scores.push((ac(lag) + 0.5 * ac(lag * 2)) * prior);
        }
        let (mut best_i, mut best) = scores
            .iter()
            .copied()
            .enumerate()
            .fold((0, f64::MIN), |a, (i, s)| if s > a.1 { (i, s) } else { a });
        // A tempo already held is kept unless another is clearly stronger: a
        // song does not change tempo from one second to the next, its
        // autocorrelation just wobbles between rivals.
        if let Some(held) = self.held_lag {
            let near = |i: usize| ((min_lag + i) as f64 - held).abs() <= held * 0.04;
            if let Some((i, s)) = scores
                .iter()
                .copied()
                .enumerate()
                .filter(|&(i, _)| near(i))
                .fold(None, |a: Option<(usize, f64)>, (i, s)| if a.map_or(true, |x| s > x.1) { Some((i, s)) } else { a })
            {
                if s >= best * HOLD_RATIO {
                    best_i = i;
                    best = s;
                }
            }
        }
        let mean = scores.iter().sum::<f64>() / scores.len() as f64;
        if best <= 0.0 || mean <= 0.0 || best / mean < MIN_CONFIDENCE {
            return None;
        }
        // Between the two neighbouring lags: parabola through the peak.
        let lag = if best_i > 0 && best_i + 1 < scores.len() {
            let (a, b, c) = (scores[best_i - 1], scores[best_i], scores[best_i + 1]);
            let d = a - 2.0 * b + c;
            let shift = if d.abs() > f64::EPSILON { 0.5 * (a - c) / d } else { 0.0 };
            (min_lag + best_i) as f64 + shift.clamp(-1.0, 1.0)
        } else {
            (min_lag + best_i) as f64
        };
        // A beat and its double (or half) look alike to the autocorrelation, so
        // fold the tempo into the range a hop looks natural at: a song at 170
        // is danced at 85, a slow one at 70 at 140. The comb is made at the
        // folded period, which still lands on real beats.
        let mut period = lag;
        while 60.0 * FPS / period >= DANCE_MAX_BPM {
            period *= 2.0;
        }
        while 60.0 * FPS / period < DANCE_MIN_BPM {
            period /= 2.0;
        }
        self.held_lag = Some(lag);
        let bpm = 60.0 * FPS / period;

        // The beat: the offset whose comb of pulses, one every `lag` frames,
        // gathers the most onsets. Each pulse counts its neighbours a little.
        let mut best_offset = 0usize;
        let mut best_sum = f64::MIN;
        for offset in 0..period.ceil() as usize {
            let mut sum = 0f64;
            let mut at = offset as f64;
            while (at.round() as usize) < n {
                let i = at.round() as usize;
                sum += env[i] as f64;
                if i > 0 {
                    sum += 0.4 * env[i - 1] as f64;
                }
                if i + 1 < n {
                    sum += 0.4 * env[i + 1] as f64;
                }
                at += period;
            }
            if sum > best_sum {
                best_sum = sum;
                best_offset = offset;
            }
        }
        // The last comb position before the newest frame.
        let last_index = (n - 1) as f64;
        let k = ((last_index - best_offset as f64) / period).floor();
        let beat_index = best_offset as f64 + k * period;
        let ago_frames = last_index - beat_index;
        Some(Beat {
            bpm,
            last_beat_ago: ago_frames / FPS,
            confidence: best / mean,
        })
    }
}

// ── Listening ─────────────────────────────────────────────────────────────────

#[cfg(target_os = "linux")]
#[derive(Default)]
pub struct Listener {
    run: Mutex<Option<Running>>,
}

#[cfg(target_os = "linux")]
struct Running {
    stop: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Child>>>,
}

#[cfg(target_os = "linux")]
fn stop_running(running: Running) {
    running.stop.store(true, Ordering::Relaxed);
    if let Some(mut child) = running.child.lock().unwrap().take() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[cfg(target_os = "linux")]
fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

/// Spotify plays and the user wants the dance on the beat: start listening;
/// otherwise stop. Asked by the island whenever either changes. The setting is
/// checked here too, so no page can start the listening without it.
#[cfg(target_os = "linux")]
#[tauri::command]
pub fn beat_enable(app: AppHandle, shared: State<'_, crate::Shared>, listener: State<'_, Listener>, on: bool) -> bool {
    let allowed = shared.settings.lock().unwrap().beat_sync;
    let mut slot = listener.run.lock().unwrap();
    if !(on && allowed) {
        if let Some(running) = slot.take() {
            stop_running(running);
        }
        return false;
    }
    if slot.is_some() {
        return true;
    }
    let stop = Arc::new(AtomicBool::new(false));
    let child_slot: Arc<Mutex<Option<Child>>> = Arc::new(Mutex::new(None));
    let spawned = Command::new("pw-record")
        .args([
            "-P", "stream.capture.sink=true",
            "--rate", "11025",
            "--channels", "1",
            "--format", "s16",
            "--latency", "20ms",
            "-",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let mut child = match spawned {
        Ok(child) => child,
        Err(_) => return false, // no PipeWire: the dance stays at its own tempo
    };
    let Some(mut out) = child.stdout.take() else {
        let _ = child.kill();
        return false;
    };
    *child_slot.lock().unwrap() = Some(child);
    *slot = Some(Running { stop: stop.clone(), child: child_slot });
    drop(slot);

    std::thread::spawn(move || {
        let mut tracker = BeatTracker::new();
        let mut buf = [0u8; 4096];
        let mut odd: Option<u8> = None;
        while !stop.load(Ordering::Relaxed) {
            let n = match out.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            let mut bytes: Vec<u8> = Vec::with_capacity(n + 1);
            if let Some(b) = odd.take() {
                bytes.push(b);
            }
            bytes.extend_from_slice(&buf[..n]);
            if bytes.len() % 2 == 1 {
                odd = bytes.pop();
            }
            let samples: Vec<i16> = bytes.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]])).collect();
            if let Some(beat) = tracker.push(&samples) {
                let _ = app.emit("beat", BeatEvent { bpm: beat.bpm, beat_at_ms: now_ms() - beat.last_beat_ago * 1000.0, confidence: beat.confidence });
            }
        }
    });
    true
}

#[cfg(target_os = "linux")]
#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct BeatEvent {
    bpm: f64,
    /// Unix time in ms of a beat; the others follow every 60000 / bpm.
    beat_at_ms: f64,
    confidence: f64,
}

#[cfg(not(target_os = "linux"))]
#[tauri::command]
pub fn beat_enable(_on: bool) -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A click track: a short low thump on every beat, a hat between, and a
    /// little noise, `secs` long, the first beat at `first_beat` seconds.
    fn click_track(bpm: f64, secs: f64, first_beat: f64) -> Vec<i16> {
        let n = (secs * RATE as f64) as usize;
        let period = 60.0 / bpm;
        let mut seed = 12345u32;
        let mut noise = || {
            seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
            ((seed >> 16) as f32 / 65536.0 - 0.5) * 0.04
        };
        (0..n)
            .map(|i| {
                let t = i as f64 / RATE as f64;
                let since = (t - first_beat).rem_euclid(period);
                let kick = if since < 0.12 {
                    (-(since * 35.0)).exp() as f32 * (2.0 * std::f32::consts::PI * 70.0 * since as f32).sin() * 0.8
                } else {
                    0.0
                };
                let hat_since = (t - first_beat - period / 2.0).rem_euclid(period);
                let hat = if hat_since < 0.02 { 0.15 * (hat_since as f32 * 9000.0).sin() } else { 0.0 };
                ((kick + hat + noise()) * 30000.0) as i16
            })
            .collect()
    }

    fn run(bpm: f64, first_beat: f64) -> Beat {
        let secs = 12.0;
        let mut t = BeatTracker::new();
        let mut last = None;
        for chunk in click_track(bpm, secs, first_beat).chunks(2048) {
            if let Some(b) = t.push(chunk) {
                last = Some(b);
            }
        }
        last.expect("an estimate")
    }

    fn assert_on_the_beat(beat: Beat, bpm: f64, first_beat: f64, at_secs: f64) {
        assert!((beat.bpm - bpm).abs() / bpm < 0.02, "wanted {bpm}, got {}", beat.bpm);
        // Where the real last beat was, compared with where the tracker says.
        let period = 60.0 / bpm;
        let real_ago = (at_secs - first_beat).rem_euclid(period);
        let diff = (beat.last_beat_ago - real_ago).abs();
        let diff = diff.min(period - diff);
        assert!(diff < 0.06, "off the beat by {diff}s (period {period})");
    }

    #[test]
    fn finds_120_bpm_and_where_the_beats_fall() {
        let beat = run(120.0, 0.3);
        // The estimate is made on whole seconds of 100 frames: 12 s of audio is
        // 1090 frames of 110 samples, so the last estimate is at 10.9 s…
        assert_on_the_beat(beat, 120.0, 0.3, 11.0);
    }

    #[test]
    fn finds_a_slow_and_a_fast_tempo() {
        for bpm in [84.0, 100.0, 126.0, 146.0] {
            let b = run(bpm, 0.1);
            assert!((b.bpm - bpm).abs() / bpm < 0.03, "{bpm} -> {}", b.bpm);
        }
    }

    #[test]
    fn a_double_or_half_tempo_is_danced_in_the_natural_range() {
        for (real, danced) in [(70.0, 140.0), (175.0, 87.5), (200.0, 100.0)] {
            let b = run(real, 0.2);
            assert!((b.bpm - danced).abs() / danced < 0.03, "{real} -> {}", b.bpm);
        }
    }

    #[test]
    fn silence_and_steady_noise_have_no_beat() {
        let mut t = BeatTracker::new();
        assert!(t.push(&vec![0i16; RATE * 6]).is_none());
        let mut seed = 7u32;
        let noise: Vec<i16> = (0..RATE * 8)
            .map(|_| {
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                ((seed >> 16) as i32 - 32768) as i16 / 8
            })
            .collect();
        let mut t = BeatTracker::new();
        assert!(t.push(&noise).is_none());
    }

    #[test]
    fn odd_chunk_sizes_make_no_difference() {
        let samples = click_track(120.0, 8.0, 0.3);
        let mut a = BeatTracker::new();
        let mut b = BeatTracker::new();
        let mut last_a = None;
        let mut last_b = None;
        for c in samples.chunks(4096) {
            if let Some(x) = a.push(c) {
                last_a = Some(x);
            }
        }
        for c in samples.chunks(333) {
            if let Some(x) = b.push(c) {
                last_b = Some(x);
            }
        }
        assert_eq!(last_a.map(|b| (b.bpm * 100.0).round()), last_b.map(|b| (b.bpm * 100.0).round()));
    }
}

#[cfg(test)]
mod live {
    use super::*;
    /// Local check against a real capture: COUCOU_BEAT_FILE=/path cargo test live -- --ignored --nocapture
    #[test]
    #[ignore]
    fn real_capture() {
        let Ok(path) = std::env::var("COUCOU_BEAT_FILE") else { return };
        let bytes = std::fs::read(path).unwrap();
        let samples: Vec<i16> = bytes.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]])).collect();
        let mut t = BeatTracker::new();
        for chunk in samples.chunks(2048) {
            if let Some(b) = t.push(chunk) {
                eprintln!("bpm {:.1} conf {:.1} last beat {:.3}s ago", b.bpm, b.confidence, b.last_beat_ago);
            }
        }
    }
}
