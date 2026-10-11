use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use cpal::{Device, SampleRate, Stream, StreamConfig};
use serde::Serialize;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Debug, Clone, Serialize)]
pub struct AudioDeviceInfo {
    pub name: String,
    pub is_default: bool,
}

pub struct MicCapture {
    is_running: Arc<AtomicBool>,
    stream: Option<Stream>,
}

impl MicCapture {
    pub fn new() -> Self {
        Self {
            is_running: Arc::new(AtomicBool::new(false)),
            stream: None,
        }
    }

    pub fn list_input_devices() -> Vec<AudioDeviceInfo> {
        let host = cpal::default_host();
        let default_name = host.default_input_device().and_then(|d| d.name().ok());
        let mut list = Vec::new();

        if let Ok(devices) = host.input_devices() {
            for device in devices {
                if let Ok(name) = device.name() {
                    let is_default = default_name.as_ref().map(|d| d == &name).unwrap_or(false);
                    list.push(AudioDeviceInfo { name, is_default });
                }
            }
        }
        list
    }

    pub fn start<F>(&mut self, mut on_data: F) -> Result<(), String>
    where
        F: FnMut(&[f32]) + Send + 'static,
    {
        let host = cpal::default_host();
        let device = host
            .default_input_device()
            .ok_or_else(|| "Nenhum microfone de entrada encontrado".to_string())?;

        let config: StreamConfig = device
            .default_input_config()
            .map_err(|e| e.to_string())?
            .into();

        let is_running = self.is_running.clone();
        is_running.store(true, Ordering::SeqCst);

        let err_fn = |err| eprintln!("Erro na captura do microfone: {}", err);

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
