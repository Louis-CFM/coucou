//! CPU neural synthesis through the same offline runtime used for ASR.
//! Model folders contain a Piper ONNX, tokens.txt and espeak-ng-data.
use sherpa_onnx::{
    GenerationConfig, OfflineTts, OfflineTtsConfig, OfflineTtsModelConfig,
    OfflineTtsVitsModelConfig,
};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

static MODEL: Mutex<Option<(PathBuf, OfflineTts)>> = Mutex::new(None);

pub fn generate(
    directory: &Path,
    text: &str,
    mut running: impl FnMut() -> bool + 'static,
) -> Option<Vec<u8>> {
    if text.contains('\0') || text.trim().is_empty() || !running() {
        return None;
    }
    let directory = directory.canonicalize().ok()?;
    let mut slot = MODEL.lock().unwrap();
    if slot.as_ref().is_none_or(|(path, _)| *path != directory) {
        let mut models: Vec<PathBuf> = std::fs::read_dir(&directory)
            .ok()?
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .filter(|p| p.extension().is_some_and(|s| s == "onnx") && p.is_file())
            .collect();
        models.sort();
        if models.len() != 1
            || !directory.join("tokens.txt").is_file()
            || !directory.join("espeak-ng-data").is_dir()
        {
            return None;
        }
        // Release the old voice before loading the next one, keeping memory bounded.
        *slot = None;
        let config = OfflineTtsConfig {
            model: OfflineTtsModelConfig {
                vits: OfflineTtsVitsModelConfig {
                    model: Some(models[0].to_string_lossy().into()),
                    tokens: Some(directory.join("tokens.txt").to_string_lossy().into()),
                    data_dir: Some(directory.join("espeak-ng-data").to_string_lossy().into()),
                    ..Default::default()
                },
                num_threads: 4,
                provider: Some("cpu".into()),
                ..Default::default()
            },
            max_num_sentences: 1,
            ..Default::default()
        };
        *slot = Some((directory, OfflineTts::create(&config)?));
    }
    if !running() {
        return None;
    }
    let audio = slot.as_ref()?.1.generate_with_config(
        text,
        &GenerationConfig::default(),
        Some(move |_: &[f32], _: f32| running()),
    )?;
    wav(audio.samples(), audio.sample_rate() as u32)
}

fn wav(samples: &[f32], rate: u32) -> Option<Vec<u8>> {
    if rate == 0 {
        return None;
    }
    let size = u32::try_from(samples.len()).ok()?.checked_mul(2)?;
    let mut out = Vec::with_capacity(size as usize + 44);
    out.extend_from_slice(b"RIFF");
    out.extend_from_slice(&size.checked_add(36)?.to_le_bytes());
    out.extend_from_slice(b"WAVEfmt ");
    out.extend_from_slice(&16u32.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    out.extend_from_slice(&rate.to_le_bytes());
    out.extend_from_slice(&rate.checked_mul(2)?.to_le_bytes());
    out.extend_from_slice(&2u16.to_le_bytes());
    out.extend_from_slice(&16u16.to_le_bytes());
    out.extend_from_slice(b"data");
    out.extend_from_slice(&size.to_le_bytes());
    for &sample in samples {
        out.extend_from_slice(&((sample.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes());
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn wave_header_and_clipping_match_the_audio_player() {
        let wave = wav(&[-2.0, 0.0, 2.0], 22050).unwrap();
        assert_eq!(&wave[..4], b"RIFF");
        assert_eq!(&wave[8..16], b"WAVEfmt ");
        assert_eq!(u32::from_le_bytes(wave[24..28].try_into().unwrap()), 22050);
        assert_eq!(u32::from_le_bytes(wave[40..44].try_into().unwrap()), 6);
        assert_eq!(
            &wave[44..],
            &[-32767i16, 0, 32767]
                .into_iter()
                .flat_map(i16::to_le_bytes)
                .collect::<Vec<_>>()
        );
        assert!(wav(&[], 0).is_none());
    }
    #[test]
    fn missing_models_and_cancelled_synthesis_do_not_use_a_network_fallback() {
        assert!(generate(Path::new("/no-such-voice-model"), "Olá", || true).is_none());
        assert!(generate(Path::new("."), "Olá", || false).is_none());
    }
    #[test]
    #[ignore = "requires downloaded pt-PT voices and local Parakeet models"]
    fn evaluate_portuguese_voice_locally() {
        use std::time::Instant;
        let directory = std::env::var("COUCOU_TEST_VOICE").expect("COUCOU_TEST_VOICE");
        let output = std::env::var("COUCOU_TEST_VOICE_OUTPUT").expect("COUCOU_TEST_VOICE_OUTPUT");
        let text = "Olá, Pedro. Sou o teu assistente. Podes falar comigo em português de Portugal. Codex, abre o gestor de ficheiros e mostra a pasta de transferências. Gravity, que horas são em Lisboa?";
        for turn in 0..2 {
            let start = Instant::now();
            let bytes = generate(Path::new(&directory), text, || true).expect("local synthesis");
            let elapsed = start.elapsed().as_secs_f64();
            let rate = u32::from_le_bytes(bytes[24..28].try_into().unwrap());
            let duration = (bytes.len() - 44) as f64 / 2.0 / rate as f64;
            std::fs::write(&output, &bytes).unwrap();
            println!(
                "TTS turn={turn} generation={elapsed:.3}s audio={duration:.3}s RTF={:.3}",
                elapsed / duration
            );
            let pcm: Vec<f32> = bytes[44..]
                .chunks_exact(2)
                .map(|b| i16::from_le_bytes([b[0], b[1]]) as f32 / 32768.0)
                .collect();
            let mut resampler = super::super::audio::Resampler::new(rate);
            let mut samples = Vec::new();
            resampler.process(&pcm, &mut samples);
            let start = Instant::now();
            let transcript = super::super::transcribe(&samples).expect("local Parakeet");
            println!(
                "ASR turn={turn} recognition={:.3}s audio={duration:.3}s transcript={}",
                start.elapsed().as_secs_f64(),
                transcript.text
            );
            assert!(!transcript.text.is_empty());
        }
    }
}
