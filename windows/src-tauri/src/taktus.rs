// taktus 0.1.0: the tempo of music and where its beats fall, from the sound
// itself. A tempo and beat engine by Shakib Bin Kabir.
//
//   https://github.com/shakibbinkabir/taktus
//   https://taktus.thisissbk.com
//
// Copyright 2026 Shakib Bin Kabir. Licensed under the Apache License, Version
// 2.0 (https://www.apache.org/licenses/LICENSE-2.0), whose notice reads:
//
//   This product includes taktus, a tempo and beat engine by Shakib Bin Kabir
//   (https://github.com/shakibbinkabir/taktus).
//
// This is the library's one source file as published in 0.1.0, put here whole
// so that the app takes on no dependency. Two things are left out: the page of
// documentation at its top, with the examples it runs, and its tests. Both
// live in its repository, with what it was measured on. Nothing else is
// changed. The app uses the ear and the follower (beat.rs); the rest of the
// library comes along.

#![forbid(unsafe_code)]
// The app reaches only part of it.
#![allow(dead_code)]

use std::sync::LazyLock;

// ── Sound → onsets ───────────────────────────────────────────────────────────

/// Onset values a second: one every 10 ms.
pub const RATE: usize = 100;
/// The sound is thinned to about this many samples a second before it is looked at.
const EAR_RATE: u32 = 12_000;
/// Samples in one look at the spectrum (43 ms).
const FRAME: usize = 512;
/// Bands the spectrum is summed into, low to high, each wider than the last:
/// an octave of bass counts as much as an octave of cymbals.
const BANDS: usize = 24;
/// A rise is measured against this many looks before (30 ms): a soft
/// instrument takes that long to speak, and 10 ms back it has hardly moved.
const BACK: usize = 3;
/// Where the logarithm bends: what is this much quieter than full scale barely counts.
const GAIN: f32 = 10.0;

struct Tables {
    window: [f32; FRAME],
    turn: [(f32, f32); FRAME / 2],
    /// The same turns laid out for the transform, cosines then sines: those
    /// of the stage whose halves are `h` long sit at `h..2 * h`, side by side.
    stage: [[f32; FRAME / 2]; 2],
    /// Where each pair of samples goes before the transform (its index, bits reversed).
    swap: [u8; FRAME / 2],
    /// The first bin of each band, and one past the last band's.
    edge: [u16; BANDS + 1],
}

static TABLES: LazyLock<Box<Tables>> = LazyLock::new(|| {
    let mut t = Box::new(Tables {
        window: [0.0; FRAME],
        turn: [(0.0, 0.0); FRAME / 2],
        stage: [[0.0; FRAME / 2]; 2],
        swap: [0; FRAME / 2],
        edge: [0; BANDS + 1],
    });
    let bits = (FRAME / 2).trailing_zeros();
    for i in 0..FRAME {
        let turn = std::f32::consts::TAU * i as f32 / FRAME as f32;
        t.window[i] = 0.5 - 0.5 * turn.cos();
        if i < FRAME / 2 {
            t.turn[i] = (turn.cos(), turn.sin());
            t.swap[i] = (i.reverse_bits() >> (usize::BITS - bits)) as u8;
        }
    }
    let mut half = 1;
    while half < FRAME / 2 {
        for k in 0..half {
            (t.stage[0][half + k], t.stage[1][half + k]) = t.turn[k * (FRAME / 2 / half)];
        }
        half *= 2;
    }
    // Bins 1 to FRAME/2, a constant ratio apart, each band at least one bin.
    let top = (FRAME / 2) as f32;
    for b in 0..=BANDS {
        let want = top.powf(b as f32 / BANDS as f32).round() as u16;
        t.edge[b] = if b == 0 { 1 } else { want.max(t.edge[b - 1] + 1) };
    }
    t.edge[BANDS] = FRAME as u16 / 2 + 1;
    t
});

/// Listens: sound in, sample by sample; out, every 10 ms, how much just
/// started — the rise of the spectrum, band by band, on a log scale.
///
/// An ear holds 2.4 KB and nothing of the sound beyond its last 43 ms. One ear
/// follows one stream: after a gap in the sound, start a new one.
#[derive(Clone, Debug)]
pub struct Ear {
    /// Samples averaged into one kept sample, and samples a second.
    thin: usize,
    rate: usize,
    sum: f32,
    held: usize,
    /// Counts up to a hundredth of a second, exactly, whatever the rate.
    since: usize,
    /// The last FRAME kept samples; `at` is the oldest.
    ring: [f32; FRAME],
    at: usize,
    filled: usize,
    /// How loud each band was at the last BACK looks; `turn` is the oldest.
    last: [[f32; BANDS]; BACK],
    turn: usize,
    primed: usize,
}

impl Ear {
    /// For mono sound at `rate` samples a second (8 kHz and up).
    pub fn new(rate: u32) -> Self {
        Ear {
            thin: (rate.saturating_add(EAR_RATE / 2) / EAR_RATE).max(1) as usize,
            rate: rate.max(1) as usize,
            sum: 0.0,
            held: 0,
            since: 0,
            ring: [0.0; FRAME],
            at: 0,
            filled: 0,
            last: [[0.0; BANDS]; BACK],
            turn: 0,
            primed: 0,
        }
    }

    /// One sample in; every 10 ms of sound, an onset value out.
    ///
    /// The first value comes [`LEAD`] seconds after the sound begins. Samples
    /// are expected between -1 and 1; louder or quieter sound gives the same
    /// beat, only larger or smaller onsets.
    #[inline]
    pub fn hear(&mut self, sample: f32) -> Option<f32> {
        self.sum += sample;
        self.held += 1;
        if self.held == self.thin {
            self.ring[self.at] = self.sum / self.thin as f32;
            self.at = (self.at + 1) % FRAME;
            self.filled = (self.filled + 1).min(FRAME);
            (self.sum, self.held) = (0.0, 0);
        }
        self.since += RATE;
        if self.since < self.rate {
            return None;
        }
        self.since -= self.rate;
        if self.filled < FRAME {
            return None;
        }
        let rise = self.rise();
        // The first looks have nothing to rise from.
        self.primed += 1;
        (self.primed > BACK).then_some(rise)
    }

    fn rise(&mut self) -> f32 {
        let t = &**TABLES;
        let mut frame = [0f32; FRAME];
        // The ring from its oldest sample on, in its two straight runs.
        let (new, old) = self.ring.split_at(self.at);
        for ((v, s), w) in frame.iter_mut().zip(old.iter().chain(new)).zip(&t.window) {
            *v = s * w;
        }
        let loud = spectrum(&frame);
        let mut rise = 0.0;
        for b in 0..BANDS {
            let sum: f32 = loud[t.edge[b] as usize - 1..t.edge[b + 1] as usize - 1].iter().sum();
            let level = (1.0 + GAIN * sum).ln();
            rise += (level - self.last[self.turn][b]).max(0.0);
            self.last[self.turn][b] = level;
        }
        self.turn = (self.turn + 1) % BACK;
        rise
    }
}

/// How loud each pitch of `frame` is, from the lowest but the steady level
/// (bin 1) to the highest (bin FRAME/2).
///
/// The sound is real numbers, so a transform half the size does: the samples
/// go in two by two as one complex number each, and the two halves of the
/// answer are untangled afterwards.
fn spectrum(frame: &[f32; FRAME]) -> [f32; FRAME / 2] {
    const HALF: usize = FRAME / 2;
    let t = &**TABLES;
    let (mut re, mut im) = ([0f32; HALF], [0f32; HALF]);
    for n in 0..HALF {
        let to = t.swap[n] as usize;
        (re[to], im[to]) = (frame[2 * n], frame[2 * n + 1]);
    }
    // Stage by stage, each block's two halves and the stage's turns running
    // straight through, so that the processor takes them several at a time.
    let mut half = 1;
    while half < HALF {
        let (c, s) = (&t.stage[0][half..2 * half], &t.stage[1][half..2 * half]);
        for (re, im) in re.chunks_exact_mut(2 * half).zip(im.chunks_exact_mut(2 * half)) {
            let ((ra, rb), (ia, ib)) = (re.split_at_mut(half), im.split_at_mut(half));
            for k in 0..half {
                let (xr, xi) = (rb[k] * c[k] + ib[k] * s[k], ib[k] * c[k] - rb[k] * s[k]);
                (rb[k], ib[k]) = (ra[k] - xr, ia[k] - xi);
                ra[k] += xr;
                ia[k] += xi;
            }
        }
        half *= 2;
    }
    let mut loud = [0f32; HALF];
    for k in 1..=HALF {
        let (c, s) = if k == HALF { (-1.0, 0.0) } else { t.turn[k] };
        let (ar, ai) = (re[k % HALF], im[k % HALF]);
        let (mr, mi) = (re[HALF - k], im[HALF - k]);
        let (er, ei) = (0.5 * (ar + mr), 0.5 * (ai - mi));
        let (or, oi) = (0.5 * (ar - mr), 0.5 * (ai + mi));
        let (xr, xi) = (er + c * oi - s * or, ei - c * or - s * oi);
        loud[k - 1] = (xr * xr + xi * xi).sqrt();
    }
    loud
}

// ── Onsets → a beat ──────────────────────────────────────────────────────────

/// Tempi looked for, beats a minute.
const SLOW: f64 = 60.0;
const FAST: f64 = 200.0;
/// A period is the beat's when its first multiples all line up as well: one
/// that does not is enough to rule it out (their geometric mean is the fit).
/// That is what tells a beat from two thirds or one and a half of it.
const TEETH: usize = 6;
/// The best few periods are tried against the onsets themselves.
const TRIED: usize = 8;
/// The tempo most music is near, and how many octaves it strays: a nudge
/// between two readings that fit as well.
const USUAL: f64 = 135.0;
const SPREAD: f64 = 0.8;

/// A beat found in a stretch of onsets.
#[derive(Clone, Copy, Debug, PartialEq)]
#[non_exhaustive]
pub struct Beat {
    /// Seconds from one beat to the next.
    pub period: f64,
    /// How well the onsets keep that period (0…1).
    pub sure: f64,
    /// How much of what starts, starts on those beats (1 = no more than anywhere else).
    pub catch: f64,
    /// Seconds from the last beat to the end of the stretch.
    pub ago: f64,
}

impl Beat {
    /// The tempo, in beats a minute.
    pub fn bpm(&self) -> f64 {
        60.0 / self.period
    }
}

/// What stands out of its surroundings: each value minus the average of the
/// second around it.
fn sharpen(onsets: &[f32]) -> Vec<f32> {
    let (n, half) = (onsets.len(), (RATE / 2) as isize);
    let mut upto = Vec::with_capacity(n + 1);
    upto.push(0f64);
    for v in onsets {
        upto.push(upto[upto.len() - 1] + *v as f64);
    }
    (0..n as isize)
        .map(|i| {
            let (from, to) = (i - half, i + half + 1);
            // Past either end, the end's own value goes on.
            let before = (-from).max(0) as f64 * onsets[0] as f64;
            let after = (to - n as isize).max(0) as f64 * onsets[n - 1] as f64;
            let inside = upto[to.min(n as isize) as usize] - upto[from.max(0) as usize];
            let around = (before + inside + after) / (2 * half + 1) as f64;
            (onsets[i as usize] as f64 - around).max(0.0) as f32
        })
        .collect()
}

/// How alike the onsets are to themselves `lag` values later, for every lag up to `most`.
fn echo(o: &[f32], most: usize) -> Vec<f64> {
    let n = o.len();
    (0..=most.min(n.saturating_sub(2)))
        .map(|lag| {
            // Eight sums side by side: the processor adds to them together, waiting for none.
            let ((a, a_rest), (b, b_rest)) = (o[..n - lag].as_chunks::<8>(), o[lag..].as_chunks::<8>());
            let rest: f64 = a_rest.iter().zip(b_rest).map(|(x, y)| *x as f64 * *y as f64).sum();
            let mut sums = [0f64; 8];
            for (x, y) in a.iter().zip(b) {
                for i in 0..8 {
                    sums[i] += x[i] as f64 * y[i] as f64;
                }
            }
            (sums.iter().sum::<f64>() + rest) / (n - lag) as f64
        })
        .collect()
}

/// `echo` between two whole lags.
fn between(a: &[f64], lag: f64) -> f64 {
    let low = lag as usize;
    if low + 1 >= a.len() {
        return 0.0;
    }
    let part = lag - low as f64;
    a[low] * (1.0 - part) + a[low + 1] * part
}

/// A beat being followed stays where it was due while the onsets there are
/// at least this much of the most gathered anywhere.
const STAYS: f64 = 0.6;

/// The ear says something started a little after it did: its look is 43 ms
/// wide, a sound shows once it is well inside, and a rise is taken against
/// 30 ms before. Measured on clicks.
const HEARD_LATE: f64 = 0.022;

/// Beats `period` apart laid over (sharpened) onsets: how much they catch, and
/// how long before the end the last one fell.
fn pulse(o: &[f32], period: f64) -> (f64, f64) {
    pulse_near(o, period, None)
}

/// The same, for a beat already followed: one was due `due` seconds before
/// the end. If the onsets still gather near there, that is where it is; only
/// when they clearly gather elsewhere does the beat move.
fn pulse_near(o: &[f32], period: f64, due: Option<f64>) -> (f64, f64) {
    let lag = period * RATE as f64;
    // 20 ms cells.
    let cells = ((lag / 2.0).round() as usize).clamp(8, 128);
    let mut fold = [0f64; 128];
    let n = o.len();
    for (i, v) in o.iter().enumerate() {
        let back = ((n - 1 - i) as f64) % lag;
        fold[((back / lag * cells as f64) as usize).min(cells - 1)] += *v as f64;
    }
    let (mut best, mut most, mut total) = (0, f64::MIN, 0.0);
    for k in 0..cells {
        let spread = fold[k] + 0.5 * (fold[(k + cells - 1) % cells] + fold[(k + 1) % cells]);
        total += spread;
        if spread > most {
            (best, most) = (k, spread);
        }
    }
    if total <= 0.0 {
        return (0.0, 0.0);
    }
    if let Some(due) = due {
        let spread = |k: usize| fold[k] + 0.5 * (fold[(k + cells - 1) % cells] + fold[(k + 1) % cells]);
        let at = ((due - HEARD_LATE).rem_euclid(period) / period * cells as f64) as usize % cells;
        let reach = (cells / 6).max(1);
        let near =
            (0..=2 * reach).map(|d| (at + cells + d - reach) % cells).max_by(|x, y| spread(*x).total_cmp(&spread(*y)));
        if let Some(k) = near.filter(|k| spread(*k) >= STAYS * most) {
            (best, most) = (k, spread(k));
        }
    }
    // Where in its cell: the balance of the best cell and its two neighbours.
    let (before, after) = (fold[(best + cells - 1) % cells], fold[(best + 1) % cells]);
    let lean = (after - before) / (before + fold[best] + after).max(f64::MIN_POSITIVE);
    let ago = (best as f64 + 0.5 + lean) / cells as f64 * period + HEARD_LATE;
    (most / total * cells as f64 / 2.0, ago.rem_euclid(period))
}

/// The beat in `onsets` (one value per 10 ms, the newest last), if they have one.
///
/// For one stretch of 8 to 16 seconds; less than 4 seconds is too short to
/// say, and a longer stretch is [`tempo_of`]'s. A reading is always given when
/// some period fits at all: whether to believe it is in its `sure` and `catch`.
pub fn beat_of(onsets: &[f32]) -> Option<Beat> {
    if onsets.len() < 4 * RATE {
        return None;
    }
    let o = sharpen(onsets);
    // About their own average, so that sound with no pattern echoes as nothing.
    let mean = o.iter().sum::<f32>() / o.len() as f32;
    let level: Vec<f32> = o.iter().map(|v| v - mean).collect();
    let a = echo(&level, (RATE as f64 * 60.0 / SLOW) as usize * TEETH + 2);
    if a.len() < 3 || a[0] <= 0.0 {
        return None;
    }
    // Every period from the fastest to the slowest, a quarter of an onset apart.
    let first = RATE as f64 * 60.0 / FAST;
    let count = ((RATE as f64 * 60.0 / SLOW - first) * 4.0) as usize + 1;
    let fits: Vec<f64> = (0..count)
        .map(|i| {
            let lag = first + i as f64 * 0.25;
            let log: f64 = (1..=TEETH).map(|k| (between(&a, lag * k as f64) / a[0]).max(1e-6).ln()).sum();
            (log / TEETH as f64).exp()
        })
        .collect();
    let mut peaks: Vec<usize> = (1..count - 1).filter(|&i| fits[i] >= fits[i - 1] && fits[i] > fits[i + 1]).collect();
    peaks.sort_by(|x, y| fits[*y].total_cmp(&fits[*x]));
    peaks.truncate(TRIED);
    // Each with its period, how well it fits, and that weighed by how usual its tempo is.
    let tried: Vec<(f64, f64, f64)> = peaks
        .iter()
        .map(|&i| {
            // The top of the peak lies between two of the periods tried: a
            // parabola through it and its neighbours says where, ten times finer.
            let (below, at, above) = (fits[i - 1], fits[i], fits[i + 1]);
            let bend = below - 2.0 * at + above;
            let nudge = if bend < 0.0 { (0.5 * (below - above) / bend).clamp(-0.5, 0.5) } else { 0.0 };
            let period = (first + (i as f64 + nudge) * 0.25) / RATE as f64;
            let off = ((60.0 / period) / USUAL).log2() / SPREAD;
            (period, at, at * (-0.5 * off * off).exp())
        })
        .collect();
    let mut best = (0..tried.len()).max_by(|x, y| tried[*x].2.total_cmp(&tried[*y].2))?;
    // How usual a tempo is may choose between a beat and its half or double.
    // Between two tempi four to three apart it has no say: one of them is a
    // rhythm laid across the beat, and the onsets tell which — how well each
    // fits, times how much of what starts falls on it.
    let mut caught: Vec<Option<(f64, f64)>> = vec![None; tried.len()];
    let mut catch = |c: usize| *caught[c].get_or_insert_with(|| pulse(&o, tried[c].0));
    for _ in 0..3 {
        let stands = tried[best].1 * catch(best).0;
        let across = (0..tried.len()).find(|&c| {
            let ratio = tried[best].0 / tried[c].0;
            [4.0 / 3.0, 0.75].iter().any(|m| (ratio / m - 1.0).abs() < 0.04) && tried[c].1 * catch(c).0 > stands
        });
        match across {
            Some(c) => best = c,
            None => break,
        }
    }
    let (period, sure, _) = tried[best];
    let (catch, ago) = catch(best);
    Some(Beat { period, sure, catch, ago })
}

/// The beat of a long stretch — half a minute, a whole song. Many readings of
/// sixteen seconds each are pooled, since a tempo that wavers blurs one long
/// reading but not the vote of short ones; the long reading still says which
/// level is the beat when it is that pulse's own.
///
/// A stretch under 20 seconds is read as [`beat_of`] reads it.
pub fn tempo_of(onsets: &[f32]) -> Option<Beat> {
    let whole = beat_of(onsets);
    let (span, step) = (KEEP * RATE, 4 * RATE);
    if onsets.len() < span + step {
        return whole;
    }
    let votes: Vec<Beat> =
        (0..=onsets.len() - span).step_by(step).filter_map(|from| beat_of(&onsets[from..from + span])).collect();
    // The tempo most of them agree on, each counting for how well it fits.
    let (mut most, mut pooled) = (0.0, 0.0);
    for v in &votes {
        let near = votes.iter().filter(|w| (w.bpm() - v.bpm()).abs() / v.bpm() <= 0.04);
        let (weight, sum) = near.fold((0.0, 0.0), |(weight, sum), w| (weight + w.sure, sum + w.bpm() * w.sure));
        if weight > most {
            (most, pooled) = (weight, sum / weight);
        }
    }
    if most <= 0.0 {
        return whole;
    }
    if let Some(w) = whole.filter(|w| same_tempo(w.bpm(), pooled, 0.04)) {
        return Some(w);
    }
    let period = 60.0 / pooled;
    let (catch, ago) = beats_at(onsets, period);
    Some(Beat { period, sure: most / votes.len() as f64, catch, ago })
}

/// How long after the sound begins the ear gives its first value, seconds
/// (for sound at 11 kHz and above): a first look of 43 ms, then three more
/// before it has something to measure a rise against.
pub const LEAD: f64 = 0.08;
/// How strictly the beats of a stretch keep to the tempo: the price of a gap
/// that is not one period long.
const TIGHT: f64 = 200.0;

/// Every beat of a stretch heard from the start of the sound, in seconds from
/// that start, for beats about `period` seconds apart: `tempo_of` gives the
/// period, and half or double it counts the same music at another level. Of
/// all the ways of stepping through the onsets about one period at a time,
/// the one that lands on the most that starts while keeping its steps even
/// (after Ellis, 2007). It follows a tempo that drifts, and it is for a
/// stretch already heard: a song as it plays is the `Follower`'s.
pub fn beats_of(onsets: &[f32], period: f64) -> Vec<f64> {
    let n = onsets.len();
    // A period too short to step by, or longer than the stretch, has no beats in it.
    if !(period * RATE as f64 >= 2.0 && period * (RATE as f64) < n as f64) {
        return Vec::new();
    }
    let o = sharpen(onsets);
    let mean = o.iter().sum::<f32>() / n as f32;
    let spread = (o.iter().map(|v| (v - mean) * (v - mean)).sum::<f32>() / n as f32).sqrt();
    // Silence, or onsets that are not numbers: nothing to land on.
    if !(spread > 0.0 && spread.is_finite()) {
        return Vec::new();
    }
    let period = period * RATE as f64;
    let (nearest, furthest) = ((period / 2.0).round().max(1.0) as usize, (period * 2.0).round() as usize);
    // What a step of each length costs.
    let price: Vec<f64> = (nearest..=furthest).map(|gap| -TIGHT * (gap as f64 / period).ln().powi(2)).collect();
    let mut score: Vec<f64> = o.iter().map(|v| (*v / spread) as f64).collect();
    let mut before = vec![usize::MAX; n];
    for t in nearest..n {
        let (mut best, mut from) = (0.0, usize::MAX);
        for (gap, cost) in (nearest..=furthest.min(t)).zip(&price) {
            let reached = score[t - gap] + cost;
            if reached > best {
                (best, from) = (reached, t - gap);
            }
        }
        if from != usize::MAX {
            score[t] += best;
            before[t] = from;
        }
    }
    // The last beat is the best place to end in the last period; the rest is the way back.
    let tail = (period as usize).clamp(1, n);
    let mut at = (n - tail..n).max_by(|a, b| score[*a].total_cmp(&score[*b])).unwrap_or(n - 1);
    let mut beats = Vec::new();
    while at != usize::MAX {
        beats.push(LEAD - HEARD_LATE + at as f64 / RATE as f64);
        at = before[at];
    }
    beats.reverse();
    beats
}

/// Where beats of a known `period` (in seconds) fall in `onsets`: how much
/// they catch, as [`Beat::catch`], and how many seconds before the end of the
/// stretch the last one fell.
///
/// For a tempo known from elsewhere, a catalogue or a tag: a few seconds of
/// onsets then say where its beats are. Nothing caught, `(0.0, 0.0)`, when
/// the period is not one or the onsets are silent.
pub fn beats_at(onsets: &[f32], period: f64) -> (f64, f64) {
    if !(period > 0.0 && period.is_finite()) {
        return (0.0, 0.0);
    }
    pulse(&sharpen(onsets), period)
}

/// The same tempo, give or take `slack`, or one twice the other: a beat is as
/// true counted in halves.
fn same_tempo(a: f64, b: f64, slack: f64) -> bool {
    [0.5, 1.0, 2.0].iter().any(|m| (a * m - b).abs() / b < slack)
}

// ── Following a song ─────────────────────────────────────────────────────────

/// The longest stretch of onsets looked at, seconds.
const KEEP: usize = 16;
/// A first reading waits for this much sound; then one every `EVERY` seconds.
const FIRST: usize = 8;
const EVERY: usize = 2;
/// Two readings in a row must agree this closely, and each be clear enough
/// for how much sound it rests on: (seconds heard, how sure, how much caught).
/// Measured on some 1,700 annotated recordings of dance music and of ten other
/// genres, readings this clear are right 99 times in 100 (95 on electronic
/// music); on recordings never used to set these, 98 (Hainsworth) and 87
/// (SMC, mostly music with no steady beat). Sound with no beat in it catches
/// about 0.7.
const AGREE: f64 = 0.02;
const CLEAR: [(usize, f64, f64); 3] = [(16, 0.10, 1.2), (12, 0.12, 1.3), (0, 0.20, 1.5)];
/// A beat already known is still there when a look catches this much.
const CAUGHT: f64 = 1.0;

/// Whether a reading resting on `seconds` of sound is clear enough to act on.
fn clear(reading: Beat, seconds: usize) -> bool {
    let (_, sure, caught) = CLEAR.iter().find(|c| seconds >= c.0).copied().unwrap_or(CLEAR[2]);
    reading.sure >= sure && reading.catch >= caught
}
/// Without a beat after this long, the ear rests before trying again.
const GIVE_UP: usize = 30;
const TRY_AGAIN: f64 = 20.0;
/// A look at a beat already known lasts this long, and comes this long after
/// the last — longer each time it finds the beat where it should be.
const LOOK: usize = 6;
/// Every second look is this long, and read afresh: a beat found wrong (in a
/// song's opening bars, say) is found out.
const AFRESH: usize = 12;
const REST: f64 = 10.0;
const LONGEST_REST: f64 = 60.0;
/// A beat seen within this of where it was due (in beats) confirms the tempo;
/// further, the tempo is taken to have moved, and is looked for this many
/// half-percents either side.
const DUE: f64 = 0.2;
const DRIFT: i32 = 8;

/// What is made of a song as it plays. Times are seconds on the caller's
/// clock, whichever it is, as long as it only goes forward.
///
/// Ask [`listens`](Follower::listens) before fetching sound, give what the
/// [`Ear`] makes of it to [`hear`](Follower::hear), and read
/// [`beat`](Follower::beat) when `hear` says it changed. A new song is a new
/// follower; a seek or a pause is [`moved`](Follower::moved).
#[derive(Clone, Debug)]
pub struct Follower {
    /// The onsets of this spell of listening, the newest last.
    heard: Vec<f32>,
    /// Onsets heard since the spell began, and at its last reading.
    spell: usize,
    read: usize,
    listening: bool,
    /// When to listen again.
    wake: f64,
    rest: f64,
    last: Option<Beat>,
    /// The beat: its period, and the time of one.
    lock: Option<(f64, f64)>,
    /// Confirmed on a full stretch of sound. Until then it is told, but still listened to.
    settled: bool,
    misses: u8,
    /// Looks taken at a settled beat: every second is a long one, read afresh.
    looks: u32,
    /// Never rests: the beat is looked at every two seconds, so that it stays
    /// on the music's own even when a band's tempo wavers. Costs the ear all
    /// the time instead of a fifth of it.
    pub attentive: bool,
    /// Seconds listened in all.
    pub listened: f64,
}

impl Default for Follower {
    fn default() -> Self {
        Follower {
            heard: Vec::new(),
            spell: 0,
            read: 0,
            listening: true,
            wake: 0.0,
            rest: REST,
            last: None,
            lock: None,
            settled: false,
            looks: 0,
            attentive: false,
            misses: 0,
            listened: 0.0,
        }
    }
}

impl Follower {
    /// Whether the sound is wanted at `now`: its source need only be open
    /// then. After a rest, start a new [`Ear`]: the old one remembers sound
    /// from before.
    pub fn listens(&mut self, now: f64) -> bool {
        if !self.listening && now >= self.wake {
            self.begin();
        }
        self.listening
    }

    /// How long until the sound is wanted again; none while listening.
    pub fn sleeps(&self, now: f64) -> Option<f64> {
        (!self.listening).then(|| (self.wake - now).max(0.0))
    }

    /// The beat as known: seconds from one to the next, and the time of one
    /// (on the clock `hear` was given). Any other beat is a whole number of
    /// periods from it. None while no beat is clear enough to tell.
    pub fn beat(&self) -> Option<(f64, f64)> {
        self.lock
    }

    /// The song went somewhere else (a seek, a pause): the tempo holds, where
    /// its beats fall has to be found again.
    pub fn moved(&mut self) {
        if self.lock.is_some() {
            self.misses = 1;
        }
        self.begin();
    }

    fn begin(&mut self) {
        self.heard.clear();
        (self.spell, self.read, self.listening, self.last) = (0, 0, true, None);
    }

    fn sleep(&mut self, now: f64, rest: f64) {
        self.listening = false;
        self.wake = now + rest;
        // The sound heard is not held while resting.
        self.heard = Vec::new();
    }

    /// Onsets heard, the last of them at `now`. True when the beat changed:
    /// found, moved, said more exactly, or lost.
    pub fn hear(&mut self, onsets: &[f32], now: f64) -> bool {
        if !self.listening || onsets.is_empty() {
            return false;
        }
        self.heard.extend_from_slice(onsets);
        let over = self.heard.len().saturating_sub(KEEP * RATE);
        self.heard.drain(..over);
        self.spell += onsets.len();
        self.listened += onsets.len() as f64 / RATE as f64;
        match self.lock {
            Some((period, beat)) if self.settled => self.check(period, beat, now),
            _ => self.seek(now),
        }
    }

    /// No settled beat yet: a reading every two seconds. Two in a row that
    /// agree give the beat, told at once; the listening goes on to a full
    /// stretch, since a longer one reads truer and may say otherwise.
    fn seek(&mut self, now: f64) -> bool {
        if self.spell < FIRST * RATE || self.spell - self.read < EVERY * RATE {
            return false;
        }
        self.read = self.spell;
        let reading = beat_of(&self.heard);
        let before = std::mem::replace(&mut self.last, reading);
        let mut told = false;
        if let (Some(a), Some(b)) = (before, reading) {
            let heard = self.heard.len() / RATE;
            if clear(a, heard.saturating_sub(EVERY)) && clear(b, heard) && same_tempo(a.bpm(), b.bpm(), AGREE) {
                self.lock = Some((b.period, now - b.ago));
                told = true;
            }
        }
        if self.spell >= KEEP * RATE {
            // A full stretch has been heard. What it says, if clear, is the
            // beat, whatever a shorter one said before.
            if let Some(b) = reading.filter(|b| clear(*b, KEEP)) {
                if self.lock.is_none_or(|(period, _)| !same_tempo(b.bpm(), 60.0 / period, AGREE)) {
                    self.lock = Some((b.period, now - b.ago));
                    told = true;
                }
            }
        }
        if self.lock.is_some() && self.spell >= KEEP * RATE {
            (self.settled, self.misses, self.rest) = (true, 0, REST);
            if self.attentive {
                self.spell = (LOOK - EVERY) * RATE;
            } else {
                self.sleep(now, REST);
            }
        } else if self.spell >= GIVE_UP * RATE {
            // Nothing clear in all this: the beat that was told, if any, is taken back.
            told |= self.lock.take().is_some();
            self.sleep(now, TRY_AGAIN);
        }
        told
    }

    /// A beat is known: after a short look, where is it now? Looked for near
    /// the tempo already known, since a band's drifts a little.
    fn check(&mut self, period: f64, beat: f64, now: f64) -> bool {
        // Resting between looks, every second one is long. Never resting, all
        // of the last stretch is at hand: every fifth look reads it.
        let afresh = if self.attentive { self.looks % 5 == 4 } else { self.looks % 2 == 1 };
        if self.spell < if afresh && !self.attentive { AFRESH } else { LOOK } * RATE {
            return false;
        }
        self.looks += 1;
        if afresh {
            // Read as if nothing were known. A clear reading of another tempo
            // unsettles the beat: the listening goes on until two agree again.
            if let Some(b) = beat_of(&self.heard) {
                if clear(b, self.heard.len() / RATE) && !same_tempo(b.bpm(), 60.0 / period, 2.0 * AGREE) {
                    (self.settled, self.last, self.read) = (false, Some(b), self.spell);
                    return false;
                }
            }
        }
        // The last few seconds: where the beat is now.
        let o = sharpen(&self.heard[self.heard.len().saturating_sub(LOOK * RATE)..]);
        let (mut catch, mut near, mut ago) = (0.0, period, 0.0);
        // When a beat was due, counted back from now.
        let due = (now - beat).rem_euclid(period);
        for step in -DRIFT..=DRIFT {
            let tried = period * (1.0 + step as f64 * 0.005);
            let (caught, back) = pulse_near(&o, tried, self.attentive.then_some(due));
            if caught > catch {
                (catch, near, ago) = (caught, tried, back);
            }
        }
        if catch < CAUGHT {
            // No beat to be seen in this look. Twice, and it is gone: start over.
            self.misses += 1;
            if self.misses >= if self.attentive { 5 } else { 2 } {
                (self.lock, self.settled) = (None, false);
                self.begin();
                return true;
            }
            if self.attentive {
                self.spell = (LOOK - EVERY) * RATE;
            } else {
                self.rest = REST;
                self.sleep(now, REST / 2.0);
            }
            return false;
        }
        let seen = now - ago;
        let beats = ((seen - beat) / period).round();
        let late = seen - (beat + beats * period);
        if self.attentive {
            // Looked at this often, the beat is simply where it is seen, and
            // the tempo eases towards what the last seconds say.
            self.lock = Some((0.75 * period + 0.25 * near, seen));
        } else if late.abs() <= DUE * period && beats >= 1.0 {
            // Where it was due, give or take: that much, over that many beats,
            // says how long a beat really is. And the next look can wait longer.
            self.lock = Some(((seen - beat) / beats, seen));
            self.rest = (self.rest * 2.0).min(LONGEST_REST);
        } else {
            // Not where it was due: the tempo moved. The beat is taken as seen.
            self.lock = Some((near, seen));
            self.rest = REST;
        }
        self.misses = 0;
        if self.attentive {
            // No rest: the same again once two more seconds have been heard.
            self.spell = (LOOK - EVERY) * RATE;
        } else {
            self.sleep(now, self.rest);
        }
        true
    }
}
