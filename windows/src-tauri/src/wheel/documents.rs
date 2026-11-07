// The wheel's documents: Word files, text and web pages, converted and cleaned
// by Microsoft Word when it is installed (hidden, through its COM automation,
// the original opened read-only), else by LibreOffice. Results go next to the
// originals, never over them. Not PDFs: hidden Word stops on its "convert this
// PDF?" question, which nobody can answer.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use super::formats::{ext, output_path};

/// What Word documents, text and web pages become.
pub const DOCUMENT_TARGETS: &[&str] = &["pdf", "docx", "doc", "rtf", "odt", "txt", "html"];
/// The documents whose author and properties can be removed.
pub const CLEANABLE: &[&str] = &["docx", "doc", "rtf", "odt"];
/// The documents Word and LibreOffice open.
pub const READABLE: &[&str] = &["docx", "doc", "odt", "rtf", "txt", "md", "markdown", "html", "htm"];

/// How long one file may take before Word is given up on (it may be stuck on a
/// dialog nobody sees).
const TIMEOUT: Duration = Duration::from_secs(180);

/// Word's file format number for a target (WdSaveFormat).
fn word_format(target: &str) -> Option<i32> {
    Some(match target {
        "pdf" => 17,
        "docx" => 16,
        "doc" => 0,
        "rtf" => 6,
        // Unicode text: made UTF-8 afterwards (utf8_text).
        "txt" => 7,
        "html" => 10,
        "odt" => 23,
        _ => return None,
    })
}

/// LibreOffice's name for a target (`--convert-to`).
fn office_filter(target: &str) -> Option<&'static str> {
    Some(match target {
        "pdf" => "pdf",
        "docx" => "docx",
        "doc" => "doc",
        "rtf" => "rtf",
        "odt" => "odt",
        "txt" => "txt:Text (encoded):UTF8",
        "html" => "html",
        _ => return None,
    })
}

/// Word, when it is installed (its COM class is registered).
#[cfg(windows)]
fn has_word() -> bool {
    Command::new("reg")
        .args(["query", r"HKCR\Word.Application\CLSID"])
        .creation_flags(NO_WINDOW)
        .output()
        .is_ok_and(|o| o.status.success())
}

#[cfg(not(windows))]
fn has_word() -> bool {
    false
}

/// LibreOffice's soffice, where its installer puts it or on PATH.
fn soffice() -> Option<PathBuf> {
    let installed = [r"C:\Program Files\LibreOffice\program\soffice.exe", r"C:\Program Files (x86)\LibreOffice\program\soffice.exe"];
    if let Some(p) = installed.iter().map(PathBuf::from).find(|p| p.exists()) {
        return Some(p);
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join("soffice.exe")).find(|p| p.exists())
}

#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
const NO_WINDOW: u32 = 0x0800_0000;

/// The script Word runs: the paths come in the environment, never in the code.
const WORD_SCRIPT: &str = r#"
$ErrorActionPreference = 'Stop'
$word = New-Object -ComObject Word.Application
try {
  $word.Visible = $false
  $word.DisplayAlerts = 0
  # Read-only, no conversion dialog, not added to the recent files.
  $doc = $word.Documents.Open($env:COUCOU_IN, $false, $true, $false)
  try {
    if ($env:COUCOU_JOB -eq 'clean') {
      # Personal information (author, last saved by), then the document's properties.
      $doc.RemoveDocumentInformation(4)
      $doc.RemoveDocumentInformation(8)
    }
    $doc.SaveAs2($env:COUCOU_OUT, [int]$env:COUCOU_FORMAT)
  } finally { $doc.Close(0) }
} finally {
  # No argument: from PowerShell, Quit's arguments are by reference.
  $word.Quit()
  [void][Runtime.InteropServices.Marshal]::ReleaseComObject($word)
}
"#;

/// Runs a command to its end, or kills it after TIMEOUT.
fn finish(mut cmd: Command) -> Result<(), String> {
    #[cfg(windows)]
    cmd.creation_flags(NO_WINDOW);
    let mut child = cmd.stdout(std::process::Stdio::null()).stderr(std::process::Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    let start = Instant::now();
    loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            if status.success() {
                return Ok(());
            }
            let mut err = String::new();
            if let Some(mut e) = child.stderr.take() {
                let _ = std::io::Read::read_to_string(&mut e, &mut err);
            }
            let first = err.lines().map(str::trim).find(|l| !l.is_empty()).unwrap_or("it stopped with an error");
            return Err(first.chars().take(160).collect());
        }
        if start.elapsed() > TIMEOUT {
            let _ = child.kill();
            close_words_since(start.elapsed());
            return Err("it took too long".into());
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// The Word processes started in the last `ago` (the one this conversion
/// opened, stuck), closed; one the user had open before is left alone.
fn close_words_since(ago: Duration) {
    let script = format!(
        "Get-Process WINWORD -ErrorAction SilentlyContinue | Where-Object {{ $_.StartTime -gt (Get-Date).AddSeconds(-{}) }} | Stop-Process -Force",
        ago.as_secs() + 2
    );
    let mut cmd = Command::new("powershell.exe");
    cmd.args(["-NoProfile", "-NonInteractive", "-Command", &script]);
    #[cfg(windows)]
    cmd.creation_flags(NO_WINDOW);
    let _ = cmd.status();
}

/// One file through Word: `job` "convert" or "clean".
fn word(input: &Path, dest: &Path, format: i32, job: &str) -> Result<(), String> {
    let mut cmd = Command::new("powershell.exe");
    cmd.args(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", WORD_SCRIPT])
        .env("COUCOU_IN", input)
        .env("COUCOU_OUT", dest)
        .env("COUCOU_FORMAT", format.to_string())
        .env("COUCOU_JOB", job);
    finish(cmd)
}

/// One file through LibreOffice, into a folder of its own, then where it goes.
fn libreoffice(soffice: &Path, input: &Path, dest: &Path, filter: &str) -> Result<(), String> {
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let out = std::env::temp_dir().join(format!("coucou-office-{}-{stamp}", std::process::id()));
    std::fs::create_dir_all(&out).map_err(|e| e.to_string())?;
    let mut cmd = Command::new(soffice);
    cmd.args(["--headless", "--norestore", "--convert-to", filter, "--outdir"]).arg(&out).arg(input);
    let result = finish(cmd).and_then(|_| {
        let made = std::fs::read_dir(&out).map_err(|e| e.to_string())?.flatten().map(|e| e.path()).next().ok_or("LibreOffice made nothing")?;
        std::fs::rename(&made, dest).or_else(|_| std::fs::copy(&made, dest).map(|_| ())).map_err(|e| e.to_string())
    });
    let _ = std::fs::remove_dir_all(&out);
    result
}

/// Word's Unicode text is UTF-16: made UTF-8, as every editor expects.
pub fn utf8_text(path: &Path) -> Result<(), String> {
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let Some(body) = bytes.strip_prefix(&[0xFF, 0xFE]) else { return Ok(()) };
    let units: Vec<u16> = body.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).collect();
    let text = String::from_utf16_lossy(&units);
    std::fs::write(path, text.as_bytes()).map_err(|e| e.to_string())
}

/// Each file to `target`, next to it; `progress` from 0 to 1 over the files.
pub fn convert(paths: &[PathBuf], target: &str, progress: &dyn Fn(f64)) -> Result<Vec<PathBuf>, String> {
    let use_word = has_word();
    let office = if use_word { None } else { soffice() };
    if !use_word && office.is_none() {
        return Err("needs-office".into());
    }
    let mut out = Vec::new();
    for (i, path) in paths.iter().enumerate() {
        progress(i as f64 / paths.len() as f64);
        let dest = output_path(path, None, target);
        match &office {
            None => word(path, &dest, word_format(target).ok_or("not a document format")?, "convert")?,
            Some(soffice) => libreoffice(soffice, path, &dest, office_filter(target).ok_or("not a document format")?)?,
        }
        if target == "txt" {
            utf8_text(&dest)?;
        }
        if !dest.exists() {
            return Err(format!("{} wasn't converted", path.display()));
        }
        out.push(dest);
    }
    progress(1.0);
    Ok(out)
}

/// A copy of each document without its author, last editor and properties.
pub fn remove_metadata(paths: &[PathBuf], progress: &dyn Fn(f64)) -> Result<Vec<PathBuf>, String> {
    if !has_word() {
        return Err("needs-word".into());
    }
    let mut out = Vec::new();
    for (i, path) in paths.iter().enumerate() {
        progress(i as f64 / paths.len() as f64);
        let e = ext(path);
        let format = word_format(&e).ok_or("not a document Word can clean")?;
        let dest = output_path(path, Some("no metadata"), &e);
        word(path, &dest, format, "clean")?;
        out.push(dest);
    }
    progress(1.0);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_target_has_a_word_format_and_an_office_filter() {
        for t in DOCUMENT_TARGETS {
            assert!(word_format(t).is_some(), "{t}");
            assert!(office_filter(t).is_some(), "{t}");
        }
        for e in CLEANABLE {
            assert!(word_format(e).is_some(), "{e}");
        }
    }

    #[test]
    fn words_unicode_text_becomes_utf8() {
        let p = std::env::temp_dir().join(format!("coucou-utf16-{}.txt", std::process::id()));
        let mut bytes = vec![0xFF, 0xFE];
        for u in "Café ✓".encode_utf16() {
            bytes.extend_from_slice(&u.to_le_bytes());
        }
        std::fs::write(&p, bytes).unwrap();
        utf8_text(&p).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "Café ✓");
        // Already UTF-8: left alone.
        utf8_text(&p).unwrap();
        assert_eq!(std::fs::read_to_string(&p).unwrap(), "Café ✓");
        let _ = std::fs::remove_file(&p);
    }
}
