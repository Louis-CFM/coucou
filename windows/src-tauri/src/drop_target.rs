// Coucou's own OLE drop target for the island.
//
// wry registers one when the webview is created, but WebView2 later puts its
// own on the same host window (`Chrome_WidgetWin_0`), and that one refuses
// every external drop — wry told WebView2 not to accept any. The result is the
// "no drop" cursor and nothing reaching the island. Rather than chase whichever
// window WebView2 picks in a given runtime version, every window of the island
// that lives in our process gets this target, re-installed whenever a drag may
// be starting (see `platform::unblock_webview_drops`), and the island hears about
// drags through our own `file-drag` event.

use std::cell::{Cell, RefCell};
use std::path::PathBuf;

use serde_json::json;
use tauri::{AppHandle, Emitter};
use windows::core::{implement, Ref, BOOL};
use windows::Win32::Foundation::{HWND, LPARAM, POINTL};
use windows::Win32::System::Com::{IDataObject, DVASPECT_CONTENT, FORMATETC, TYMED_HGLOBAL};
use windows::Win32::System::Ole::{
    IDropTarget, IDropTarget_Impl, RegisterDragDrop, ReleaseStgMedium, RevokeDragDrop, CF_HDROP,
    DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_NONE,
};
use windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS;
use windows::Win32::UI::Shell::{DragQueryFileW, HDROP};
use windows::Win32::UI::Input::KeyboardAndMouse::EnableWindow;
use windows::Win32::UI::WindowsAndMessaging::{EnumChildWindows, GetClassNameW, GetWindowThreadProcessId};

use crate::island::WINDOW_LABEL;

#[implement(IDropTarget)]
struct FileDropTarget {
    app: AppHandle,
    /// What DragEnter decided, repeated on every DragOver.
    effect: Cell<DROPEFFECT>,
}

impl FileDropTarget {
    fn emit(&self, kind: &str, paths: &[PathBuf]) {
        let paths: Vec<String> = paths.iter().map(|p| p.to_string_lossy().into_owned()).collect();
        let _ = self.app.emit_to(WINDOW_LABEL, "file-drag", json!({ "type": kind, "paths": paths }));
    }
}

/// The dragged files, if the data carries any (CF_HDROP — Explorer, the
/// desktop, `\\wsl.localhost` folders…).
fn file_paths(data: Ref<'_, IDataObject>) -> Option<Vec<PathBuf>> {
    let data = data.as_ref()?;
    let format = FORMATETC {
        cfFormat: CF_HDROP.0,
        ptd: std::ptr::null_mut(),
        dwAspect: DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL.0 as u32,
    };
    let mut medium = unsafe { data.GetData(&format) }.ok()?;
    let hdrop = HDROP(unsafe { medium.u.hGlobal.0 });
    let count = unsafe { DragQueryFileW(hdrop, u32::MAX, None) };
    let mut paths = Vec::new();
    for i in 0..count {
        let len = unsafe { DragQueryFileW(hdrop, i, None) } as usize;
        let mut buf = vec![0u16; len + 1];
        unsafe { DragQueryFileW(hdrop, i, Some(&mut buf)) };
        paths.push(PathBuf::from(String::from_utf16_lossy(&buf[..len])));
    }
    // The data object owns the HGLOBAL; the medium is ours to release.
    unsafe { ReleaseStgMedium(&mut medium) };
    Some(paths)
}

#[allow(non_snake_case)]
impl IDropTarget_Impl for FileDropTarget_Impl {
    fn DragEnter(
        &self,
        data: Ref<'_, IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        _pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        let paths = file_paths(data).filter(|p| !p.is_empty());
        let accepted = if paths.is_some() { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
        self.effect.set(accepted);
        unsafe { *effect = accepted };
        if let Some(paths) = paths {
            self.emit("enter", &paths);
        }
        Ok(())
    }

    fn DragOver(&self, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        unsafe { *effect = self.effect.get() };
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        if self.effect.get() != DROPEFFECT_NONE {
            self.emit("leave", &[]);
        }
        self.effect.set(DROPEFFECT_NONE);
        Ok(())
    }

    fn Drop(
        &self,
        data: Ref<'_, IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        _pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        let paths = file_paths(data).unwrap_or_default();
        crate::log::line(format!("file drop: {} file(s)", paths.len()));
        unsafe { *effect = if paths.is_empty() { DROPEFFECT_NONE } else { DROPEFFECT_COPY } };
        self.effect.set(DROPEFFECT_NONE);
        self.emit("drop", &paths);
        Ok(())
    }
}

thread_local! {
    /// One target, created on the main thread and kept alive for the app's life.
    static TARGET: RefCell<Option<IDropTarget>> = const { RefCell::new(None) };
}

/// Puts our target on `root` and on every descendant window that belongs to
/// this process — whatever was registered there before, WebView2's included.
/// Windows of WebView2's own processes are out of reach, and need not be: OLE
/// walks up from the window under the cursor to the first one with a target.
/// Main thread only: OLE ties a target to the thread that registers it.
pub fn install(app: &AppHandle, root: HWND) {
    let target = TARGET.with(|t| {
        t.borrow_mut()
            .get_or_insert_with(|| {
                FileDropTarget { app: app.clone(), effect: Cell::new(DROPEFFECT_NONE) }.into()
            })
            .clone()
    });

    unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let out = unsafe { &mut *(lparam.0 as *mut Vec<HWND>) };
        out.push(hwnd);
        BOOL(1)
    }
    let mut windows = vec![root];
    unsafe {
        let _ = EnumChildWindows(Some(root), Some(collect), LPARAM(&mut windows as *mut _ as isize));
    }

    let me = std::process::id();
    for hwnd in windows {
        let mut pid = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
        if pid != me {
            continue;
        }
        unsafe {
            let _ = RevokeDragDrop(hwnd);
            if let Err(err) = RegisterDragDrop(hwnd, &target) {
                crate::log::line(format!("drop target not registered on {hwnd:?}: {err}"));
            }
        }
    }
}

/// Our own windows below the island's root, in z/creation order.
fn own_descendants(root: HWND) -> Vec<HWND> {
    unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let out = unsafe { &mut *(lparam.0 as *mut Vec<HWND>) };
        out.push(hwnd);
        BOOL(1)
    }
    let mut all = Vec::new();
    unsafe {
        let _ = EnumChildWindows(Some(root), Some(collect), LPARAM(&mut all as *mut _ as isize));
    }
    let me = std::process::id();
    all.into_iter()
        .filter(|h| {
            let mut pid = 0u32;
            unsafe { GetWindowThreadProcessId(*h, Some(&mut pid)) };
            pid == me
        })
        .collect()
}

/// During a file drag, takes WebView2's host window (`Chrome_WidgetWin_0`) out
/// of hit-testing so the drag lands on WRY_WEBVIEW and our target; restores it
/// when the drag ends. Main thread only.
pub fn shield_webview(app: &AppHandle, on: bool) {
    let Some(root) = crate::platform::island_hwnd(app) else { return };
    if on {
        install(app, root);
    }
    for hwnd in own_descendants(root) {
        let mut name = [0u16; 64];
        let len = unsafe { GetClassNameW(hwnd, &mut name) }.max(0) as usize;
        if String::from_utf16_lossy(&name[..len]) == "Chrome_WidgetWin_0" {
            unsafe {
                let _ = EnableWindow(hwnd, !on);
            }
        }
    }
}
