// The one careful way Nova changes a file that belongs to somebody else:
// Claude Code's settings.json, every other agent's hook config, and the plugin
// files a few agents load.
//
// The rules (CLAUDE.md) are applied here once, for everyone:
//   * read strictly — a file we cannot read or parse is an error, never "empty";
//   * the change is computed from the exact bytes the user was shown, identified
//     by a fingerprint, and refused if the file moved since;
//   * an edit refuses values of an unexpected type instead of replacing them;
//   * a dated backup of the current bytes is taken first and must succeed;
//   * the new contents are written beside the target and renamed over it,
//     keeping its permissions, and through a symlink to the file it points at.
//
// Nothing here decides *what* to change: callers hand in an `Edit` per file.

use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Value};

use crate::i18n::{t, tf};

/// What an edit wants a file to become.
pub struct Change {
    /// The current contents as the diff shows them.
    pub before: String,
    /// The new contents, or `None` to remove the file.
    pub after: Option<String>,
}

/// Computes the change for one file from its current bytes (`None`: no file).
pub type Edit<'a> = Box<dyn Fn(Option<&[u8]>) -> Result<Change, String> + 'a>;

/// One file and what to do with it.
pub struct FileEdit<'a> {
    pub path: PathBuf,
    pub edit: Edit<'a>,
}

/// What the user looks at before anything is written.
#[derive(Serialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Plan {
    pub diff: String,
    /// Where each existing file will be copied first, one per line; empty when
    /// there is nothing to back up.
    pub backup: String,
    /// The file (or files, one per line) that change.
    pub path: String,
    /// Identifies the exact bytes the diff was computed from; handed back to
    /// `apply` so only what the user actually looked at is ever written.
    pub fingerprint: String,
}

// ── Reading ───────────────────────────────────────────────────────────────────

/// The bytes of `path`, `None` when there is no such file. Anything else — a
/// lock, a permission problem, a directory in its place — is an error: not
/// knowing what is in a file is not the same as it being empty.
pub fn read(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match std::fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(err) if err.kind() == ErrorKind::NotFound => Ok(None),
        Err(err) => Err(tf("Can't read {path}: {error}", &[("path", &path.display().to_string()), ("error", &err.to_string())])),
    }
}

/// A JSON config as an object. A missing, empty or whitespace-only file is an
/// empty object; a UTF-8 BOM (PowerShell 5, Notepad) is stripped. Anything
/// else that is not a JSON object is refused.
pub fn parse_json(bytes: Option<&[u8]>, label: &str) -> Result<Value, String> {
    let Some(bytes) = bytes else { return Ok(json!({})) };
    let text = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if text.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    match serde_json::from_slice::<Value>(text) {
        Ok(v) if v.is_object() => Ok(v),
        Ok(_) => Err(tf("{file} isn't a JSON object — Nova won't touch it.", &[("file", label)])),
        Err(err) => Err(tf(
            "{file} isn't valid JSON ({error}). Fix or move it, then try again — Nova won't overwrite it.",
            &[("file", label), ("error", &err.to_string())],
        )),
    }
}

pub fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

/// An `Edit` for a JSON file: `change` gets the parsed object and returns the
/// new one, or `None` to remove the file. The diff compares both pretty-printed.
pub fn json_edit<'a>(
    label: String,
    change: impl Fn(&Value) -> Result<Option<Value>, String> + 'a,
) -> Edit<'a> {
    Box::new(move |bytes| {
        let current = parse_json(bytes, &label)?;
        let after = change(&current)?.map(|next| {
            let mut text = pretty(&next);
            text.push('\n');
            text
        });
        // A file that is not there yet shows as all additions.
        let before = if bytes.is_some() { pretty(&current) } else { String::new() };
        Ok(Change { before, after })
    })
}

/// An `Edit` for a text file Nova generates whole (a plugin): `change` gets
/// the current text and returns the new one, or `None` to remove the file.
pub fn text_edit<'a>(
    label: String,
    change: impl Fn(Option<&str>) -> Result<Option<String>, String> + 'a,
) -> Edit<'a> {
    Box::new(move |bytes| {
        let current = match bytes {
            None => None,
            Some(b) => Some(
                std::str::from_utf8(b)
                    .map_err(|_| tf("{file} isn't UTF-8 text — Nova won't touch it.", &[("file", &label)]))?,
            ),
        };
        let after = change(current)?;
        Ok(Change { before: current.unwrap_or_default().to_string(), after })
    })
}

// ── Preview and apply ─────────────────────────────────────────────────────────

/// Identifies the exact bytes a preview was computed from. FNV-1a is plenty:
/// the question is only "is this still the file I showed the user?".
pub fn fingerprint(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    format!("{hash:016x}")
}

/// A missing file and an empty one are told apart: creating a file someone
/// else just created must be refused too.
fn fingerprint_of(bytes: Option<&[u8]>) -> String {
    match bytes {
        Some(b) => fingerprint(b),
        None => "none".into(),
    }
}

/// The diff, backups and fingerprint for a set of edits. Nothing is written.
pub fn preview(edits: &[FileEdit]) -> Result<Plan, String> {
    let mut diffs = Vec::new();
    let mut backups = Vec::new();
    let mut paths = Vec::new();
    let mut prints = Vec::new();
    for file in edits {
        let current = read(&file.path)?;
        let change = (file.edit)(current.as_deref())?;
        let after = change.after.clone().unwrap_or_default();
        let mut diff = unified_diff(&change.before, after.trim_end_matches('\n'));
        match (&current, &change.after) {
            (Some(_), None) => diff = format!("{}\n{diff}", t("The file is removed.")),
            (None, None) => diff = t("No change."),
            _ => {}
        }
        if edits.len() > 1 {
            diff = format!("── {}\n{diff}", file.path.display());
        }
        diffs.push(diff);
        if current.is_some() {
            backups.push(backup_name(&file.path, &stamp(), 0).display().to_string());
        }
        paths.push(file.path.display().to_string());
        prints.push(fingerprint_of(current.as_deref()));
    }
    Ok(Plan {
        diff: diffs.join("\n"),
        backup: backups.join("\n"),
        path: paths.join("\n"),
        fingerprint: prints.join(":"),
    })
}

/// Applies the edits the user confirmed. Returns the backups taken.
///
/// Every file is read, checked against `expected` and edited before anything
/// is touched; then every existing file is backed up; only then is anything
/// written. A file that changed since the preview — another tool, another
/// window, the user's own editor — stops everything: the only thing worse than
/// not installing is silently reverting somebody else's edit.
pub fn apply(edits: &[FileEdit], expected: &str) -> Result<Vec<PathBuf>, String> {
    let wanted: Vec<&str> = expected.split(':').collect();
    if wanted.len() != edits.len() {
        return Err(t("The preview is out of date. Nothing was written — review the new diff."));
    }
    let mut planned = Vec::new();
    for (file, want) in edits.iter().zip(wanted) {
        let current = read(&file.path)?;
        if fingerprint_of(current.as_deref()) != want {
            return Err(tf(
                "{path} changed since the preview. Nothing was written — review the new diff.",
                &[("path", &file.path.display().to_string())],
            ));
        }
        let change = (file.edit)(current.as_deref())?;
        planned.push((file, current, change.after));
    }

    let mut backups = Vec::new();
    for (file, current, _) in &planned {
        if let Some(bytes) = current {
            let copy = back_up(&file.path, bytes)
                .map_err(|e| {
                    tf(
                        "Backup of {path} failed, nothing was written: {error}",
                        &[("path", &file.path.display().to_string()), ("error", &e.to_string())],
                    )
                })?;
            backups.push(copy);
        }
    }

    for (file, current, after) in planned {
        match after {
            Some(text) => replace(&file.path, text.as_bytes())
                .map_err(|e| {
                    tf("Write to {path} failed: {error}", &[("path", &file.path.display().to_string()), ("error", &e.to_string())])
                })?,
            None if current.is_some() => std::fs::remove_file(resolve_link(&file.path))
                .map_err(|e| {
                    tf("Could not remove {path}: {error}", &[("path", &file.path.display().to_string()), ("error", &e.to_string())])
                })?,
            None => {}
        }
    }
    Ok(backups)
}

// ── Writing ───────────────────────────────────────────────────────────────────

/// Down to the second: installing then uninstalling in the same minute must not
/// quietly overwrite the first backup.
fn stamp() -> String {
    let t = crate::platform::local_time();
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        t.year, t.month, t.day, t.hour, t.minute, t.second
    )
}

/// `settings.json.bak-20260102-030405`, then `-1`, `-2`… while that is taken.
fn backup_name(path: &Path, stamp: &str, n: u32) -> PathBuf {
    let name = path.file_name().unwrap_or_default().to_string_lossy();
    match n {
        0 => path.with_file_name(format!("{name}.bak-{stamp}")),
        n => path.with_file_name(format!("{name}.bak-{stamp}-{n}")),
    }
}

/// Copies `bytes` — the very bytes the change was computed from — beside
/// `path`. A backup that already exists is never written over, and one that
/// could not be written whole is removed rather than left looking faithful.
fn back_up(path: &Path, bytes: &[u8]) -> std::io::Result<PathBuf> {
    let stamp = stamp();
    for n in 0..100 {
        let copy = backup_name(path, &stamp, n);
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        match options.open(&copy) {
            Ok(mut file) => {
                let written = write_whole(&mut file, bytes).and_then(|()| keep_mode(&file, path));
                drop(file);
                if let Err(err) = written {
                    let _ = std::fs::remove_file(&copy);
                    return Err(err);
                }
                return Ok(copy);
            }
            Err(err) if err.kind() == ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(err),
        }
    }
    Err(std::io::Error::new(ErrorKind::AlreadyExists, "too many backups this second"))
}

fn write_whole(file: &mut std::fs::File, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    file.write_all(bytes)?;
    file.sync_all()
}

/// Gives `file` the permissions of `original` (ours only when there is none).
/// A config can hold API keys: a rewrite or a backup must never widen access.
fn keep_mode(file: &std::fs::File, original: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(original)
            .map(|m| m.permissions().mode() & 0o777)
            .unwrap_or(0o600);
        file.set_permissions(std::fs::Permissions::from_mode(mode))?;
    }
    #[cfg(not(unix))]
    let _ = (file, original);
    Ok(())
}

/// Writes `bytes` to `temp`, which is about to replace `original`: created
/// readable by us only, then given the original's permissions.
pub fn write_like(temp: &Path, original: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    let mut file = options.open(temp)?;
    write_whole(&mut file, bytes)?;
    keep_mode(&file, original)
}

/// The file a symlinked config points at (on Windows too), else `path` itself.
fn resolve_link(path: &Path) -> std::path::PathBuf {
    let is_link = std::fs::symlink_metadata(path).map(|m| m.file_type().is_symlink()).unwrap_or(false);
    if is_link {
        std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
    } else {
        path.to_path_buf()
    }
}

/// Replaces `path` with `bytes`: written beside it and renamed over it, so a
/// crash or a full disk leaves the original intact rather than half a file.
fn replace(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    // A dotfiles setup often makes a config a symlink: write to the file it
    // points at, so the link survives the rename.
    let resolved = resolve_link(path);
    let path = resolved.as_path();

    let name = path.file_name().unwrap_or_default().to_string_lossy();
    let temp = path.with_file_name(format!("{name}.nova-{}", std::process::id()));
    let result = write_like(&temp, path, bytes).and_then(|()| std::fs::rename(&temp, path));
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

// ── Minimal unified diff (LCS) ────────────────────────────────────────────────

/// Config files are short, so a plain O(n·m) LCS is the simplest honest diff.
pub fn unified_diff(before: &str, after: &str) -> String {
    let a: Vec<&str> = before.lines().collect();
    let b: Vec<&str> = after.lines().collect();
    let (n, m) = (a.len(), b.len());

    let mut lcs = vec![vec![0usize; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if a[i] == b[j] {
                lcs[i + 1][j + 1] + 1
            } else {
                lcs[i + 1][j].max(lcs[i][j + 1])
            };
        }
    }

    let mut out: Vec<String> = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if a[i] == b[j] {
            out.push(format!("  {}", a[i]));
            i += 1;
            j += 1;
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            out.push(format!("- {}", a[i]));
            i += 1;
        } else {
            out.push(format!("+ {}", b[j]));
            j += 1;
        }
    }
    while i < n {
        out.push(format!("- {}", a[i]));
        i += 1;
    }
    while j < m {
        out.push(format!("+ {}", b[j]));
        j += 1;
    }

    // Keep three lines of context around each change so the panel stays readable.
    let changed: Vec<usize> = out
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with('+') || l.starts_with('-'))
        .map(|(i, _)| i)
        .collect();
    if changed.is_empty() {
        return "No change.".into();
    }
    let mut keep = vec![false; out.len()];
    for idx in changed {
        let lo = idx.saturating_sub(3);
        let hi = (idx + 4).min(out.len());
        for k in lo..hi {
            keep[k] = true;
        }
    }
    let mut result = String::new();
    let mut gap = false;
    for (idx, line) in out.iter().enumerate() {
        if keep[idx] {
            result.push_str(line);
            result.push('\n');
            gap = false;
        } else if !gap {
            result.push_str("  …\n");
            gap = true;
        }
    }
    result
}

#[cfg(test)]
pub mod tests {
    use super::*;

    /// A fresh directory of our own.
    pub fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("nova-cfg-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn names(dir: &Path) -> Vec<String> {
        let mut names: Vec<String> = std::fs::read_dir(dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().to_string())
            .collect();
        names.sort();
        names
    }

    /// Adds `"ours": true` and refuses a `hooks` that is not an object.
    fn add_ours(path: &Path) -> Vec<FileEdit<'static>> {
        vec![FileEdit {
            path: path.to_path_buf(),
            edit: json_edit("test.json".into(), |v| {
                if v.get("hooks").is_some_and(|h| !h.is_object()) {
                    return Err("\"hooks\" has an unexpected type — Nova has not touched it.".into());
                }
                let mut next = v.clone();
                next["ours"] = json!(true);
                Ok(Some(next))
            }),
        }]
    }

    fn remove_file_edit(path: &Path) -> Vec<FileEdit<'static>> {
        vec![FileEdit { path: path.to_path_buf(), edit: json_edit("test.json".into(), |_| Ok(None)) }]
    }

    #[test]
    fn unreadable_content_is_an_error_never_an_empty_object() {
        for bad in [&b"{ not json"[..], &b"[1,2,3]"[..], &b"\"a string\""[..]] {
            assert!(parse_json(Some(bad), "x").is_err());
        }
        assert_eq!(parse_json(None, "x").unwrap(), json!({}));
        assert_eq!(parse_json(Some(b" \n\t"), "x").unwrap(), json!({}));
        let mut bom = vec![0xEF, 0xBB, 0xBF];
        bom.extend_from_slice(br#"{"a":1}"#);
        assert_eq!(parse_json(Some(&bom), "x").unwrap()["a"], 1);
    }

    #[test]
    fn a_fingerprint_notices_any_change_and_tells_missing_from_empty() {
        assert_eq!(fingerprint(b"{}"), fingerprint(b"{}"));
        assert_ne!(fingerprint(b"{}"), fingerprint(b"{ }"));
        assert_ne!(fingerprint_of(None), fingerprint_of(Some(b"")));
    }

    #[test]
    fn the_backup_holds_the_original_bytes_and_the_rest_is_kept() {
        let dir = scratch("backup");
        let path = dir.join("settings.json");
        let mut original = vec![0xEF, 0xBB, 0xBF];
        original.extend_from_slice(br#"{"model":"opus","keep":{"x":[1,2]}}"#);
        std::fs::write(&path, &original).unwrap();

        let plan = preview(&add_ours(&path)).unwrap();
        assert!(plan.diff.contains("\"ours\": true"), "{}", plan.diff);
        assert!(plan.backup.contains("settings.json.bak-"));
        let backups = apply(&add_ours(&path), &plan.fingerprint).unwrap();
        assert_eq!(backups.len(), 1);
        assert_eq!(std::fs::read(&backups[0]).unwrap(), original);

        let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(after["model"], "opus");
        assert_eq!(after["keep"]["x"], json!([1, 2]));
        assert_eq!(after["ours"], true);
        // Nothing but the file and its backup: no temporary left behind.
        assert_eq!(names(&dir).len(), 2);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn two_backups_in_the_same_second_never_overwrite_each_other() {
        let dir = scratch("twice");
        let path = dir.join("hooks.json");
        std::fs::write(&path, b"{}").unwrap();
        let first = apply(&add_ours(&path), &fingerprint(b"{}")).unwrap();
        let now = std::fs::read(&path).unwrap();
        let second = apply(&add_ours(&path), &fingerprint(&now)).unwrap();
        assert_ne!(first, second);
        assert_eq!(std::fs::read(&first[0]).unwrap(), b"{}");
        assert_eq!(std::fs::read(&second[0]).unwrap(), now);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_backup_that_cannot_be_taken_stops_everything() {
        let dir = scratch("nobackup");
        // A name the file system accepts, but too long for ".bak-<stamp>" on top.
        let path = dir.join(format!("{}.json", "s".repeat(240)));
        std::fs::write(&path, b"{}").unwrap();
        let err = apply(&add_ours(&path), &fingerprint(b"{}")).unwrap_err();
        assert!(err.contains("Backup"), "{err}");
        assert_eq!(std::fs::read(&path).unwrap(), b"{}");
        assert_eq!(names(&dir).len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_file_that_changed_since_the_preview_is_refused_and_left_alone() {
        let dir = scratch("changed");
        let path = dir.join("settings.json");
        std::fs::write(&path, b"{}").unwrap();
        let plan = preview(&add_ours(&path)).unwrap();
        std::fs::write(&path, br#"{"someone":"else"}"#).unwrap();
        let err = apply(&add_ours(&path), &plan.fingerprint).unwrap_err();
        assert!(err.contains("changed since the preview"), "{err}");
        assert_eq!(std::fs::read(&path).unwrap(), br#"{"someone":"else"}"#);

        // A file created since a preview of "no file" is refused too.
        let fresh = dir.join("new.json");
        let plan = preview(&add_ours(&fresh)).unwrap();
        std::fs::write(&fresh, b"").unwrap();
        assert!(apply(&add_ours(&fresh), &plan.fingerprint).is_err());
        assert_eq!(std::fs::read(&fresh).unwrap(), b"");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn unexpected_types_and_invalid_json_are_refused_before_anything_is_written() {
        let dir = scratch("types");
        let path = dir.join("settings.json");
        for bad in [&br#"{"hooks":"a string"}"#[..], &b"{ broken"[..]] {
            std::fs::write(&path, bad).unwrap();
            assert!(preview(&add_ours(&path)).is_err());
            assert!(apply(&add_ours(&path), &fingerprint(bad)).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), bad);
        }
        assert_eq!(names(&dir), ["settings.json"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_new_file_is_created_with_its_folder_and_nothing_is_backed_up() {
        let dir = scratch("create");
        let path = dir.join("deep").join("er").join("hooks.json");
        let plan = preview(&add_ours(&path)).unwrap();
        assert_eq!(plan.backup, "");
        assert!(apply(&add_ours(&path), &plan.fingerprint).unwrap().is_empty());
        let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(after, json!({ "ours": true }));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn removing_a_file_backs_it_up_first() {
        let dir = scratch("remove");
        let path = dir.join("nova.json");
        std::fs::write(&path, b"{\"a\":1}").unwrap();
        let plan = preview(&remove_file_edit(&path)).unwrap();
        assert!(plan.diff.starts_with("The file is removed."));
        let backups = apply(&remove_file_edit(&path), &plan.fingerprint).unwrap();
        assert!(!path.exists());
        assert_eq!(std::fs::read(&backups[0]).unwrap(), b"{\"a\":1}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn several_files_are_checked_together() {
        let dir = scratch("many");
        let (a, b) = (dir.join("a.json"), dir.join("b.json"));
        std::fs::write(&a, b"{}").unwrap();
        let edits = |a: &Path, b: &Path| {
            let mut v = add_ours(a);
            v.extend(add_ours(b));
            v
        };
        let plan = preview(&edits(&a, &b)).unwrap();
        // The second one appears in between: neither is written.
        std::fs::write(&b, b"{\"x\":1}").unwrap();
        assert!(apply(&edits(&a, &b), &plan.fingerprint).is_err());
        assert_eq!(std::fs::read(&a).unwrap(), b"{}");
        let plan = preview(&edits(&a, &b)).unwrap();
        apply(&edits(&a, &b), &plan.fingerprint).unwrap();
        for p in [&a, &b] {
            let v: Value = serde_json::from_slice(&std::fs::read(p).unwrap()).unwrap();
            assert_eq!(v["ours"], true);
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[cfg(unix)]
    #[test]
    fn rewriting_keeps_permissions_and_symlinks() {
        use std::os::unix::fs::PermissionsExt;
        let dir = scratch("perm");
        let real = dir.join("dotfiles-settings.json");
        let link = dir.join("settings.json");
        std::fs::write(&real, b"{}").unwrap();
        std::fs::set_permissions(&real, std::fs::Permissions::from_mode(0o640)).unwrap();
        std::os::unix::fs::symlink(&real, &link).unwrap();

        let backups = apply(&add_ours(&link), &fingerprint(b"{}")).unwrap();
        assert!(std::fs::symlink_metadata(&link).unwrap().file_type().is_symlink());
        let v: Value = serde_json::from_slice(&std::fs::read(&real).unwrap()).unwrap();
        assert_eq!(v["ours"], true);
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&real), 0o640);
        assert_eq!(mode(&backups[0]), 0o640);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_text_file_that_is_not_utf8_is_refused() {
        let edit = text_edit("plugin.js".into(), |_| Ok(Some("x".into())));
        assert!(edit(Some(&[0xff, 0xfe, 0x00])).is_err());
        let change = edit(None).unwrap();
        assert_eq!(change.before, "");
        assert_eq!(change.after.as_deref(), Some("x"));
    }
}
