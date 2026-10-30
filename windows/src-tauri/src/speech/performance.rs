//! Measure the bundled runtime on this computer. No audio is saved or sent.
//! A GPU name is not evidence that this CPU-only build can use that GPU.

use std::sync::{Mutex, OnceLock};
use std::time::Instant;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Measurement {
    pub threads: u16,
    pub milliseconds: f64,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
struct Cache {
    key: String,
    measurements: Vec<Measurement>,
}

#[derive(Default)]
struct Runtime {
    manual: u16,
    generation: u64,
    cache: Option<Cache>,
    tuning: bool,
    attempted: bool,
    error: Option<String>,
}

fn runtime() -> &'static Mutex<Runtime> {
    static R: OnceLock<Mutex<Runtime>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(Runtime::default()))
}

fn worker() -> &'static Mutex<Option<std::thread::JoinHandle<()>>> {
    static W: OnceLock<Mutex<Option<std::thread::JoinHandle<()>>>> = OnceLock::new();
    W.get_or_init(|| Mutex::new(None))
}

/// Native inference must finish before the process tears ONNX Runtime down.
pub fn shutdown() {
    let handle = {
        let mut worker = worker().lock().unwrap();
        let mut state = runtime().lock().unwrap();
        state.generation += 1;
        state.attempted = true;
        worker.take()
    };
    if let Some(handle) = handle { let _ = handle.join(); }
    runtime().lock().unwrap().tuning = false;
}

pub fn available_threads() -> u16 {
    std::thread::available_parallelism().map(|n| n.get().min(16) as u16).unwrap_or(1)
}

fn candidates(limit: u16) -> Vec<u16> {
    let mut values = vec![1, 2, 4, 8, 16];
    values.retain(|&n| n <= limit);
    values.push(limit.max(1));
    values.sort_unstable();
    values.dedup();
    values
}

fn fastest(measurements: &[Measurement], limit: u16) -> Option<u16> {
    measurements.iter()
        .filter(|m| m.threads > 0 && m.threads <= limit && m.milliseconds.is_finite() && m.milliseconds > 0.0)
        .min_by(|a, b| a.milliseconds.total_cmp(&b.milliseconds).then(a.threads.cmp(&b.threads)))
        .map(|m| m.threads)
}

fn key() -> String {
    format!("{}:sherpa-1.13.8:cpu:v1:{}:{}:{}", super::PARAKEET.id, std::env::consts::ARCH,
        std::env::var("PROCESSOR_IDENTIFIER").unwrap_or_default(), available_threads())
}

fn cache_path() -> std::path::PathBuf {
    super::models_dir().join("performance.json")
}

pub fn configure(manual: u16) {
    let mut state = runtime().lock().unwrap();
    let manual = manual.min(available_threads());
    if state.manual != manual {
        state.generation += 1;
        state.manual = manual;
        state.attempted = false;
        state.error = None;
    }
    if state.cache.is_none() {
        state.cache = std::fs::read(cache_path()).ok()
            .and_then(|b| serde_json::from_slice::<Cache>(&b).ok())
            .filter(|c| c.key == key() && fastest(&c.measurements, available_threads()).is_some());
    }
}

pub fn threads() -> i32 {
    let state = runtime().lock().unwrap();
    selected(&state) as i32
}

fn selected(state: &Runtime) -> u16 {
    if state.manual > 0 { return state.manual; }
    state.cache.as_ref().and_then(|c| fastest(&c.measurements, available_threads()))
        .unwrap_or(available_threads().min(4))
}

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub provider: &'static str,
    pub automatic: bool,
    pub threads: u16,
    pub available_threads: u16,
    pub tuning: bool,
    pub measured: bool,
    pub measurements: Vec<Measurement>,
    pub error: Option<String>,
}

pub fn status() -> Status {
    let state = runtime().lock().unwrap();
    Status {
        provider: "cpu", automatic: state.manual == 0, threads: selected(&state),
        available_threads: available_threads(), tuning: state.tuning,
        measured: state.cache.is_some(),
        measurements: state.cache.as_ref().map(|c| c.measurements.clone()).unwrap_or_default(),
        error: state.error.clone(),
    }
}

pub fn retune() {
    let mut state = runtime().lock().unwrap();
    state.generation += 1;
    state.cache = None;
    state.attempted = false;
    state.error = None;
    let _ = std::fs::remove_file(cache_path());
}

/// Keep a bounded, energetic part of a successful transcription. A call may
/// begin with silence; benchmarking only its first seconds would decode no
/// words even though the full recording was transcribed successfully.
fn calibration_window(samples: &[f32], limit: usize) -> &[f32] {
    let width = samples.len().min(limit);
    if width == 0 { return &samples[..0]; }
    let energy = |sample: f32| if sample.is_finite() { (sample as f64).powi(2) } else { 0.0 };
    let mut sum: f64 = samples[..width].iter().map(|&s| energy(s)).sum();
    let mut best = (sum, 0);
    for end in width..samples.len() {
        sum += energy(samples[end]) - energy(samples[end - width]);
        if sum > best.0 { best = (sum, end + 1 - width); }
    }
    &samples[best.1..best.1 + width]
}

/// Calibration uses a bounded copy of a successful dictation, after its result
/// is available. It never changes that transcript. Manual changes invalidate it.
pub fn consider(samples: &[f32]) {
    if samples.len() < super::SAMPLE_RATE as usize * 3 { return; }
    let mut worker = worker().lock().unwrap();
    let generation = {
        let mut state = runtime().lock().unwrap();
        if state.manual > 0 || state.cache.is_some() || state.tuning || state.attempted { return; }
        state.tuning = true;
        state.attempted = true;
        state.generation
    };
    let sample = calibration_window(samples, super::SAMPLE_RATE as usize * 6).to_vec();
    *worker = Some(std::thread::spawn(move || {
        let mut measurements = Vec::new();
        let mut reference: Option<String> = None;
        for threads in candidates(available_threads()) {
            if runtime().lock().unwrap().generation != generation { break; }
            let Some(rec) = super::create_recognizer(threads as i32) else { continue };
            if runtime().lock().unwrap().generation != generation { break; }
            let decode = || {
                let stream = rec.create_stream();
                stream.accept_waveform(super::SAMPLE_RATE as i32, &sample);
                rec.decode(&stream);
                stream.get_result().map(|r| r.text.trim().to_string()).filter(|s| !s.is_empty())
            };
            // Warm caches before timing; compare the text so a failed/partial
            // inference can never win merely because it returned quickly.
            let Some(text) = decode() else { continue };
            if reference.as_ref().is_some_and(|r| r != &text) { continue; }
            reference.get_or_insert(text.clone());
            let start = Instant::now();
            let first = decode();
            let second = decode();
            let milliseconds = start.elapsed().as_secs_f64() * 500.0;
            if first.as_ref() == Some(&text) && second.as_ref() == Some(&text) {
                measurements.push(Measurement { threads, milliseconds });
            }
        }
        let mut state = runtime().lock().unwrap();
        state.tuning = false;
        if state.generation != generation { return; }
        if fastest(&measurements, available_threads()).is_none() {
            state.error = Some("Could not measure speech performance. Try again after a longer dictation.".into());
            return;
        }
        let cache = Cache { key: key(), measurements };
        if crate::platform::ensure_private_dir(&super::models_dir()).is_ok() {
            if let Ok(bytes) = serde_json::to_vec(&cache) {
                let tmp = cache_path().with_extension("tmp");
                if std::fs::write(&tmp, bytes).is_ok() { let _ = std::fs::rename(tmp, cache_path()); }
            }
        }
        state.cache = Some(cache);
        crate::log::line(format!("Parakeet measured CPU selection: {} threads", selected(&state)));
    }));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn candidates_include_small_and_large_cpus_without_oversubscription() {
        assert_eq!(candidates(1), vec![1]);
        assert_eq!(candidates(6), vec![1, 2, 4, 6]);
        assert_eq!(candidates(16), vec![1, 2, 4, 8, 16]);
    }

    #[test]
    fn measured_speed_wins_and_invalid_measurements_do_not() {
        let values = vec![Measurement { threads: 1, milliseconds: 80.0 },
            Measurement { threads: 4, milliseconds: 30.0 }, Measurement { threads: 8, milliseconds: 50.0 },
            Measurement { threads: 0, milliseconds: 0.1 }, Measurement { threads: 2, milliseconds: f64::NAN }];
        assert_eq!(fastest(&values, 8), Some(4));
        assert_eq!(fastest(&values, 2), Some(1));
        assert_eq!(fastest(&[], 8), None);
    }

    #[test]
    fn manual_choice_wins_over_a_faster_measurement() {
        let state = Runtime { manual: 1, cache: Some(Cache { key: String::new(),
            measurements: vec![Measurement { threads: 4, milliseconds: 1.0 }] }), ..Default::default() };
        assert_eq!(selected(&state), 1);
    }

    #[test]
    fn calibration_uses_audio_between_leading_and_trailing_silence() {
        let mut samples = vec![0.0; 10];
        samples.extend([0.25; 8]);
        samples.extend([0.0; 10]);
        assert_eq!(calibration_window(&samples, 6), &[0.25; 6]);
        assert_eq!(samples.len(), 28, "the source recording is unchanged");
    }

    #[test]
    fn calibration_is_bounded_for_short_empty_and_nonfinite_inputs() {
        assert!(calibration_window(&[], 6).is_empty());
        assert!(calibration_window(&[1.0], 0).is_empty());
        assert_eq!(calibration_window(&[0.1, -0.2], 6), &[0.1, -0.2]);
        assert_eq!(calibration_window(&[f32::NAN, 0.0, 0.5, -0.5, 0.0], 2), &[0.5, -0.5]);
    }
}
