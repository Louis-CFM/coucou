// Starting even when the registered WebView2 runtime is broken.
//
// EdgeUpdate can register a version (`pv`) whose folder no longer holds
// msedgewebview2.exe (an interrupted update, a file removed by an antivirus…).
// The WebView2 loader trusts the registry, fails with 0x80070002 and Tauri
// panics before any window opens; Microsoft's installer does not always manage
// to repair it. The previous version's folder is usually still there and
// intact: the loader is pointed at it through WEBVIEW2_BROWSER_EXECUTABLE_FOLDER,
// for this process only (programs Coucou starts don't get it, see keep_out_of).
//
// An intact registered runtime is never touched, and neither is a variable
// that is already set (by the user, or for a Fixed Version runtime).

use std::ffi::OsString;
use std::os::windows::ffi::OsStringExt;
use std::path::{Component, Path, PathBuf, Prefix};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};

use crate::log;

const FOLDER_VAR: &str = "WEBVIEW2_BROWSER_EXECUTABLE_FOLDER";
const BROWSER_EXE: &str = "msedgewebview2.exe";
/// The loader loads this from the chosen folder before it even starts
/// msedgewebview2.exe, so a usable folder needs both.
const EMBEDDED_DLL: &str = if cfg!(target_arch = "aarch64") {
    r"EBWebView\arm64\EmbeddedBrowserWebView.dll"
} else if cfg!(target_arch = "x86") {
    r"EBWebView\x86\EmbeddedBrowserWebView.dll"
} else {
    r"EBWebView\x64\EmbeddedBrowserWebView.dll"
};

/// EdgeUpdate's key for the Evergreen WebView2 runtime, under `SOFTWARE\`.
const CLIENT_KEY: &str = r"Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}";

/// True when repair_runtime_path, not the user, set the variable.
static PINNED: AtomicBool = AtomicBool::new(false);

/// A runtime as EdgeUpdate registered it.
struct Registration {
    /// `location`: the `…\EdgeWebView\Application` folder that holds the versions.
    location: PathBuf,
    /// `pv`: the version the loader looks for in `location`.
    version: String,
    /// Registered under HKLM, which only an administrator can write; otherwise
    /// under HKCU, which any program in the session can write.
    machine: bool,
}

/// To be called at the top of `run()`, before the first webview (see `set_var` below).
pub fn repair_runtime_path() {
    if std::env::var_os(FOLDER_VAR).is_some() {
        return;
    }
    let machine_root = machine_root();
    let registered = registrations(machine_root.as_deref());
    let Some(folder) = choose_folder(&registered, machine_root.as_deref(), children, |file| file.is_file()) else {
        return;
    };
    // The loader reads the variable when the first webview is created, so it
    // must be set before the Tauri Builder runs. No other thread exists yet,
    // which keeps set_var sound (it becomes `unsafe` in the 2024 edition).
    std::env::set_var(FOLDER_VAR, &folder);
    PINNED.store(true, Ordering::Relaxed);
    let expected: Vec<String> = registered
        .iter()
        .map(|r| r.location.join(&r.version).display().to_string())
        .collect();
    let expected = if expected.is_empty() { "no runtime registered".to_string() } else { expected.join(", ") };
    log::line(format!(
        "WebView2: no {BROWSER_EXE} where the registry points ({expected}), {FOLDER_VAR}={} for this launch; \
         this version stays pinned until the WebView2 runtime is repaired or reinstalled",
        folder.display()
    ));
}

/// Applied to every program Coucou starts. Otherwise VS Code, Explorer or Claude
/// would hand the pinned folder down to all their descendants, stuck on a
/// version without its fixes, then on a folder EdgeUpdate has since deleted. A
/// variable the user set is passed on as before.
pub fn keep_out_of(cmd: &mut Command) -> &mut Command {
    withhold(cmd, PINNED.load(Ordering::Relaxed))
}

fn withhold(cmd: &mut Command, pinned: bool) -> &mut Command {
    if pinned {
        cmd.env_remove(FOLDER_VAR)
    } else {
        cmd
    }
}

/// The folder to give the loader, or `None` when there is nothing to do: a
/// registered runtime is intact, or no version folder is complete. The disk is
/// only read through `children` (a folder's entries) and `is_file`, which the
/// tests stand in for.
fn choose_folder(
    registered: &[Registration],
    machine_root: Option<&Path>,
    children: impl Fn(&Path) -> Vec<PathBuf>,
    is_file: impl Fn(&Path) -> bool,
) -> Option<PathBuf> {
    // The registered runtime is judged on its executable alone: anything
    // stricter could take a working runtime for a broken one.
    let healthy = registered
        .iter()
        .any(|r| !r.version.is_empty() && is_file(&r.location.join(&r.version).join(BROWSER_EXE)));
    if healthy {
        return None;
    }
    let best = |roots: &[&Path]| {
        roots
            .iter()
            .flat_map(|&root| children(root))
            .filter_map(|dir| Some((parse_version(dir.file_name()?.to_str()?)?, dir)))
            // An unfinished update can leave one without the other.
            .filter(|(_, dir)| is_file(&dir.join(BROWSER_EXE)) && is_file(&dir.join(EMBEDDED_DLL)))
            .max_by_key(|(version, _)| *version)
            .map(|(_, dir)| dir)
    };
    // The user's folders only count when the machine has no complete one: a
    // "999.0.0.0" that any program in the session can drop there must not win
    // over Program Files on its version number alone.
    let machine: Vec<&Path> = registered
        .iter()
        .filter(|r| r.machine)
        .map(|r| r.location.as_path())
        .chain(machine_root)
        .collect();
    let user: Vec<&Path> = registered.iter().filter(|r| !r.machine).map(|r| r.location.as_path()).collect();
    best(&machine).or_else(|| best(&user))
}

/// `154.0.4258.53` → `[154, 0, 4258, 53]`, compared number by number
/// (`.9` < `.53`); any other folder name → `None`.
fn parse_version(name: &str) -> Option<[u32; 4]> {
    let mut parts = name.split('.');
    let mut version = [0u32; 4];
    for slot in &mut version {
        let part = parts.next()?;
        // u32::from_str would accept "+5".
        if part.is_empty() || !part.bytes().all(|b| b.is_ascii_digit()) {
            return None;
        }
        *slot = part.parse().ok()?;
    }
    parts.next().is_none().then_some(version)
}

/// A registration from its two registry values, `default_location` being the
/// default install folder for its scope.
fn registration(
    version: Option<String>,
    location: Option<String>,
    default_location: Option<PathBuf>,
    machine: bool,
) -> Option<Registration> {
    // `pv` becomes a folder name: `..\..\x` is not a version.
    let version = version.filter(|v| parse_version(v).is_some());
    // Empty, relative (resolved against the launch's current folder) or on the
    // network (an SMB connection at startup): the same as missing.
    let location = location.map(PathBuf::from).filter(|l| is_local_absolute(l));
    if version.is_none() && location.is_none() {
        return None;
    }
    Some(Registration {
        // Without `location`, `pv` is checked in the default install folder: a
        // healthy runtime must never pass for a broken one.
        location: location.or(default_location)?,
        version: version.unwrap_or_default(),
        machine,
    })
}

/// `C:\…` or `\\?\C:\…`: neither relative nor on the network.
fn is_local_absolute(path: &Path) -> bool {
    path.is_absolute()
        && matches!(
            path.components().next(),
            Some(Component::Prefix(prefix)) if matches!(prefix.kind(), Prefix::Disk(_) | Prefix::VerbatimDisk(_))
        )
}

// ── Disk and registry ─────────────────────────────────────────────────────────

/// `…\Program Files (x86)\Microsoft\EdgeWebView\Application`, where the runtime
/// is installed for the whole machine. No path is guessed when Windows doesn't
/// give one: a `C:\Program Files (x86)` on a C: that isn't the system drive may
/// have been created by any account.
fn machine_root() -> Option<PathBuf> {
    std::env::var_os("ProgramFiles(x86)")
        .or_else(|| reg_string(HKEY_LOCAL_MACHINE, r"SOFTWARE\Microsoft\Windows\CurrentVersion", "ProgramFilesDir (x86)"))
        .map(PathBuf::from)
        .filter(|dir| is_local_absolute(dir))
        .map(|dir| dir.join(r"Microsoft\EdgeWebView\Application"))
}

fn children(dir: &Path) -> Vec<PathBuf> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    entries.flatten().map(|e| e.path()).collect()
}

/// The three places where EdgeUpdate registers the runtime: the machine (the
/// 32-bit view, the most common, then the 64-bit one) and the user.
fn registrations(machine_root: Option<&Path>) -> Vec<Registration> {
    let user_root = std::env::var_os("LOCALAPPDATA")
        .map(|d| PathBuf::from(d).join(r"Microsoft\EdgeWebView\Application"))
        .filter(|dir| is_local_absolute(dir));
    let places = [
        (HKEY_LOCAL_MACHINE, r"SOFTWARE\WOW6432Node\", machine_root.map(Path::to_path_buf), true),
        (HKEY_LOCAL_MACHINE, r"SOFTWARE\", machine_root.map(Path::to_path_buf), true),
        (HKEY_CURRENT_USER, r"Software\", user_root, false),
    ];
    places
        .into_iter()
        .filter_map(|(hive, prefix, default_location, machine)| {
            let key = format!("{prefix}{CLIENT_KEY}");
            let value = |name: &str| reg_string(hive, &key, name).map(|v| v.to_string_lossy().into_owned());
            registration(value("pv"), value("location"), default_location, machine)
        })
        .collect()
}

// Declared by hand with its documented C signature, like the calls in
// platform/windows.rs, so it needs no extra `Win32_System_Registry` feature.
#[link(name = "advapi32")]
extern "system" {
    fn RegGetValueW(
        hkey: isize,
        sub_key: *const u16,
        value: *const u16,
        flags: u32,
        kind: *mut u32,
        data: *mut core::ffi::c_void,
        size: *mut u32,
    ) -> i32;
}

// The predefined HKEYs are negative LONGs, sign-extended to pointer size.
const HKEY_CURRENT_USER: isize = 0x8000_0001_u32 as i32 as isize;
const HKEY_LOCAL_MACHINE: isize = 0x8000_0002_u32 as i32 as isize;
/// REG_SZ, or a REG_EXPAND_SZ that RegGetValueW has already expanded.
const RRF_RT_REG_SZ: u32 = 0x0000_0002;

fn reg_string(hive: isize, key: &str, name: &str) -> Option<OsString> {
    let key: Vec<u16> = key.encode_utf16().chain(std::iter::once(0)).collect();
    let name: Vec<u16> = name.encode_utf16().chain(std::iter::once(0)).collect();
    let mut bytes = 0u32;
    // A first call for the size, in bytes, terminating zero included.
    let status = unsafe {
        RegGetValueW(
            hive,
            key.as_ptr(),
            name.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            &mut bytes,
        )
    };
    if status != 0 || bytes == 0 {
        return None;
    }
    let mut buf = vec![0u16; (bytes as usize).div_ceil(2)];
    let mut bytes = (buf.len() * 2) as u32;
    let status = unsafe {
        RegGetValueW(
            hive,
            key.as_ptr(),
            name.as_ptr(),
            RRF_RT_REG_SZ,
            std::ptr::null_mut(),
            buf.as_mut_ptr().cast(),
            &mut bytes,
        )
    };
    if status != 0 {
        return None;
    }
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    Some(OsString::from_wide(&buf[..len]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const ROOT: &str = r"C:\Program Files (x86)\Microsoft\EdgeWebView\Application";
    const USER: &str = r"C:\Users\me\AppData\Local\Microsoft\EdgeWebView\Application";

    /// What a version folder holds: complete, then unfinished in two ways.
    const FULL: &[&str] = &[BROWSER_EXE, EMBEDDED_DLL];
    const NO_EXE: &[&str] = &[EMBEDDED_DLL];
    const NO_DLL: &[&str] = &[BROWSER_EXE];
    const EMPTY: &[&str] = &[];

    fn machine(location: &str, version: &str) -> Registration {
        Registration { location: PathBuf::from(location), version: version.to_string(), machine: true }
    }

    fn user(location: &str, version: &str) -> Registration {
        Registration { location: PathBuf::from(location), version: version.to_string(), machine: false }
    }

    /// `disk`: (root folder, subfolder, the files it holds).
    fn choose(registered: &[Registration], disk: &[(&str, &str, &[&str])]) -> Option<PathBuf> {
        let mut tree: HashMap<PathBuf, Vec<PathBuf>> = HashMap::new();
        let mut files = Vec::new();
        for (root, name, present) in disk {
            let dir = Path::new(root).join(name);
            tree.entry(PathBuf::from(root)).or_default().push(dir.clone());
            files.extend(present.iter().map(|file| dir.join(file)));
        }
        choose_folder(
            registered,
            Some(Path::new(ROOT)),
            |root| tree.get(root).cloned().unwrap_or_default(),
            |file| files.iter().any(|f| f == file),
        )
    }

    fn under(root: &str, name: &str) -> Option<PathBuf> {
        Some(Path::new(root).join(name))
    }

    #[test]
    fn a_healthy_runtime_is_left_alone() {
        let reg = [machine(ROOT, "154.0.4258.62")];
        let disk = [(ROOT, "154.0.4258.53", FULL), (ROOT, "154.0.4258.62", FULL), (ROOT, "199.0.0.1", FULL)];
        assert_eq!(choose(&reg, &disk), None);
    }

    #[test]
    fn a_registered_version_without_its_exe_falls_back_to_the_best_healthy_folder() {
        // The failure seen on a real machine: pv names a folder without the executable.
        let reg = [machine(ROOT, "154.0.4258.62")];
        let disk = [
            (ROOT, "154.0.4258.53", FULL),
            (ROOT, "154.0.4258.62", NO_EXE),
            (ROOT, "SetupMetrics", EMPTY),
        ];
        assert_eq!(choose(&reg, &disk), under(ROOT, "154.0.4258.53"));
    }

    #[test]
    fn an_empty_registered_version_takes_the_highest_healthy_folder() {
        let reg = [machine(ROOT, "")];
        let disk = [
            (ROOT, "120.0.2210.91", FULL),
            (ROOT, "154.0.4258.53", FULL),
            (ROOT, "155.0.1.0", NO_EXE),
        ];
        assert_eq!(choose(&reg, &disk), under(ROOT, "154.0.4258.53"));
    }

    #[test]
    fn a_folder_without_the_embedded_dll_is_not_a_candidate() {
        // A higher unfinished update: the executable without the DLL.
        let reg = [machine(ROOT, "154.0.4258.62")];
        let disk = [
            (ROOT, "154.0.4258.53", FULL),
            (ROOT, "154.0.4258.62", NO_EXE),
            (ROOT, "155.0.1.0", NO_DLL),
        ];
        assert_eq!(choose(&reg, &disk), under(ROOT, "154.0.4258.53"));
    }

    #[test]
    fn the_registered_runtime_is_judged_on_its_exe_alone() {
        let reg = [machine(ROOT, "154.0.4258.62")];
        let disk = [(ROOT, "154.0.4258.53", FULL), (ROOT, "154.0.4258.62", NO_DLL)];
        assert_eq!(choose(&reg, &disk), None);
    }

    #[test]
    fn malformed_version_folders_are_ignored() {
        let malformed = [
            "SetupMetrics",
            "154.0.4258",
            "154.0.4258.53.1",
            "154.0.x.53",
            "+154.0.4258.53",
            "-1.0.0.0",
            "154..4258.53",
            "154.0.4258.53 ",
            "99999999999.0.0.0",
            "",
        ];
        for name in malformed {
            assert_eq!(parse_version(name), None, "{name:?}");
        }
        let mut disk: Vec<(&str, &str, &[&str])> =
            malformed.iter().filter(|n| !n.is_empty()).map(|n| (ROOT, *n, FULL)).collect();
        disk.push((ROOT, "1.2.3.4", FULL));
        assert_eq!(choose(&[], &disk), under(ROOT, "1.2.3.4"));
    }

    #[test]
    fn no_candidate_means_nothing_to_do() {
        assert_eq!(choose(&[], &[]), None);
        let reg = [machine(ROOT, "154.0.4258.62")];
        let disk = [(ROOT, "154.0.4258.62", NO_EXE), (ROOT, "154.0.4258.53", NO_EXE)];
        assert_eq!(choose(&reg, &disk), None);
    }

    #[test]
    fn versions_compare_as_numbers_not_as_text() {
        assert!(parse_version("154.0.4258.9").unwrap() < parse_version("154.0.4258.53").unwrap());
        assert!(parse_version("99.0.0.0").unwrap() < parse_version("100.0.0.0").unwrap());
        let disk = [(ROOT, "154.0.4258.9", FULL), (ROOT, "154.0.4258.53", FULL)];
        assert_eq!(choose(&[], &disk), under(ROOT, "154.0.4258.53"));
    }

    #[test]
    fn every_registered_location_counts() {
        // An intact user runtime is enough, even when the machine's is broken.
        let reg = [machine(ROOT, "154.0.4258.62"), user(USER, "153.0.3.1")];
        let disk = [(ROOT, "154.0.4258.62", NO_EXE), (USER, "153.0.3.1", FULL)];
        assert_eq!(choose(&reg, &disk), None);
        // All broken, and nothing complete on the machine side: the user's
        // folders are candidates.
        let reg = [machine(ROOT, "154.0.4258.62"), user(USER, "")];
        assert_eq!(choose(&reg, &disk), under(USER, "153.0.3.1"));
    }

    #[test]
    fn a_machine_folder_wins_over_a_higher_user_one() {
        let reg = [machine(ROOT, "154.0.4258.62"), user(USER, "")];
        let disk = [
            (ROOT, "154.0.4258.62", NO_EXE),
            (ROOT, "154.0.4258.53", FULL),
            (USER, "999.0.0.0", FULL),
        ];
        assert_eq!(choose(&reg, &disk), under(ROOT, "154.0.4258.53"));
    }

    #[test]
    fn a_registered_version_without_location_is_checked_in_the_default_folder() {
        let reg = registration(Some("154.0.4258.62".into()), None, Some(PathBuf::from(ROOT)), true).unwrap();
        assert_eq!((reg.location.as_path(), reg.version.as_str()), (Path::new(ROOT), "154.0.4258.62"));
        // Healthy there: nothing to do, even though other folders exist.
        let disk = [(ROOT, "154.0.4258.62", FULL), (ROOT, "154.0.4258.53", FULL)];
        assert_eq!(choose(&[reg], &disk), None);
    }

    #[test]
    fn registry_values_are_kept_only_when_they_make_sense() {
        let default = || Some(PathBuf::from(ROOT));
        assert!(registration(None, None, default(), true).is_none());
        // `location` without `pv`: its folders remain candidates.
        let reg = registration(None, Some(USER.into()), default(), false).unwrap();
        assert_eq!((reg.location.as_path(), reg.version.as_str()), (Path::new(USER), ""));
        // An empty, relative or network `location` counts as a missing one.
        for bad in ["", "Application", r"\Microsoft\EdgeWebView", r"\\server\share\EdgeWebView", r"\\?\UNC\server\share"] {
            let reg = registration(Some("154.0.4258.62".into()), Some(bad.into()), default(), true).unwrap();
            assert_eq!(reg.location, PathBuf::from(ROOT), "{bad:?}");
            assert!(registration(None, Some(bad.into()), default(), true).is_none(), "{bad:?}");
        }
        assert!(is_local_absolute(Path::new(r"\\?\C:\Program Files (x86)")));
        // A `pv` that is not a version counts as a missing one.
        let reg = registration(Some(r"..\..\x".into()), Some(USER.into()), default(), false).unwrap();
        assert_eq!(reg.version, "");
        // Without a known default folder, a lone `pv` cannot be checked anywhere.
        assert!(registration(Some("154.0.4258.62".into()), None, None, true).is_none());
    }

    #[test]
    fn only_a_folder_pinned_here_is_kept_from_child_processes() {
        let mut cmd = Command::new("code");
        let removed: Vec<_> = withhold(&mut cmd, true).get_envs().collect();
        assert_eq!(removed, [(std::ffi::OsStr::new(FOLDER_VAR), None)]);
        let mut cmd = Command::new("code");
        assert_eq!(withhold(&mut cmd, false).get_envs().count(), 0);
    }
}
