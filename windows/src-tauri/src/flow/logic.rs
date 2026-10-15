// The key logic of Flow dictation, with nothing from the OS in it. Port of
// FlowKeyLogic.swift.
//
// - Hold the key: Coucou listens. Release it: the words are pasted where you type.
// - Two quick taps: hands-free, until the next tap.
// - Esc, or another key pressed while the key is held (a shortcut such as
//   Ctrl+C), cancels.
//
// Listening starts on the first press, so a word said right away is not lost; a
// press too short to be a hold waits a moment for the second tap, and is
// dropped if none comes.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Phase {
    Idle,
    Holding { since: f64 },
    TapWait { until: f64 },
    Locked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Action {
    None,
    /// Open the microphone and show the pill.
    Start,
    /// Hands-free: keep listening after the key is released.
    Lock,
    /// Stop listening and paste what was said.
    Finish,
    /// Stop listening and paste nothing.
    Cancel,
    /// The last listen was dropped (too short) and a new one begins.
    Restart,
}

/// A press shorter than this is a tap.
pub const HOLD_THRESHOLD: f64 = 0.30;
/// The second tap of a double tap comes within this.
pub const DOUBLE_TAP_WINDOW: f64 = 0.40;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct KeyLogic {
    phase: Phase,
}

impl Default for KeyLogic {
    fn default() -> Self {
        Self { phase: Phase::Idle }
    }
}

impl KeyLogic {
    #[cfg(test)]
    pub fn phase(&self) -> Phase {
        self.phase
    }

    pub fn is_active(&self) -> bool {
        self.phase != Phase::Idle
    }

    pub fn key_down(&mut self, t: f64) -> Action {
        match self.phase {
            Phase::Idle => {
                self.phase = Phase::Holding { since: t };
                Action::Start
            }
            Phase::Holding { .. } => Action::None, // key repeat
            Phase::TapWait { until } => {
                if t <= until {
                    self.phase = Phase::Locked;
                    Action::Lock
                } else {
                    // The wait ran out unnoticed: start afresh.
                    self.phase = Phase::Holding { since: t };
                    Action::Restart
                }
            }
            Phase::Locked => {
                self.phase = Phase::Idle;
                Action::Finish
            }
        }
    }

    pub fn key_up(&mut self, t: f64) -> Action {
        let Phase::Holding { since } = self.phase else { return Action::None };
        if t - since >= HOLD_THRESHOLD {
            self.phase = Phase::Idle;
            return Action::Finish;
        }
        self.phase = Phase::TapWait { until: t + DOUBLE_TAP_WINDOW };
        Action::None
    }

    /// Another key while the key is held, or between the two taps: it was a
    /// shortcut, not dictation.
    pub fn other_key(&mut self) -> Action {
        match self.phase {
            Phase::Holding { .. } | Phase::TapWait { .. } => {
                self.phase = Phase::Idle;
                Action::Cancel
            }
            Phase::Idle | Phase::Locked => Action::None,
        }
    }

    pub fn escape(&mut self) -> Action {
        if self.phase == Phase::Idle {
            return Action::None;
        }
        self.phase = Phase::Idle;
        Action::Cancel
    }

    /// Called when the double-tap window may have run out.
    pub fn tick(&mut self, t: f64) -> Action {
        match self.phase {
            Phase::TapWait { until } if t > until => {
                self.phase = Phase::Idle;
                Action::Cancel
            }
            _ => Action::None,
        }
    }

    /// Hands-free straight away (the pill's microphone button).
    pub fn lock(&mut self) {
        self.phase = Phase::Locked;
    }

    /// The listen ended on its own (no microphone, nothing heard…).
    pub fn reset(&mut self) {
        self.phase = Phase::Idle;
    }
}

/// The key held to dictate. A key that is a modifier on its own, so holding it
/// does nothing in any app.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum FlowKey {
    #[default]
    RightCtrl,
    RightAlt,
    RightShift,
    LeftCtrlSuper,
}

impl FlowKey {
    /// How the key is written in the interface (the same in every language).
    pub fn label(self) -> &'static str {
        match self {
            FlowKey::RightCtrl => "Right Ctrl",
            FlowKey::RightAlt => "Right Alt",
            FlowKey::RightShift => "Right Shift",
            FlowKey::LeftCtrlSuper => {
                if cfg!(windows) {
                    "Ctrl + Win"
                } else {
                    "Ctrl + Super"
                }
            }
        }
    }
}

/// Frequency bands for the pill's dots: low notes on the left, high on the right.
pub mod bands {
    pub const COUNT: usize = 9;
    pub const LOW_HZ: f64 = 90.0;
    pub const HIGH_HZ: f64 = 7000.0;

    /// The `count + 1` band edges in Hz, spaced evenly on a log scale.
    pub fn edges(count: usize) -> Vec<f64> {
        (0..=count).map(|i| LOW_HZ * (HIGH_HZ / LOW_HZ).powf(i as f64 / count as f64)).collect()
    }

    /// The FFT bins [from, to) of each band, for `fft_size` samples at `sample_rate`.
    /// Each band has at least one bin.
    pub fn bin_ranges(fft_size: usize, sample_rate: f64, count: usize) -> Vec<(usize, usize)> {
        let bin_hz = sample_rate / fft_size as f64;
        let max_bin = fft_size / 2;
        let e = edges(count);
        let mut out = Vec::with_capacity(count);
        let mut last = 1;
        for i in 0..count {
            let from = last.max((e[i] / bin_hz).floor() as usize);
            let to = max_bin.min((from + 1).max((e[i + 1] / bin_hz).ceil() as usize));
            out.push((from, to));
            last = to;
        }
        out
    }

    /// A band's power in dB → 0…1 for the dot's height: silence stays low, a
    /// normal voice fills it.
    pub fn level(db: f64) -> f64 {
        let (floor, ceiling) = (-78.0, -30.0);
        ((db - floor) / (ceiling - floor)).clamp(0.0, 1.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hold_then_release_pastes() {
        let mut k = KeyLogic::default();
        assert_eq!(k.key_down(0.0), Action::Start);
        assert_eq!(k.key_down(0.1), Action::None); // key repeat
        assert_eq!(k.key_up(1.2), Action::Finish);
        assert!(!k.is_active());
    }

    #[test]
    fn two_quick_taps_go_hands_free_and_a_third_pastes() {
        let mut k = KeyLogic::default();
        assert_eq!(k.key_down(0.0), Action::Start);
        assert_eq!(k.key_up(0.1), Action::None);
        assert_eq!(k.key_down(0.3), Action::Lock);
        assert_eq!(k.key_up(0.35), Action::None);
        assert_eq!(k.phase(), Phase::Locked);
        assert_eq!(k.key_down(5.0), Action::Finish);
    }

    #[test]
    fn a_lone_tap_is_dropped_once_the_window_runs_out() {
        let mut k = KeyLogic::default();
        k.key_down(0.0);
        k.key_up(0.1);
        assert_eq!(k.tick(0.3), Action::None);
        assert_eq!(k.tick(0.6), Action::Cancel);
        assert!(!k.is_active());
        // A press after an unnoticed timeout starts afresh.
        let mut k = KeyLogic::default();
        k.key_down(0.0);
        k.key_up(0.1);
        assert_eq!(k.key_down(2.0), Action::Restart);
    }

    #[test]
    fn a_shortcut_or_esc_cancels() {
        let mut k = KeyLogic::default();
        k.key_down(0.0);
        assert_eq!(k.other_key(), Action::Cancel);
        let mut k = KeyLogic::default();
        k.lock();
        assert_eq!(k.other_key(), Action::None); // typing while hands-free is fine
        assert_eq!(k.escape(), Action::Cancel);
        assert_eq!(k.escape(), Action::None);
    }

    #[test]
    fn bands_cover_the_voice_from_low_to_high() {
        let e = bands::edges(9);
        assert_eq!(e.len(), 10);
        assert!((e[0] - 90.0).abs() < 1e-9 && (e[9] - 7000.0).abs() < 1e-6);
        let r = bands::bin_ranges(512, 16000.0, 9);
        assert_eq!(r.len(), 9);
        for (i, (from, to)) in r.iter().enumerate() {
            assert!(to > from, "band {i} is empty");
            if i > 0 {
                assert_eq!(*from, r[i - 1].1);
            }
        }
        assert_eq!(bands::level(-100.0), 0.0);
        assert_eq!(bands::level(0.0), 1.0);
    }
}
