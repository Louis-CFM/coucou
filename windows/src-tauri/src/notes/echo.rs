// Without headphones, the others' voices come out of the speakers and back into
// the microphone, and Parakeet writes them as yours (often heard a little
// differently, so comparing the words is not enough). The computer's own sound
// is the reference: where the microphone holds no more energy than the echo of
// that sound explains, what it heard is the others, not you. Port of
// NoteEcho.swift; pure functions on 16 kHz samples.

use super::builder::TimedWord;

/// Levels are measured on 20 ms frames.
pub const FRAME_SECONDS: f64 = 0.02;
/// How much louder than the echo the microphone must be for a word to be yours (≈ 10 dB).
const MARGIN: f32 = 3.0;
/// The microphone lags behind what the computer plays: searched from -100 ms to +500 ms.
const LAGS: std::ops::RangeInclusive<i64> = -5..=25;

pub struct Analysis {
    /// Frames the microphone lags behind the computer's sound.
    pub lag: i64,
    /// The microphone's level for one unit of the computer's sound: the echo's strength (≈ 0 with headphones).
    pub gain: f32,
    /// Below this, the computer plays nothing.
    sys_active: f32,
    /// The microphone's level in silence.
    mic_floor: f32,
    mic: Vec<f32>,
    sys: Vec<f32>,
}

/// RMS level of each 20 ms frame.
pub fn levels(samples: &[f32], sample_rate: f64) -> Vec<f32> {
    let size = (sample_rate * FRAME_SECONDS) as usize;
    if size == 0 || samples.is_empty() {
        return Vec::new();
    }
    samples
        .chunks(size)
        .map(|c| (c.iter().map(|s| s * s).sum::<f32>() / c.len() as f32).sqrt())
        .collect()
}

pub fn percentile(values: &[f32], p: f64) -> f32 {
    if values.is_empty() {
        return 0.0;
    }
    let mut sorted = values.to_vec();
    sorted.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let index = (((sorted.len() - 1) as f64) * p) as usize;
    sorted[index.min(sorted.len() - 1)]
}

/// How the computer's sound reaches the microphone: the delay and the strength
/// of the echo. None when the computer played too little sound to tell.
pub fn analyze(mic: Vec<f32>, sys: Vec<f32>) -> Option<Analysis> {
    if mic.is_empty() || sys.is_empty() {
        return None;
    }
    let sys_active = (percentile(&sys, 0.1) * 4.0).max(0.004);
    let active: Vec<usize> = (0..sys.len()).filter(|&t| sys[t] > sys_active).collect();
    if active.len() < 50 {
        return None;
    }
    let mic_floor = percentile(&mic, 0.1);
    let at = |t: usize, lag: i64| -> Option<usize> {
        let f = t as i64 + lag;
        (f >= 0 && (f as usize) < mic.len()).then_some(f as usize)
    };

    // The delay: where the microphone's levels follow the computer's best.
    let mut best = (0i64, f32::NEG_INFINITY);
    for lag in LAGS {
        let (mut xs, mut ys) = (Vec::new(), Vec::new());
        for &t in &active {
            if let Some(f) = at(t, lag) {
                xs.push(sys[t]);
                ys.push(mic[f]);
            }
        }
        if xs.len() < 50 {
            continue;
        }
        let corr = pearson(&xs, &ys);
        if corr > best.1 {
            best = (lag, corr);
        }
    }

    // The echo's strength: while only the others speak, the microphone is the
    // computer's sound times this. When you speak over them the ratio is far
    // higher, so a low percentile skips those moments.
    let ratios: Vec<f32> = active.iter().filter_map(|&t| at(t, best.0).map(|f| mic[f] / sys[t])).collect();
    if ratios.len() < 50 {
        return None;
    }
    let gain = percentile(&ratios, 0.35);
    Some(Analysis { lag: best.0, gain, sys_active, mic_floor, mic, sys })
}

/// For one frame of the microphone: None when the computer plays nothing then,
/// true when the microphone holds nothing more than the echo.
fn is_echo(f: i64, a: &Analysis) -> Option<bool> {
    let t = f - a.lag;
    if f < 0 || f as usize >= a.mic.len() || t < 0 || t as usize >= a.sys.len() || a.sys[t as usize] <= a.sys_active {
        return None;
    }
    Some(a.mic[f as usize] <= MARGIN * a.gain * a.sys[t as usize] + 2.0 * a.mic_floor)
}

/// Which of the microphone's words are the echo of the others.
pub fn echo_words(words: &[TimedWord], a: &Analysis) -> Vec<bool> {
    let mut flags: Vec<bool> = words
        .iter()
        .map(|w| {
            let first = (((w.start - 0.04) / FRAME_SECONDS).floor() as i64).max(0);
            let last = (((w.end + 0.04) / FRAME_SECONDS).ceil() as i64).max(first);
            let (mut active, mut echo) = (0usize, 0usize);
            for f in first..=last {
                if let Some(e) = is_echo(f, a) {
                    active += 1;
                    if e {
                        echo += 1;
                    }
                }
            }
            let frames = (last - first + 1) as usize;
            active * 2 >= frames && echo as f64 >= active as f64 * 0.6
        })
        .collect();
    // A lone word in the middle of the other kind, close to both neighbours, goes with them.
    let original = flags.clone();
    if words.len() >= 3 {
        for i in 1..words.len() - 1 {
            if original[i - 1] == original[i + 1] && original[i] != original[i - 1]
                && words[i].start - words[i - 1].end < 0.6
                && words[i + 1].start - words[i].end < 0.6
            {
                flags[i] = original[i - 1];
            }
        }
    }
    flags
}

/// The microphone's words without the echo, from both recordings' levels.
/// Returns the words kept and how many were removed.
pub fn removing(words: &[TimedWord], mic_levels: Vec<f32>, sys_levels: Vec<f32>) -> (Vec<TimedWord>, usize) {
    let Some(analysis) = analyze(mic_levels, sys_levels) else { return (words.to_vec(), 0) };
    let flags = echo_words(words, &analysis);
    let kept: Vec<TimedWord> = words.iter().zip(&flags).filter(|(_, &e)| !e).map(|(w, _)| w.clone()).collect();
    let removed = words.len() - kept.len();
    (kept, removed)
}

fn pearson(xs: &[f32], ys: &[f32]) -> f32 {
    let n = xs.len() as f32;
    let mx = xs.iter().sum::<f32>() / n;
    let my = ys.iter().sum::<f32>() / n;
    let (mut sxy, mut sxx, mut syy) = (0.0f32, 0.0f32, 0.0f32);
    for (x, y) in xs.iter().zip(ys) {
        let (dx, dy) = (x - mx, y - my);
        sxy += dx * dy;
        sxx += dx * dx;
        syy += dy * dy;
    }
    if sxx > 0.0 && syy > 0.0 { sxy / (sxx * syy).sqrt() } else { 0.0 }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(text: &str, start: f64, end: f64) -> TimedWord {
        TimedWord { text: text.into(), start, end }
    }

    /// The Mac's test (tests/NoteModelsTests.swift): synthetic voices, the
    /// others' coming back into the microphone 80 ms late at a fifth of their level.
    #[test]
    fn the_others_voice_back_in_the_microphone_is_removed() {
        let rate = 16_000.0f64;
        let mut seed: u32 = 7;
        let mut noise = move || -> f32 {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            (seed >> 8) as f32 / (1u32 << 24) as f32 - 0.5
        };
        // Syllables: 80–250 ms each, of random loudness, some silent.
        let mut syllables: Vec<f32> = Vec::new();
        while syllables.len() < 200 {
            let n = noise();
            syllables.push(if n < -0.3 { 0.05 } else { 0.5 + noise() });
        }
        let mut bounds: Vec<f64> = vec![0.0];
        while *bounds.last().unwrap() < 15.0 {
            let next = bounds.last().unwrap() + 0.165 + noise() as f64 * 0.17;
            bounds.push(next);
        }
        let voice = |t: f64, f: f64, amp: f32| -> f32 {
            let k = bounds.iter().position(|&b| b > t).unwrap_or(1);
            (2.0 * std::f64::consts::PI * f * t).sin() as f32 * amp * syllables[(k + f as usize) % syllables.len()]
        };
        let count = (rate * 14.0) as usize;
        let mut sys = vec![0.0f32; count];
        let mut mic = vec![0.0f32; count];
        let delay = (0.08 * rate) as usize;
        for i in 0..count {
            let t = i as f64 / rate;
            // Them: 1–5 s and 9–11 s. Me: 6–7.5 s alone, and 9.3–10.2 s over them.
            if (1.0..5.0).contains(&t) || (9.0..11.0).contains(&t) {
                sys[i] = voice(t, 180.0, 0.1);
            }
            mic[i] = noise() * 0.002;
            if (6.0..7.5).contains(&t) || (9.3..10.2).contains(&t) {
                mic[i] += voice(t, 140.0, 0.12);
            }
        }
        for i in delay..count {
            mic[i] += 0.2 * sys[i - delay];
        }
        let heard = vec![
            w("currently", 1.5, 2.0), w("we", 2.1, 2.3), w("start", 2.4, 2.9),
            w("okay", 6.2, 6.6), w("perfect", 6.8, 7.3), w("wait", 9.5, 9.9),
        ];
        let a = analyze(levels(&mic, rate), levels(&sys, rate)).expect("analysed");
        assert!((a.lag - 4).abs() <= 1, "the delay is found (80 ms = 4 frames): {}", a.lag);
        assert!(a.gain > 0.1 && a.gain < 0.4, "the echo's strength is found: {}", a.gain);
        let (kept, removed) = removing(&heard, levels(&mic, rate), levels(&sys, rate));
        let texts: Vec<&str> = kept.iter().map(|w| w.text.as_str()).collect();
        assert_eq!(texts, ["okay", "perfect", "wait"], "the echo is gone, my words stay, even over them");
        assert_eq!(removed, 3);

        // With headphones: nothing comes back, nothing is removed.
        let quiet: Vec<f32> = (0..count)
            .map(|i| {
                let t = i as f64 / rate;
                noise() * 0.002 + if (9.3..10.2).contains(&t) { voice(t, 140.0, 0.12) } else { 0.0 }
            })
            .collect();
        let (kept, _) = removing(&[w("wait", 9.5, 9.9)], levels(&quiet, rate), levels(&sys, rate));
        assert_eq!(kept.len(), 1, "with headphones, my words stay");
    }

    #[test]
    fn without_the_computers_sound_nothing_is_removed() {
        let words = vec![w("hello", 0.0, 0.5)];
        let (kept, removed) = removing(&words, vec![0.1; 100], Vec::new());
        assert_eq!((kept.len(), removed), (1, 0));
    }
}
