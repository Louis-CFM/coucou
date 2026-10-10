// The beat, by ear.
//
// Mochi dances at 112 beats a minute whatever plays. Where the sound can be
// tapped (Windows: what the default output plays, see `tap`), a few seconds of
// it give the song's own tempo and where its beats fall. The listening itself
// is taktus (taktus.rs), a tempo and beat engine by Shakib Bin Kabir; what is
// here is how the app feeds it and what it makes of the answer.
//
// Nothing of the sound is kept or sent anywhere: as it comes it is reduced to
// "how much just started", a hundred values a second, and those are all that is
// looked at. And it is cheap on purpose: the tap is open a few seconds at a
// time, not for the whole song. Once a tempo is found twice over, a short look
// now and then keeps it true, and each look says more exactly how long a beat is.

// Each OS reaches only its own part, and the tests all of it.
#![allow(dead_code)]

pub use crate::taktus::{Ear, Follower};

/// The tempo Mochi dances at: the beat, or half or twice it, whichever falls
/// in the range a bounce looks right in. 0 for a period that is not one.
pub fn dance_tempo(period: f64) -> f64 {
    if !(period > 0.0 && period.is_finite()) {
        return 0.0;
    }
    let mut bpm = 60.0 / period;
    while bpm < 80.0 {
        bpm *= 2.0;
    }
    while bpm >= 160.0 {
        bpm /= 2.0;
    }
    bpm
}

// ── Windows: what the output plays ───────────────────────────────────────────

#[cfg(windows)]
pub mod tap {
    use super::Ear;
    use std::sync::LazyLock;
    use windows::Win32::Media::Audio::{
        eMultimedia, eRender, IAudioCaptureClient, IAudioClient, IMMDeviceEnumerator, MMDeviceEnumerator,
        AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK,
    };
    use windows::Win32::System::Com::{CoCreateInstance, CoIncrementMTAUsage, CoTaskMemFree, CLSCTX_ALL};

    /// Room for this much sound between two reads (100 ns units): read ten times
    /// a second, three reads can be late.
    const ROOM: i64 = 3_000_000;
    /// AUDCLNT_BUFFERFLAGS_SILENT: the packet is silence, whatever its bytes say.
    const SILENT: u32 = 2;

    /// What the default output plays, for as long as this lives. Only its onsets
    /// leave here; the sound itself is never held.
    // ponytail: the whole output, not Spotify alone, so another app's sound
    // blurs the reading. Windows can tap one process (ActivateAudioInterfaceAsync
    // with a process loopback): worth its hundred lines only if that matters.
    pub struct Tap {
        client: IAudioClient,
        capture: IAudioCaptureClient,
        channels: usize,
        ear: Ear,
    }

    impl Tap {
        pub fn open() -> Option<Tap> {
            // COM for every thread that asks, for as long as the app runs.
            static COM: LazyLock<()> = LazyLock::new(|| unsafe {
                let _ = CoIncrementMTAUsage();
            });
            LazyLock::force(&COM);
            unsafe {
                let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
                let client: IAudioClient =
                    devices.GetDefaultAudioEndpoint(eRender, eMultimedia).ok()?.Activate(CLSCTX_ALL, None).ok()?;
                let format = client.GetMixFormat().ok()?;
                let (rate, channels, bits) =
                    ((*format).nSamplesPerSec, (*format).nChannels as usize, (*format).wBitsPerSample);
                let started = client
                    .Initialize(AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, ROOM, 0, format, None)
                    .and_then(|_| client.GetService::<IAudioCaptureClient>())
                    .and_then(|capture| client.Start().map(|_| capture));
                CoTaskMemFree(Some(format as *const _));
                // The shared mix is 32-bit float; anything else is not read.
                if bits != 32 || channels == 0 {
                    return None;
                }
                Some(Tap { capture: started.ok()?, client, channels, ear: Ear::new(rate) })
            }
        }

        /// What was played since the last read, as onsets added to `out`.
        pub fn read(&mut self, out: &mut Vec<f32>) {
            unsafe {
                while self.capture.GetNextPacketSize().is_ok_and(|n| n > 0) {
                    let (mut data, mut frames, mut flags) = (std::ptr::null_mut(), 0u32, 0u32);
                    if self.capture.GetBuffer(&mut data, &mut frames, &mut flags, None, None).is_err() {
                        return;
                    }
                    let samples = std::slice::from_raw_parts(data as *const f32, frames as usize * self.channels);
                    let right = self.channels.min(2) - 1;
                    for frame in samples.chunks_exact(self.channels) {
                        let sample = if flags & SILENT != 0 { 0.0 } else { (frame[0] + frame[right]) * 0.5 };
                        out.extend(self.ear.hear(sample));
                    }
                    let _ = self.capture.ReleaseBuffer(frames);
                }
            }
        }
    }

    impl Drop for Tap {
        fn drop(&mut self) {
            unsafe {
                let _ = self.client.Stop();
            }
        }
    }
}

// ── Tests ────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn he_dances_in_one_range_whatever_level_the_beat_was_read_at() {
        for (read, danced) in [(87.0, 87.0), (174.0, 87.0), (60.0, 120.0), (128.0, 128.0), (199.0, 99.5), (79.9, 159.8)] {
            assert!((dance_tempo(60.0 / read) - danced).abs() < 1e-9, "{read} read: danced at {}", dance_tempo(60.0 / read));
        }
        for none in [0.0, -0.5, f64::NAN, f64::INFINITY] {
            assert_eq!(dance_tempo(none), 0.0);
        }
    }

    /// The library as it is fed here: sound a tenth of a second at a time,
    /// through the ear, to the follower. Its own tests are in its repository;
    /// this one says it is all there and answers.
    #[test]
    fn a_drum_is_followed_to_its_tempo_and_rested_from() {
        let (rate, bpm) = (12_000usize, 104.0);
        let period = 60.0 / bpm;
        let sound: Vec<f32> = (0..rate * 40)
            .map(|i| {
                let since = (i as f64 / rate as f64).rem_euclid(period);
                if since < 0.06 { ((since * std::f64::consts::TAU * 90.0).sin() * (1.0 - since / 0.06)) as f32 * 0.8 } else { 0.0 }
            })
            .collect();
        let (mut ear, mut follower, mut told) = (Ear::new(rate as u32), Follower::default(), 0);
        for (i, chunk) in sound.chunks(rate / 10).enumerate() {
            let now = (i + 1) as f64 * 0.1;
            if !follower.listens(now) {
                ear = Ear::new(rate as u32);
                continue;
            }
            let heard: Vec<f32> = chunk.iter().filter_map(|s| ear.hear(*s)).collect();
            told += follower.hear(&heard, now) as usize;
        }
        let (found, beat) = follower.beat().expect("a beat");
        assert!(told >= 2 && (dance_tempo(found) - bpm).abs() < 0.5, "told {told} times, dances at {}", dance_tempo(found));
        // One of its beats falls on a drum, give or take 40 ms.
        let off = (beat + period / 2.0).rem_euclid(period) - period / 2.0;
        assert!(off.abs() < 0.04, "{:.0} ms from a drum", off * 1000.0);
        assert!(follower.listened < 30.0, "listened {:.0} s of 40", follower.listened);
    }

    /// By hand, on a machine with sound: three seconds of what it plays, and
    /// how much of it was heard (nothing playing, nothing heard).
    ///   cargo test -p coucou the_tap_hears_what_plays -- --ignored --nocapture
    #[cfg(windows)]
    #[test]
    #[ignore]
    fn the_tap_hears_what_plays() {
        let mut tap = tap::Tap::open().expect("an output to listen to");
        let mut heard = Vec::new();
        for _ in 0..30 {
            std::thread::sleep(std::time::Duration::from_millis(100));
            tap.read(&mut heard);
        }
        let loudest = heard.iter().cloned().fold(0f32, f32::max);
        println!("{} onsets in 3 s, the strongest {loudest:.2}", heard.len());
        assert!(heard.len() <= 310);
    }
}
