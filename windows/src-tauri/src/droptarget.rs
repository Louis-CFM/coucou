// Our own OLE drop target, installed on every descendant window of the
// island (and settings) webviews.
//
// Why this exists: wry registers its drop target by walking child windows
// ONCE at webview creation, but WebView2 creates its render widgets later
// (nested several levels deep in current runtimes). Those late widgets end
// up with WebView2's default target — or none our relay can revoke from this
// thread — so drops die there with the "prohibited" cursor and neither Tauri
// nor DOM events ever fire. Revoking proved unreliable (cross-apartment
// targets refuse it); OWNING the target does not depend on anyone else.
//
// `ensure_targets` walks the whole subtree, replaces whatever target each
// descendant has with ours (revoke-then-register), and is re-run throughout
// drags so late-created widgets get covered too. Targets are kept alive in a
// process-wide vec — OLE holds only a weak reference pattern here, and
// dropping our last Rust reference mid-drag would crash the drag.
//
// Events (`ext-drag` enter/leave/drop) mirror Tauri's DragDropEvent shape so
// the island reuses a single handler for both transports.

use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};
use windows::core::{implement, BOOL};
use windows::Win32::Foundation::{HWND, LPARAM};
use windows::Win32::System::Com::{
    IDataObject, DVASPECT_CONTENT, FORMATETC, STGMEDIUM, TYMED_HGLOBAL,
};
use windows::Win32::System::Ole::{
    IDropTarget, IDropTarget_Impl, RegisterDragDrop, RevokeDragDrop, CF_HDROP, DROPEFFECT,
    DROPEFFECT_COPY, DROPEFFECT_NONE,
};
use windows::Win32::UI::Shell::{DragFinish, DragQueryFileW, HDROP};
use windows::Win32::UI::WindowsAndMessaging::EnumChildWindows;

use crate::island::WINDOW_LABEL;

#[derive(Serialize, Clone)]
struct ExtDrag {
    #[serde(rename = "type")]
    kind: String,
    paths: Vec<String>,
}

fn file_format() -> FORMATETC {
    FORMATETC {
        cfFormat: CF_HDROP.0,
        ptd: std::ptr::null_mut(),
        dwAspect: DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL.0 as u32,
    }
}

fn has_files(data: &IDataObject) -> bool {
    unsafe { data.QueryGetData(&file_format()).is_ok() }
}

fn extract_paths(data: &IDataObject) -> Vec<String> {
    let mut paths = Vec::new();
    let fmt = file_format();
    // windows 0.61: GetData returns the medium directly.
    let medium: STGMEDIUM = match unsafe { data.GetData(&fmt) } {
        Ok(m) => m,
        Err(_) => return paths,
    };
    let hdrop = HDROP(unsafe { medium.u.hGlobal.0 } as _);
    let count = unsafe { DragQueryFileW(hdrop, 0xFFFFFFFF, None) };
    for i in 0..count {
        let len = unsafe { DragQueryFileW(hdrop, i, None) } as usize;
        let mut buf = vec![0u16; len + 1];
        unsafe { DragQueryFileW(hdrop, i, Some(&mut buf)) };
        paths.push(
            OsString::from_wide(&buf[..len])
                .to_string_lossy()
                .into_owned(),
        );
    }
    unsafe { DragFinish(hdrop) };
    paths
}

#[implement(IDropTarget)]
struct IslandDropTarget {
    app: AppHandle,
}

impl IslandDropTarget {
    fn emit(&self, kind: &str, paths: Vec<String>) {
        let _ = self.app.emit_to(
            WINDOW_LABEL,
            "ext-drag",
            ExtDrag {
                kind: kind.into(),
                paths,
            },
        );
    }
}

#[allow(non_snake_case)]
impl IDropTarget_Impl for IslandDropTarget_Impl {
    fn DragEnter(
        &self,
        pDataObj: windows::core::Ref<'_, IDataObject>,
        _grfKeyState: windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS,
        _pt: &windows::Win32::Foundation::POINTL,
        pdwEffect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        let ok = pDataObj.as_ref().map(has_files).unwrap_or(false);
        unsafe {
            *pdwEffect = if ok { DROPEFFECT_COPY } else { DROPEFFECT_NONE };
        }
        if ok {
            self.emit("enter", Vec::new());
        }
        Ok(())
    }

    fn DragOver(
        &self,
        _grfKeyState: windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS,
        _pt: &windows::Win32::Foundation::POINTL,
        pdwEffect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        unsafe {
            *pdwEffect = DROPEFFECT_COPY;
        }
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        self.emit("leave", Vec::new());
        Ok(())
    }

    fn Drop(
        &self,
        pDataObj: windows::core::Ref<'_, IDataObject>,
        _grfKeyState: windows::Win32::System::SystemServices::MODIFIERKEYS_FLAGS,
        _pt: &windows::Win32::Foundation::POINTL,
        _pdwEffect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        let paths = pDataObj.as_ref().map(extract_paths).unwrap_or_default();
        if !paths.is_empty() {
            self.emit("drop", paths);
        }
        Ok(())
    }
}

struct WalkCtx<'a> {
    app: &'a AppHandle,
    label: &'static str,
    total: u32,
    injected: u32,
}

/// Inject our target into one window: revoke whatever is there, then register
/// ours. No keep-alive vec needed: RegisterDragDrop AddRefs the object, so
/// OLE itself keeps it alive until replaced or revoked.
fn inject(hwnd: HWND, ctx: &mut WalkCtx) {
    ctx.total += 1;
    let target: IDropTarget = IslandDropTarget {
        app: ctx.app.clone(),
    }
    .into();
    let _ = unsafe { RevokeDragDrop(hwnd) };
    if unsafe { RegisterDragDrop(hwnd, &target) }.is_ok() {
        ctx.injected += 1;
    }
}

unsafe extern "system" fn walk(hwnd: HWND, lparam: LPARAM) -> BOOL {
    let ctx = unsafe { &mut *(lparam.0 as *mut WalkCtx) };
    inject(hwnd, ctx);
    unsafe {
        let _ = EnumChildWindows(Some(hwnd), Some(walk), lparam);
    }
    true.into()
}

/// Covers a webview window and its whole subtree with our drop target.
/// Re-runnable: already-covered windows just get the same treatment again
/// (the old target object stays alive in TARGETS either way).
pub fn ensure_targets(app: &AppHandle, label: &'static str) {
    let Some(win) = app.get_webview_window(label) else {
        return;
    };
    let Ok(raw) = win.hwnd() else { return };
    let hwnd = HWND(raw.0 as *mut _);
    if hwnd.0.is_null() {
        return;
    }
    let mut ctx = WalkCtx {
        app,
        label,
        total: 0,
        injected: 0,
    };
    inject(hwnd, &mut ctx);
    unsafe {
        let _ = EnumChildWindows(
            Some(hwnd),
            Some(walk),
            LPARAM(&mut ctx as *mut WalkCtx as isize),
        );
    }
    crate::log::line(format!(
        "drop-targets {label}: windows={} injected={}",
        ctx.total, ctx.injected
    ));
}

/// Both windows, like the old unblock pass.
pub fn ensure_all(app: &AppHandle) {
    ensure_targets(app, WINDOW_LABEL);
    ensure_targets(app, "settings");
}
