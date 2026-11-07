//! The Windows Save As dialog stays on its own COM apartment. The main window
//! keeps pumping messages while the user chooses a destination or cancels.
use std::path::PathBuf;
use windows::{core::{w, HSTRING, HRESULT}, Win32::{
    Foundation::{ERROR_CANCELLED, HWND},
    System::Com::{CoCreateInstance, CoInitializeEx, CoTaskMemFree, CoUninitialize,
        CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED},
    UI::Shell::{Common::COMDLG_FILTERSPEC, FileSaveDialog, IFileSaveDialog,
        FOS_FORCEFILESYSTEM, FOS_OVERWRITEPROMPT, FOS_PATHMUSTEXIST, SIGDN_FILESYSPATH},
}};

struct Apartment;
impl Apartment {
    fn enter() -> windows::core::Result<Self> {
        unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok()?; }
        Ok(Self)
    }
}
impl Drop for Apartment { fn drop(&mut self) { unsafe { CoUninitialize(); } } }

fn configured_dialog(name: &str) -> windows::core::Result<IFileSaveDialog> {
    unsafe {
        let dialog: IFileSaveDialog = CoCreateInstance(&FileSaveDialog, None, CLSCTX_INPROC_SERVER)?;
        // Retain the native defaults, including overwrite confirmation.
        dialog.SetOptions(dialog.GetOptions()? | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT | FOS_PATHMUSTEXIST)?;
        dialog.SetFileTypes(&[COMDLG_FILTERSPEC { pszName: w!("Markdown"), pszSpec: w!("*.md") }])?;
        dialog.SetFileTypeIndex(1)?;
        dialog.SetDefaultExtension(w!("md"))?;
        dialog.SetFileName(&HSTRING::from(name))?;
        dialog.SetTitle(&HSTRING::from(crate::i18n::t("Export as Markdown…")))?;
        Ok(dialog)
    }
}

fn show(owner: isize, name: &str) -> windows::core::Result<Option<PathBuf>> {
    let _apartment = Apartment::enter()?;
    let dialog = configured_dialog(name)?;
    unsafe {
        if let Err(error) = dialog.Show(Some(HWND(owner as *mut _))) {
            return if error.code() == HRESULT::from_win32(ERROR_CANCELLED.0) { Ok(None) } else { Err(error) };
        }
        let raw = dialog.GetResult()?.GetDisplayName(SIGDN_FILESYSPATH)?;
        let path = raw.to_string();
        CoTaskMemFree(Some(raw.0.cast()));
        Ok(Some(PathBuf::from(path?)))
    }
}

pub async fn choose_path(owner: isize, name: String) -> Result<Option<PathBuf>, String> {
    let (send, receive) = tokio::sync::oneshot::channel();
    // A dedicated STA avoids inheriting an MTA from a reused blocking worker.
    std::thread::Builder::new().name("coucou-note-export".into()).spawn(move || {
        let _ = send.send(show(owner, &name).map_err(|error| error.to_string()));
    }).map_err(|error| error.to_string())?;
    receive.await.map_err(|error| error.to_string())?
}

pub fn write_selected(selected: Option<PathBuf>, content: &str) -> Result<Option<String>, String> {
    let Some(path) = selected else { return Ok(None) };
    std::fs::write(&path, content).map_err(|error| error.to_string())?;
    Ok(Some(path.to_string_lossy().into_owned()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn native_save_dialog_retains_overwrite_and_filesystem_checks() {
        std::thread::spawn(|| {
            let _apartment = Apartment::enter().unwrap();
            let dialog = configured_dialog("Synthetic call.md").unwrap();
            unsafe {
                let options = dialog.GetOptions().unwrap();
                for flag in [FOS_OVERWRITEPROMPT, FOS_PATHMUSTEXIST, FOS_FORCEFILESYSTEM] {
                    assert_eq!(options.0 & flag.0, flag.0);
                }
                assert_eq!(dialog.GetFileTypeIndex().unwrap(), 1);
            }
        }).join().unwrap();
    }

    #[test]
    fn cancellation_writes_nothing_and_the_selected_file_receives_complete_utf8() {
        assert_eq!(write_selected(None, "cancelled"), Ok(None));
        let dir = std::env::temp_dir().join(format!("coucou-note-export-{}-{}", std::process::id(), crate::flow::store::now_ms()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("Chosen destination.md");
        let text = "# Synthetic call\n\nCafé 世界 — verify both audio sources Friday.\n";
        assert_eq!(write_selected(Some(path.clone()), text).unwrap(), Some(path.to_string_lossy().into_owned()));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), text);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 1);
        assert!(write_selected(Some(dir.join("missing").join("call.md")), text).is_err());
        std::fs::remove_file(path).unwrap();
        std::fs::remove_dir(dir).unwrap();
    }
}
