// The notch's Clipboard: the last things copied (text, images, files), to copy
// or paste again. In memory only, never written to disk, and gone when Coucou
// quits. What a password manager marks as private (Windows'
// ExcludeClipboardContentFromMonitorProcessing, or CanIncludeInClipboardHistory
// set to 0) is never kept, and neither are Coucou's own short-lived writes
// (Flow's dictation, a capture's paste), which are marked the same way.

use std::sync::Mutex;
use std::time::Duration;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

/// How many items are kept, pinned ones not counted.
const KEEP: usize = 30;
/// At most this many pinned items.
const KEEP_PINNED: usize = 20;
/// Longer texts are kept up to here (a whole file copied by mistake).
const MAX_TEXT: usize = 100_000;
/// Bigger images are not kept.
const MAX_IMAGE: usize = 12_000_000;
const POLL: Duration = Duration::from_millis(500);

#[derive(Clone, PartialEq)]
enum Content {
    Text(String),
    Image(Vec<u8>),
    Files(Vec<String>),
}

struct Entry {
    id: u64,
    content: Content,
    app: Option<String>,
    at: f64,
    pinned: bool,
}

/// One item as the island shows it: never the image itself (clipboard_image).
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Item {
    pub id: u64,
    /// "text", "image" or "files".
    pub kind: &'static str,
    /// The text, cut for the card; the files' paths, one per line.
    pub text: String,
    /// The whole text's length, in characters.
    pub chars: usize,
    pub files: Vec<String>,
    /// The app it was copied from, when Coucou could tell.
    pub app: Option<String>,
    /// When, in epoch ms.
    pub at: f64,
    pub pinned: bool,
}

#[derive(Default)]
struct History {
    entries: Vec<Entry>,
    next_id: u64,
}

static HISTORY: Mutex<History> = Mutex::new(History { entries: Vec::new(), next_id: 1 });

fn now_ms() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as f64).unwrap_or(0.0)
}

/// The card shows the start of a long text only.
const PREVIEW: usize = 600;

fn item(e: &Entry) -> Item {
    let (kind, text, chars, files) = match &e.content {
        Content::Text(t) => ("text", t.chars().take(PREVIEW).collect(), t.chars().count(), Vec::new()),
        Content::Image(_) => ("image", String::new(), 0, Vec::new()),
        Content::Files(f) => ("files", f.join("\n"), 0, f.clone()),
    };
    Item { id: e.id, kind, text, chars, files, app: e.app.clone(), at: e.at, pinned: e.pinned }
}

impl History {
    /// Adds what was copied, newest first. The same thing copied again moves to
    /// the top (and keeps its pin) instead of being listed twice.
    fn add(&mut self, content: Content, app: Option<String>, at: f64) -> bool {
        if let Some(pos) = self.entries.iter().position(|e| e.content == content) {
            let mut e = self.entries.remove(pos);
            e.at = at;
            if app.is_some() {
                e.app = app;
            }
            self.entries.insert(0, e);
            return true;
        }
        let id = self.next_id;
        self.next_id += 1;
        self.entries.insert(0, Entry { id, content, app, at, pinned: false });
        self.trim();
        true
    }

    /// The oldest unpinned items go first.
    fn trim(&mut self) {
        let mut unpinned = 0;
        self.entries.retain(|e| {
            if e.pinned {
                return true;
            }
            unpinned += 1;
            unpinned <= KEEP
        });
    }

    fn items(&self) -> Vec<Item> {
        self.entries.iter().map(item).collect()
    }

    fn pin(&mut self, id: u64, on: bool) -> bool {
        let pinned = self.entries.iter().filter(|e| e.pinned).count();
        let Some(e) = self.entries.iter_mut().find(|e| e.id == id) else { return false };
        if on && !e.pinned && pinned >= KEEP_PINNED {
            return false;
        }
        e.pinned = on;
        true
    }

    fn delete(&mut self, id: u64) {
        self.entries.retain(|e| e.id != id);
    }

    /// Clear keeps what is pinned.
    fn clear(&mut self) {
        self.entries.retain(|e| e.pinned);
    }
}

/// A text worth keeping: not empty, cut when huge.
fn text_content(text: String) -> Option<Content> {
    if text.trim().is_empty() {
        return None;
    }
    let text = if text.chars().count() > MAX_TEXT { text.chars().take(MAX_TEXT).collect() } else { text };
    Some(Content::Text(text))
}

fn enabled(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>().map(|s| s.settings.lock().unwrap().clipboard_history).unwrap_or(false)
}

fn publish(app: &AppHandle) {
    let items = HISTORY.lock().unwrap().items();
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "clipboard", items);
}

/// Watches the clipboard while the setting is on; off, the history is emptied.
pub fn start(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        let mut last_seq = os::sequence();
        let mut was_on = true;
        loop {
            std::thread::sleep(POLL);
            let on = enabled(&app);
            if !on {
                if was_on {
                    HISTORY.lock().unwrap().entries.clear();
                    publish(&app);
                }
                was_on = false;
                last_seq = os::sequence();
                continue;
            }
            was_on = true;
            let seq = os::sequence();
            if seq == last_seq {
                continue;
            }
            last_seq = seq;
            let Some(content) = os::read() else { continue };
            let from = crate::flow::os::foreground_app().map(|(_, name)| name);
            if HISTORY.lock().unwrap().add(content, from, now_ms()) {
                publish(&app);
            }
        }
    });
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn clipboard_items() -> Vec<Item> {
    HISTORY.lock().unwrap().items()
}

/// An image item, for its card.
#[tauri::command]
pub fn clipboard_image(id: u64) -> Option<String> {
    let h = HISTORY.lock().unwrap();
    let e = h.entries.iter().find(|e| e.id == id)?;
    let Content::Image(png) = &e.content else { return None };
    Some(format!("data:image/png;base64,{}", crate::claude::base64_for(png)))
}

fn content_of(id: u64) -> Option<Content> {
    HISTORY.lock().unwrap().entries.iter().find(|e| e.id == id).map(|e| e.content.clone())
}

/// Back on the clipboard (it moves to the top of the list when the watcher sees it).
#[tauri::command]
pub fn clipboard_copy(id: u64) -> bool {
    content_of(id).is_some_and(|c| os::write(&c))
}

/// On the clipboard, then Ctrl+V in the app in front (the island never takes focus from it).
#[tauri::command]
pub async fn clipboard_paste(id: u64) -> bool {
    let Some(content) = content_of(id) else { return false };
    if !os::write(&content) {
        return false;
    }
    std::thread::sleep(Duration::from_millis(60));
    crate::capture::send_ctrl_v()
}

#[tauri::command]
pub fn clipboard_pin(app: AppHandle, id: u64, pinned: bool) -> bool {
    let ok = HISTORY.lock().unwrap().pin(id, pinned);
    publish(&app);
    ok
}

#[tauri::command]
pub fn clipboard_delete(app: AppHandle, id: u64) {
    HISTORY.lock().unwrap().delete(id);
    publish(&app);
}

#[tauri::command]
pub fn clipboard_clear(app: AppHandle) {
    HISTORY.lock().unwrap().clear();
    publish(&app);
}

// ── The clipboard itself ──────────────────────────────────────────────────────

#[cfg(windows)]
mod os {
    use super::{text_content, Content, MAX_IMAGE};
    use clipboard_win::{formats, raw, register_format, Clipboard};

    pub fn sequence() -> u32 {
        clipboard_win::seq_num().map(|n| n.get()).unwrap_or(0)
    }

    /// Marked private, or kept out of Windows' own clipboard history.
    fn private() -> bool {
        for name in ["ExcludeClipboardContentFromMonitorProcessing", "Clipboard Viewer Ignore"] {
            if register_format(name).is_some_and(|f| raw::is_format_avail(f.get())) {
                return true;
            }
        }
        if let Some(f) = register_format("CanIncludeInClipboardHistory") {
            if raw::is_format_avail(f.get()) {
                let mut v = Vec::new();
                if raw::get_vec(f.get(), &mut v).is_ok() && v.iter().all(|b| *b == 0) {
                    return true;
                }
            }
        }
        false
    }

    /// What was just copied: the files, else the text, else the image.
    pub fn read() -> Option<Content> {
        let image = {
            let _clip = Clipboard::new_attempts(10).ok()?;
            if private() {
                return None;
            }
            if raw::is_format_avail(formats::CF_HDROP) {
                let mut files = Vec::new();
                if raw::get_file_list(&mut files).is_ok() && !files.is_empty() {
                    return Some(Content::Files(files));
                }
            }
            if raw::is_format_avail(formats::CF_UNICODETEXT) {
                let mut bytes = Vec::new();
                if raw::get_string(&mut bytes).is_ok() {
                    return text_content(String::from_utf8_lossy(&bytes).into_owned());
                }
            }
            raw::is_format_avail(formats::CF_DIB) || register_format("PNG").is_some_and(|f| raw::is_format_avail(f.get()))
        };
        if !image {
            return None;
        }
        let png = crate::capture::clipboard_image()?;
        (png.len() <= MAX_IMAGE).then_some(Content::Image(png))
    }

    pub fn write(content: &Content) -> bool {
        match content {
            Content::Text(t) => clipboard_win::set_clipboard_string(t).is_ok(),
            Content::Image(png) => crate::capture::set_clipboard_image(png),
            Content::Files(files) => {
                let Ok(_clip) = Clipboard::new_attempts(10) else { return false };
                raw::empty().is_ok() && raw::set_file_list(files).is_ok()
            }
        }
    }
}

#[cfg(not(windows))]
mod os {
    use super::Content;

    pub fn sequence() -> u32 {
        0
    }
    pub fn read() -> Option<Content> {
        None
    }
    pub fn write(_content: &Content) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(t: &str) -> Content {
        Content::Text(t.into())
    }

    #[test]
    fn newest_first_and_a_repeat_moves_up() {
        let mut h = History::default();
        h.add(text("one"), Some("Notepad".into()), 1.0);
        h.add(text("two"), None, 2.0);
        h.add(text("one"), None, 3.0);
        let items = h.items();
        assert_eq!(items.len(), 2, "copied twice, listed once");
        assert_eq!(items[0].text, "one");
        assert_eq!(items[0].app.as_deref(), Some("Notepad"), "the app it came from stays");
        assert_eq!(items[0].at, 3.0);
    }

    #[test]
    fn keeps_thirty_plus_the_pinned_ones() {
        let mut h = History::default();
        h.add(text("keep me"), None, 0.0);
        let first = h.items()[0].id;
        assert!(h.pin(first, true));
        for i in 0..40 {
            h.add(text(&format!("item {i}")), None, i as f64);
        }
        let items = h.items();
        assert_eq!(items.iter().filter(|i| !i.pinned).count(), KEEP);
        assert!(items.iter().any(|i| i.id == first), "a pinned item is never dropped");
        h.clear();
        assert_eq!(h.items().len(), 1, "Clear keeps what is pinned");
        h.delete(first);
        assert!(h.items().is_empty());
    }

    #[test]
    fn empty_texts_are_not_kept_and_long_ones_are_cut() {
        assert!(text_content("  \n\t ".into()).is_none());
        let Some(Content::Text(t)) = text_content("x".repeat(MAX_TEXT + 10)) else { panic!() };
        assert_eq!(t.chars().count(), MAX_TEXT);
        let mut h = History::default();
        h.add(Content::Text("y".repeat(PREVIEW * 2)), None, 0.0);
        let item = &h.items()[0];
        assert_eq!(item.text.chars().count(), PREVIEW, "the card gets the start");
        assert_eq!(item.chars, PREVIEW * 2, "and the real length");
    }

    #[test]
    fn files_and_images_are_items_too() {
        let mut h = History::default();
        h.add(Content::Files(vec!["C:\\a.txt".into(), "C:\\b.png".into()]), None, 0.0);
        h.add(Content::Image(vec![1, 2, 3]), None, 1.0);
        let items = h.items();
        assert_eq!(items[0].kind, "image");
        assert_eq!(items[1].kind, "files");
        assert_eq!(items[1].files.len(), 2);
    }
}
