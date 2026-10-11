pub struct AudioMixer;

impl AudioMixer {
    /// Calculate Root-Mean-Square (RMS) for waveform visualizer level (0.0 to 1.0)
    pub fn calculate_rms(samples: &[f32]) -> f32 {
        if samples.is_empty() {
            return 0.0;
        }
        let sum_sq: f32 = samples.iter().map(|&s| s * s).sum();
        let rms = (sum_sq / samples.len() as f32).sqrt();
        (rms * 3.5).min(1.0) // Boost sensitivity for visualizer
    }

    /// Convert f32 samples to 16-bit Linear PCM Little-Endian bytes
    pub fn f32_to_pcm16_bytes(samples: &[f32]) -> Vec<u8> {
        let mut bytes = Vec::with_capacity(samples.len() * 2);
        for &sample in samples {
            // Clamp sample to [-1.0, 1.0]
            let clamped = sample.max(-1.0).min(1.0);
            let pcm = (clamped * 32767.0) as i16;
            bytes.extend_from_slice(&pcm.to_le_bytes());
        }
        bytes
    }

    /// Downsample audio linearly from source_rate to target_rate (e.g. 48kHz -> 24kHz for OpenAI)
    pub fn resample_linear(samples: &[f32], source_rate: u32, target_rate: u32) -> Vec<f32> {
        if source_rate == target_rate || samples.is_empty() {
            return samples.to_vec();
        }
        let ratio = source_rate as f32 / target_rate as f32;
        let new_len = (samples.len() as f32 / ratio) as usize;
        let mut output = Vec::with_capacity(new_len);

        for i in 0..new_len {
            let src_idx = (i as f32 * ratio) as usize;
            if src_idx < samples.len() {
                output.push(samples[src_idx]);
            }
        }
        output
    }
}
