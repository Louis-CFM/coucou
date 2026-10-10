// Files dropped on the island, taken by WebView2 itself.
//
// Tauri's drag-drop goes through drop targets wry registers on the webview's
// child windows. The innermost windows, though, belong to msedgewebview2.exe,
// and drags from the classic Explorer folder view (Downloads, Documents…) never
// walked up to wry's target: "no drop" cursor, nothing reached the app. Only the
// newer WinUI views (Home, Recent) got through.
//
// So `dragDropEnabled` is off for the island and WebView2 takes drops the way
// Edge does. The page accepts the HTML5 drag (src/core/bridge.ts) and hands the
// dropped File objects back with `chrome.webview.postMessageWithAdditionalObjects`;
// here they turn back into real paths and reach the island as a `file-drag` drop.

use tauri::{AppHandle, Emitter};
use webview2_com::Microsoft::Web::WebView2::Win32::{
    ICoreWebView2File, ICoreWebView2WebMessageReceivedEventArgs2,
};
use webview2_com::{take_pwstr, WebMessageReceivedEventHandler};
use wv2_core::{Interface, PWSTR};

use crate::island::{self, WINDOW_LABEL};

#[derive(serde::Serialize, Clone)]
struct FileDrop {
    #[serde(rename = "type")]
    kind: &'static str,
    paths: Vec<String>,
}

pub fn install(app: &AppHandle) {
    let Some(win) = island::window(app) else { return };
    let handle = app.clone();
    let result = win.with_webview(move |webview| unsafe {
        let core = match webview.controller().CoreWebView2() {
            Ok(core) => core,
            Err(err) => {
                crate::log::line(format!("file drop: no webview: {err}"));
                return;
            }
        };
        let handler = WebMessageReceivedEventHandler::create(Box::new(move |_, args| {
            let Some(args) = args else { return Ok(()) };
            // Tauri's own IPC messages come through here too; they carry no objects.
            let Ok(args) = args.cast::<ICoreWebView2WebMessageReceivedEventArgs2>() else { return Ok(()) };
            let Ok(objects) = args.AdditionalObjects() else { return Ok(()) };
            let mut count = 0u32;
            objects.Count(&mut count)?;
            if count == 0 {
                return Ok(());
            }
            let mut paths = Vec::new();
            for i in 0..count {
                let Ok(file) = objects.GetValueAtIndex(i)?.cast::<ICoreWebView2File>() else { continue };
                let mut path = PWSTR::null();
                file.Path(&mut path)?;
                paths.push(take_pwstr(path));
            }
            crate::files::allow_dropped(paths.iter().cloned());
            let _ = handle.emit_to(WINDOW_LABEL, "file-drag", FileDrop { kind: "drop", paths });
            Ok(())
        }));
        let mut token = 0i64;
        if let Err(err) = core.add_WebMessageReceived(&handler, &mut token) {
            crate::log::line(format!("file drop: cannot listen: {err}"));
        }
    });
    if let Err(err) = result {
        crate::log::line(format!("file drop: {err}"));
    }
}
