use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, Stream, StreamConfig};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

pub struct SystemLoopback {
    is_running: Arc<AtomicBool>,
    stream: Option<Stream>,
}

impl SystemLoopback {
    pub fn new() -> Self {
        Self {
            is_running: Arc::new(AtomicBool::new(false)),
            stream: None,
        }
    }

    pub fn start<F>(&mut self, mut on_data: F) -> Result<(), String>
    where
        F: FnMut(&[f32]) + Send + 'static,
    {
        let host = cpal::default_host();
        // In cpal on Windows with WASAPI, capturing default output device acts as loopback
        let device = host
            .default_output_device()
            .ok_or_else(|| "Nenhum dispositivo de saída/loopback do Windows encontrado".to_string())?;

        let config: StreamConfig = device
            .default_output_config()
            .map_err(|e| e.to_string())?
            .into();

        let is_running = self.is_running.clone();
        is_running.store(true, Ordering::SeqCst);

        let err_fn = |err| eprintln!("Erro no loopback WASAPI: {}", err);

        let stream = device
            .build_input_stream(
                &config,
                move |data: &[f32], _: &_| {
                    if is_running.load(Ordering::SeqCst) {
                        on_data(data);
                    }
                },
                err_fn,
                None,
            )
            .map_err(|e| e.to_string())?;

        stream.play().map_err(|e| e.to_string())?;
        self.stream = Some(stream);
        Ok(())
    }

    pub fn stop(&mut self) {
        self.is_running.store(false, Ordering::SeqCst);
        self.stream = None;
    }
}
