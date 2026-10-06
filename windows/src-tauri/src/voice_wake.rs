use std::sync::Mutex;
use tauri::{AppHandle, Emitter};

#[cfg(windows)]
use std::io::{BufRead, BufReader};
#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
use std::process::{Child, Command, Stdio};

static LISTENER: Mutex<Option<ListenerState>> = Mutex::new(None);

struct ListenerState {
    #[cfg(windows)]
    child: Child,
    #[cfg(not(windows))]
    _dummy: (),
}

pub fn start_listener(app: AppHandle, wake_word: &str) {
    stop_listener();

    #[cfg(windows)]
    {
        const CREATE_NO_WINDOW: u32 = 0x08000000;

        let custom = wake_word.trim().to_lowercase();
        let script = format!(
            r#"
Add-Type -AssemblyName System.Speech;
try {{
    $recognizer = New-Object System.Speech.Recognition.SpeechRecognitionEngine;
    $choices = New-Object System.Speech.Recognition.Choices;
    $words = @(
        'hey coucou', 'coucou', 'cuckoo', 'hey cuckoo',
        'kuku', 'hey kuku', 'kukuk', 'hey kukuk',
        'koko', 'hey koko', 'coco', 'hey coco',
        'moci', 'hey moci', 'mochi', 'hey mochi'
    );
    if ('{0}' -ne '') {{ $words += '{0}' }};
    $choices.Add([string[]]$words);
    $gb = New-Object System.Speech.Recognition.GrammarBuilder;
    $gb.Append($choices);
    $grammar = New-Object System.Speech.Recognition.Grammar($gb);
    $recognizer.LoadGrammar($grammar);
    $recognizer.SetInputToDefaultAudioDevice();
    [Console]::WriteLine('DEVICE_INFO: Audio input listener bound to default audio device');
    [Console]::Out.Flush();
    $script:lastTrigger = [DateTime]::MinValue;
    $script:debounceMs = 1500;
    $triggerWake = {{
        param($conf, $text, $type)
        $now = [DateTime]::UtcNow;
        if (($now - $script:lastTrigger).TotalMilliseconds -gt $script:debounceMs) {{
            $script:lastTrigger = $now;
            [Console]::WriteLine(('WAKE_DETECTED:' + $type + ':' + $conf + ':' + $text));
            [Console]::Out.Flush();
        }}
    }};
    $recognizer.add_SpeechHypothesized({{
        param($s, $e)
        if ($e.Result.Confidence -ge 0.20) {{
            & $triggerWake $e.Result.Confidence $e.Result.Text "hypothesized"
        }}
    }});
    $recognizer.add_SpeechRecognized({{
        param($s, $e)
        if ($e.Result.Confidence -ge 0.15) {{
            & $triggerWake $e.Result.Confidence $e.Result.Text "recognized"
        }}
    }});
    $recognizer.RecognizeAsync([System.Speech.Recognition.RecognizeMode]::Multiple);
    while ($true) {{ Start-Sleep -Seconds 1 }};
}} catch {{
    [Console]::WriteLine('ERROR: ' + $_.Exception.Message);
}}
"#,
            custom.replace('\'', "''")
        );

        let mut cmd = Command::new("powershell.exe");
        cmd.args(["-NoProfile", "-NonInteractive", "-Command", &script])
            .creation_flags(CREATE_NO_WINDOW)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());

        if let Ok(mut child) = cmd.spawn() {
            if let Some(stdout) = child.stdout.take() {
                let handle = app.clone();
                std::thread::spawn(move || {
                    let reader = BufReader::new(stdout);
                    for line in reader.lines().map_while(Result::ok) {
                        let trimmed = line.trim();
                        if trimmed.starts_with("WAKE_DETECTED") {
                            crate::log::line(format!("voice wake word detected: {trimmed}"));
                            let _ = handle.emit("wake-word-detected", ());
                        } else if trimmed.starts_with("DEVICE_INFO:") {
                            crate::log::line(format!("voice wake {trimmed}"));
                        } else if trimmed.starts_with("ERROR:") {
                            crate::log::line(format!("voice wake error: {trimmed}"));
                        }
                    }
                });
            }

            if let Some(stderr) = child.stderr.take() {
                std::thread::spawn(move || {
                    let reader = BufReader::new(stderr);
                    for line in reader.lines().map_while(Result::ok) {
                        let trimmed = line.trim();
                        if !trimmed.is_empty() {
                            crate::log::line(format!("voice wake stderr: {trimmed}"));
                        }
                    }
                });
            }

            let mut guard = LISTENER.lock().unwrap();
            *guard = Some(ListenerState { child });
        }
    }

    #[cfg(not(windows))]
    {
        let _ = app;
        let _ = wake_word;
    }
}

pub fn stop_listener() {
    let mut guard = LISTENER.lock().unwrap();
    if let Some(mut state) = guard.take() {
        #[cfg(windows)]
        {
            let _ = state.child.kill();
            let _ = state.child.wait();
        }
        #[cfg(not(windows))]
        {
            let _ = state;
        }
    }
}

#[tauri::command]
pub fn start_wake_word_listener(app: AppHandle, wake_word: String) -> Result<(), String> {
    start_listener(app, &wake_word);
    Ok(())
}

#[tauri::command]
pub fn stop_wake_word_listener() -> Result<(), String> {
    stop_listener();
    Ok(())
}
