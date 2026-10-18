// The words go where you type: onto the clipboard (kept out of the clipboard
// history), Ctrl+V in the app in front, and the clipboard gets back what it
// held 700 ms later — unless something else was copied meanwhile.

use std::sync::Mutex;
use std::time::Duration;

use arboard::Clipboard;

/// One clipboard for the app's whole life: on X11 the text stays served only
/// while its owner lives.
static CLIPBOARD: Mutex<Option<Clipboard>> = Mutex::new(None);

fn with_clipboard<T>(f: impl FnOnce(&mut Clipboard) -> T) -> Option<T> {
    let mut slot = CLIPBOARD.lock().unwrap();
    if slot.is_none() {
        *slot = Clipboard::new().ok();
    }
    slot.as_mut().map(f)
}

fn set_text(clipboard: &mut Clipboard, text: &str) -> Result<(), arboard::Error> {
    #[cfg(windows)]
    {
        use arboard::SetExtWindows;
        clipboard.set().exclude_from_history().exclude_from_cloud().text(text.to_string())
    }
    #[cfg(target_os = "linux")]
    {
        use arboard::SetExtLinux;
        clipboard.set().exclude_from_history().text(text.to_string())
    }
}

/// Copies `text` and leaves it there (the dictation could not be pasted).
pub fn copy(text: &str) -> bool {
    with_clipboard(|c| set_text(c, text).is_ok()).unwrap_or(false)
}

/// What happened to the words.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Pasted,
    /// On the clipboard only: the keystroke could not be sent.
    Copied,
    Failed,
}

/// Pastes `text` in the app in front. `shift` sends Ctrl+Shift+V (terminals).
pub fn paste(text: &str, shift: bool) -> Outcome {
    let previous = with_clipboard(|c| c.get_text().ok()).flatten();
    if with_clipboard(|c| set_text(c, text)).map(|r| r.is_ok()) != Some(true) {
        return Outcome::Failed;
    }
    // Give the clipboard a moment to be announced before the app reads it.
    std::thread::sleep(Duration::from_millis(40));
    if let Err(err) = super::os::send_paste(shift) {
        crate::log::line(format!("flow: paste keystroke failed: {err}"));
        return Outcome::Copied;
    }
    let ours = text.to_string();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(700));
        let Some(previous) = previous else { return };
        with_clipboard(|c| {
            // Something else was copied meanwhile: leave it.
            if c.get_text().ok().as_deref() == Some(ours.as_str()) {
                let _ = c.set_text(previous);
            }
        });
    });
    Outcome::Pasted
}
