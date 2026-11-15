// A new Claude Code session from the island, and a file dropped on a session —
// ports of LaunchScript.swift, SessionLauncher.swift and SessionDrop.swift.
//
// Launch: the user's terminal opens in the project with `claude` and the
// prompt. The prompt is never spliced into a command line:
// - Linux: it travels in COUCOU_PROMPT, set on the terminal's process, and the
//   user's login shell runs `claude "$COUCOU_PROMPT"` (as the Mac's script).
// - Windows: Windows Terminal starts its tabs with a fresh environment, not
//   wt.exe's (microsoft/terminal#11094), so an environment variable set on
//   wt.exe never reaches the tab. The prompt goes into a file of ours in the
//   temp folder instead; PowerShell reads it into $env:COUCOU_PROMPT, deletes
//   it, and runs claude with that variable. Only the file's path, which we
//   made, is in the command line.
// The session then shows in the island like any other, through the hooks.
//
// Drop: the session's window comes forward (the same lookup as "Open
// terminal", session_window.rs) and the paths are pasted with Flow's paste
// (flow/paste.rs), escaped as a drag onto that terminal would write them.
//
// The command lines are built by the pure functions below, tested here; the
// spawning and the OS calls are the few lines after them.

use std::path::Path;
use std::process::Command;
use std::time::Duration;

use crate::{flow, herdr, platform, session_window};

/// What to start: a program, its arguments, extra environment, its folder.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Spawn {
    pub program: String,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub dir: String,
}

/// The prompt as it is handed over: trimmed, on one line.
pub fn clean_prompt(prompt: &str) -> String {
    prompt.split(['\r', '\n']).map(str::trim).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ")
}

/// A folder a session may start in: an existing folder given by its full path.
pub fn valid_folder(folder: &str) -> bool {
    let p = Path::new(folder);
    !folder.is_empty() && p.is_absolute() && p.is_dir()
}

// ── Linux ─────────────────────────────────────────────────────────────────────

/// The shell's single quotes, only where needed: 'it'\''s' for it's.
#[cfg_attr(windows, allow(dead_code))]
pub fn sh_quote(s: &str) -> String {
    let plain = !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || "/._-+=:@,".contains(c));
    if plain {
        s.to_string()
    } else {
        format!("'{}'", s.replace('\'', r"'\''"))
    }
}

/// What the terminal runs: the user's login shell (so `claude` is found as in
/// any terminal), Claude Code with the prompt from COUCOU_PROMPT, then the
/// shell again in the project once Claude Code quits.
#[cfg_attr(windows, allow(dead_code))]
pub fn shell_command(shell: &str, has_prompt: bool) -> Vec<String> {
    let run = if has_prompt { r#"claude "$COUCOU_PROMPT""# } else { "claude" };
    vec![shell.to_string(), "-lic".to_string(), format!("{run}; exec {} -l", sh_quote(shell))]
}

/// The terminals we know how to hand a command and a folder to, best first
/// after $TERMINAL: the desktop's own default (Debian's x-terminal-emulator),
/// then the usual ones.
#[cfg_attr(windows, allow(dead_code))]
pub const LINUX_TERMINALS: &[&str] = &[
    "x-terminal-emulator", "gnome-terminal", "ptyxis", "konsole", "kitty", "alacritty", "wezterm", "foot", "xterm",
];

/// The terminals to try, in order: $TERMINAL's program first, if set.
#[cfg_attr(windows, allow(dead_code))]
pub fn linux_candidates(env_terminal: Option<&str>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    if let Some(first) = env_terminal.and_then(|t| t.split_whitespace().next()) {
        out.push(first.to_string());
    }
    for t in LINUX_TERMINALS {
        if !out.iter().any(|o| o == t) {
            out.push(t.to_string());
        }
    }
    out
}

/// The arguments that make `terminal` open a window in `dir` running `command`.
/// Unknown terminals get the common `-e` (as x-terminal-emulator must take).
/// konsole and wezterm are asked for a process of their own, so the window
/// gets this environment (COUCOU_PROMPT) and not the one of a running copy.
#[cfg_attr(windows, allow(dead_code))]
pub fn linux_terminal_args(terminal: &str, dir: &str, command: &[String]) -> Vec<String> {
    let name = Path::new(terminal).file_name().and_then(|n| n.to_str()).unwrap_or(terminal);
    let mut args: Vec<String> = match name {
        "gnome-terminal" => vec![format!("--working-directory={dir}"), "--".into()],
        "ptyxis" => vec!["--new-window".into(), "-d".into(), dir.into(), "--".into()],
        "konsole" => vec!["--separate".into(), "--workdir".into(), dir.into(), "-e".into()],
        "kitty" => vec!["--directory".into(), dir.into()],
        "alacritty" => vec!["--working-directory".into(), dir.into(), "-e".into()],
        "wezterm" => vec!["start".into(), "--always-new-process".into(), "--cwd".into(), dir.into(), "--".into()],
        "foot" => vec![format!("--working-directory={dir}")],
        _ => vec!["-e".into()],
    };
    args.extend(command.iter().cloned());
    args
}

/// The whole launch on Linux, `terminal` being the one found.
#[cfg_attr(windows, allow(dead_code))]
pub fn linux_spawn(terminal: &str, shell: &str, folder: &str, prompt: &str) -> Spawn {
    let prompt = clean_prompt(prompt);
    let command = shell_command(shell, !prompt.is_empty());
    let env = if prompt.is_empty() { Vec::new() } else { vec![("COUCOU_PROMPT".to_string(), prompt)] };
    Spawn { program: terminal.to_string(), args: linux_terminal_args(terminal, folder, &command), env, dir: folder.to_string() }
}

// ── Windows ───────────────────────────────────────────────────────────────────

/// PowerShell's single quotes: 'it''s' for it's.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn ps_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

/// The prompt as it is written to the file on Windows. `claude` there is
/// often npm's claude.cmd, and cmd.exe reads its command line again: a double
/// quote in the prompt would end the quoted argument and let the rest run as
/// commands. It becomes a single quote, which reads the same to Claude.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn windows_prompt(prompt: &str) -> String {
    clean_prompt(prompt).replace('"', "'")
}

/// What PowerShell runs. With a prompt: read the file into COUCOU_PROMPT,
/// delete it, start Claude Code with it. `Get-Command -CommandType
/// Application` takes claude.exe or claude.cmd, never npm's claude.ps1, which
/// the default execution policy refuses to run. No double quote and nothing
/// but the file's path, which is ours, is spelled out.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn powershell_script(prompt_file: Option<&str>) -> String {
    let claude = "& (Get-Command claude -CommandType Application -TotalCount 1)";
    match prompt_file {
        None => claude.to_string(),
        Some(file) => {
            let f = ps_quote(file);
            format!(
                "$env:COUCOU_PROMPT = Get-Content -LiteralPath {f} -Raw -Encoding UTF8; \
                 Remove-Item -LiteralPath {f}; {claude} $env:COUCOU_PROMPT"
            )
        }
    }
}

/// wt.exe splits its command line into several commands at each `;`: in the
/// command it hands the shell, they are written `\;`.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn wt_escape(s: &str) -> String {
    s.replace(';', r"\;")
}

/// The whole launch on Windows: in Windows Terminal (`wt`, its path) when it
/// is installed, else PowerShell in a console of its own (the caller gives it
/// one). `shell` is pwsh.exe or powershell.exe.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn windows_spawn(wt: Option<&str>, shell: &str, folder: &str, prompt_file: Option<&str>) -> Spawn {
    let script = powershell_script(prompt_file);
    match wt {
        Some(wt) => Spawn {
            program: wt.to_string(),
            args: vec![
                "-d".into(), folder.into(), shell.into(),
                "-NoExit".into(), "-NoLogo".into(), "-Command".into(), wt_escape(&script),
            ],
            env: Vec::new(),
            dir: folder.to_string(),
        },
        None => Spawn {
            program: shell.to_string(),
            args: vec!["-NoExit".into(), "-NoLogo".into(), "-Command".into(), script],
            env: Vec::new(),
            dir: folder.to_string(),
        },
    }
}

// ── Drop ──────────────────────────────────────────────────────────────────────

/// What a file dropped on a session types into its prompt: the paths as a
/// terminal writes them when files are dragged onto it, then a space. Claude
/// Code takes them as files, an image path as the image. Windows Terminal
/// puts a path with a space in double quotes (a backslash is a separator
/// there); a Linux terminal, like the Mac's, puts a backslash before spaces
/// and shell characters.
pub fn drop_text(paths: &[String], windows: bool) -> String {
    let escaped: Vec<String> = paths
        .iter()
        .map(|path| {
            if windows {
                if path.chars().any(|c| c == ' ' || "&()[]{}^=;!'+,`~".contains(c)) {
                    format!("\"{path}\"")
                } else {
                    path.clone()
                }
            } else {
                let special = " ()'\"\\&;|<>*?[]{}$`!#~";
                path.chars().map(|c| if special.contains(c) { format!("\\{c}") } else { c.to_string() }).collect()
            }
        })
        .collect();
    format!("{} ", escaped.join(" "))
}

// ── Commands ──────────────────────────────────────────────────────────────────

fn start(spawn: &Spawn, new_console: bool) -> std::io::Result<()> {
    let mut cmd = Command::new(&spawn.program);
    cmd.args(&spawn.args).current_dir(&spawn.dir);
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        // PowerShell on its own needs a console window to show in; wt.exe
        // opens its own window and must not flash one.
        const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
        if new_console {
            cmd.creation_flags(CREATE_NEW_CONSOLE);
        } else {
            platform::no_console(&mut cmd);
        }
    }
    #[cfg(not(windows))]
    {
        let _ = new_console;
        // Coucou's own GDK settings stay out of the terminal (platform/linux.rs).
        platform::no_console(&mut cmd);
    }
    for (k, v) in &spawn.env {
        cmd.env(k, v);
    }
    cmd.spawn().map(|_| ())
}

#[cfg(target_os = "linux")]
fn launch_here(folder: &str, prompt: &str) -> Result<String, String> {
    let shell = std::env::var("SHELL").ok().filter(|s| Path::new(s).is_absolute()).unwrap_or_else(|| "/bin/bash".into());
    let env_terminal = std::env::var("TERMINAL").ok();
    for candidate in linux_candidates(env_terminal.as_deref()) {
        let Some(path) = (if Path::new(&candidate).is_absolute() {
            Some(std::path::PathBuf::from(&candidate)).filter(|p| p.is_file())
        } else {
            platform::find_on_path(&candidate)
        }) else {
            continue;
        };
        let spawn = linux_spawn(&path.to_string_lossy(), &shell, folder, prompt);
        match start(&spawn, false) {
            Ok(()) => return Ok(candidate),
            Err(err) => crate::log::line(format!("launch: {candidate} didn't start: {err}")),
        }
    }
    Err("no terminal found".into())
}

#[cfg(windows)]
fn launch_here(folder: &str, prompt: &str) -> Result<String, String> {
    let prompt = windows_prompt(prompt);
    let file = if prompt.is_empty() {
        None
    } else {
        let mut bytes = [0u8; 8];
        ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes).map_err(|_| "no randomness")?;
        let name = format!("coucou-prompt-{}.txt", bytes.iter().map(|b| format!("{b:02x}")).collect::<String>());
        let path = std::env::temp_dir().join(name);
        std::fs::write(&path, prompt.as_bytes()).map_err(|e| e.to_string())?;
        // PowerShell deletes it once read; this catches a terminal that never started.
        let stale = path.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(120));
            let _ = std::fs::remove_file(stale);
        });
        Some(path.to_string_lossy().to_string())
    };
    // By name, found on %PATH% by the terminal: a full path would carry the
    // spaces of "Program Files" through wt.exe's re-joined command line.
    let shell = if platform::find_on_path("pwsh").is_some() { "pwsh.exe" } else { "powershell.exe" };
    if let Some(wt) = platform::windows_terminal() {
        let spawn = windows_spawn(Some(&wt.to_string_lossy()), shell, folder, file.as_deref());
        match start(&spawn, false) {
            Ok(()) => return Ok("Windows Terminal".into()),
            Err(err) => crate::log::line(format!("launch: Windows Terminal didn't start: {err}")),
        }
    }
    let spawn = windows_spawn(None, shell, folder, file.as_deref());
    start(&spawn, true).map(|()| "PowerShell".into()).map_err(|e| e.to_string())
}

/// Opens the user's terminal in `folder` with Claude Code and the prompt.
/// False when the folder isn't one or no terminal could be started.
#[tauri::command]
pub fn launch_session(folder: String, prompt: String) -> bool {
    if !valid_folder(&folder) {
        return false;
    }
    let name = session_window::folder_name(&folder).to_string();
    match launch_here(&folder, &prompt) {
        Ok(terminal) => {
            crate::log::line(format!("launch: Claude Code in {name} with {terminal}"));
            true
        }
        Err(err) => {
            crate::log::line(format!("launch: couldn't open a terminal in {name}: {err}"));
            false
        }
    }
}

/// "Choose a folder…": the system's folder picker, `start` open in it.
#[tauri::command]
pub async fn pick_folder(app: tauri::AppHandle, start: Option<String>) -> Option<String> {
    let title = crate::i18n::t("Choose a folder…");
    let start = start.filter(|s| valid_folder(s));
    tauri::async_runtime::spawn_blocking(move || platform::pick_folder(&app, start.as_deref(), &title))
        .await
        .ok()
        .flatten()
        .filter(|p| valid_folder(p))
}

/// Brings the session's window forward and pastes the paths into it.
/// "pasted"; "copied" when they could only be put on the clipboard (the
/// window wasn't found, or the keystroke was refused); "failed".
#[tauri::command]
pub async fn drop_into_session(session_id: String, path: Option<String>, paths: Vec<String>) -> String {
    let paths: Vec<String> = paths.into_iter().filter(|p| Path::new(p).is_absolute()).take(32).collect();
    if paths.is_empty() {
        return "failed".into();
    }
    let text = drop_text(&paths, cfg!(windows));
    let folder = path.as_deref().map(session_window::folder_name).unwrap_or_default().to_string();
    tauri::async_runtime::spawn_blocking(move || {
        let in_herdr = herdr::focus(&session_id);
        let focused = session_window::lookup(&session_id)
            .is_some_and(|owners| platform::focus_session_window(&owners, &folder))
            || in_herdr;
        crate::log::line(format!("drop: {} file(s) into a session, window found: {focused}", paths.len()));
        if !focused {
            return if flow::paste::copy(&text) { "copied" } else { "failed" }.to_string();
        }
        // The window takes a moment to come forward and take the keyboard.
        std::thread::sleep(Duration::from_millis(250));
        // A Linux terminal pastes with Ctrl+Shift+V (VS Code's terminal too);
        // Windows Terminal, VS Code and the console with Ctrl+V.
        match flow::paste::paste(&text, cfg!(target_os = "linux")) {
            flow::paste::Outcome::Pasted => "pasted",
            flow::paste::Outcome::Copied => "copied",
            flow::paste::Outcome::Failed => "failed",
        }
        .to_string()
    })
    .await
    .unwrap_or_else(|_| "failed".into())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn the_prompt_is_trimmed_onto_one_line() {
        assert_eq!(clean_prompt("  fix the bug \n\r\n and test it  "), "fix the bug and test it");
        assert_eq!(clean_prompt("   "), "");
    }

    #[test]
    fn only_an_existing_absolute_folder_is_a_project() {
        let dir = std::env::temp_dir();
        assert!(valid_folder(&dir.to_string_lossy()));
        assert!(!valid_folder(""));
        assert!(!valid_folder("relative/path"));
        assert!(!valid_folder("/no/such/folder/coucou-xyz"));
        let file = dir.join("coucou-launch-test-file.txt");
        std::fs::write(&file, "x").unwrap();
        assert!(!valid_folder(&file.to_string_lossy()), "a file is not a folder");
        let _ = std::fs::remove_file(file);
    }

    #[test]
    fn sh_quote_leaves_plain_paths_and_quotes_the_rest() {
        assert_eq!(sh_quote("/usr/bin/zsh"), "/usr/bin/zsh");
        assert_eq!(sh_quote("it's"), r"'it'\''s'");
        assert_eq!(sh_quote("/opt/my shell/fish"), "'/opt/my shell/fish'");
        assert_eq!(sh_quote(""), "''");
    }

    #[test]
    fn the_shell_runs_claude_with_the_variable_never_the_prompt() {
        assert_eq!(
            shell_command("/bin/zsh", true),
            s(&["/bin/zsh", "-lic", r#"claude "$COUCOU_PROMPT"; exec /bin/zsh -l"#])
        );
        assert_eq!(shell_command("/usr/bin/fish", false), s(&["/usr/bin/fish", "-lic", "claude; exec /usr/bin/fish -l"]));
    }

    #[test]
    fn terminal_is_tried_first_then_the_known_ones_without_duplicates() {
        let list = linux_candidates(Some("kitty -1"));
        assert_eq!(list[0], "kitty");
        assert_eq!(list.iter().filter(|t| *t == "kitty").count(), 1);
        assert_eq!(list[1], "x-terminal-emulator");
        assert_eq!(linux_candidates(None), s(LINUX_TERMINALS));
        assert_eq!(linux_candidates(Some("  ")), s(LINUX_TERMINALS));
    }

    #[test]
    fn each_terminal_gets_the_folder_and_the_command_its_way() {
        let cmd = s(&["/bin/bash", "-lic", "claude; exec /bin/bash -l"]);
        let dir = "/home/me/My Project";
        let with = |t: &str| linux_terminal_args(t, dir, &cmd);
        let tail = |args: Vec<String>, head: &[&str]| {
            let mut want = s(head);
            want.extend(cmd.iter().cloned());
            assert_eq!(args, want);
        };
        tail(with("/usr/bin/gnome-terminal"), &["--working-directory=/home/me/My Project", "--"]);
        tail(with("ptyxis"), &["--new-window", "-d", dir, "--"]);
        tail(with("konsole"), &["--separate", "--workdir", dir, "-e"]);
        tail(with("kitty"), &["--directory", dir]);
        tail(with("alacritty"), &["--working-directory", dir, "-e"]);
        tail(with("wezterm"), &["start", "--always-new-process", "--cwd", dir, "--"]);
        tail(with("foot"), &["--working-directory=/home/me/My Project"]);
        tail(with("x-terminal-emulator"), &["-e"]);
        tail(with("/opt/st/st"), &["-e"]);
    }

    #[test]
    fn linux_hands_the_prompt_in_the_environment_only() {
        let nasty = r#"fix the "login" bug; rm -rf / && echo $HOME `id` $(id)"#;
        let spawn = linux_spawn("/usr/bin/kitty", "/bin/zsh", "/home/me/p", nasty);
        assert_eq!(spawn.program, "/usr/bin/kitty");
        assert_eq!(spawn.dir, "/home/me/p");
        assert_eq!(spawn.env, vec![("COUCOU_PROMPT".to_string(), nasty.to_string())]);
        assert!(spawn.args.iter().all(|a| !a.contains("login") && !a.contains("rm -rf")), "{:?}", spawn.args);
        assert_eq!(spawn.args.last().unwrap(), r#"claude "$COUCOU_PROMPT"; exec /bin/zsh -l"#);

        let empty = linux_spawn("kitty", "/bin/zsh", "/home/me/p", "  \n ");
        assert!(empty.env.is_empty());
        assert_eq!(empty.args.last().unwrap(), "claude; exec /bin/zsh -l");
    }

    #[test]
    fn powershell_quotes_and_the_windows_prompt() {
        assert_eq!(ps_quote(r"C:\Users\O'Brien\AppData\Local\Temp\p.txt"), r"'C:\Users\O''Brien\AppData\Local\Temp\p.txt'");
        assert_eq!(windows_prompt(r#"fix the "login" bug & exit"#), "fix the 'login' bug & exit");
        assert_eq!(wt_escape("a; b; c"), r"a\; b\; c");
    }

    #[test]
    fn powershell_reads_the_prompt_from_our_file() {
        assert_eq!(powershell_script(None), "& (Get-Command claude -CommandType Application -TotalCount 1)");
        let script = powershell_script(Some(r"C:\Temp\coucou-prompt-ab.txt"));
        assert_eq!(
            script,
            "$env:COUCOU_PROMPT = Get-Content -LiteralPath 'C:\\Temp\\coucou-prompt-ab.txt' -Raw -Encoding UTF8; \
             Remove-Item -LiteralPath 'C:\\Temp\\coucou-prompt-ab.txt'; \
             & (Get-Command claude -CommandType Application -TotalCount 1) $env:COUCOU_PROMPT"
        );
        // wt.exe re-joins its arguments in quotes: none may be inside.
        assert!(!script.contains('"'));
    }

    #[test]
    fn windows_terminal_or_a_powershell_console() {
        let file = Some(r"C:\Temp\p.txt");
        let wt = windows_spawn(Some(r"C:\Users\me\AppData\Local\Microsoft\WindowsApps\wt.exe"), "pwsh.exe", r"C:\code\my app", file);
        assert_eq!(wt.args[..3], s(&["-d", r"C:\code\my app", "pwsh.exe"]));
        assert_eq!(wt.args[3..6], s(&["-NoExit", "-NoLogo", "-Command"]));
        let script = &wt.args[6];
        assert!(script.contains(r"\;") && !script.replace(r"\;", "").contains(';'), "every semicolon escaped for wt: {script}");
        assert_eq!(script.replace(r"\;", ";"), powershell_script(file));
        assert_eq!(wt.dir, r"C:\code\my app");
        assert!(wt.env.is_empty());

        let console = windows_spawn(None, "powershell.exe", r"C:\code", None);
        assert_eq!(console.program, "powershell.exe");
        assert_eq!(console.args, s(&["-NoExit", "-NoLogo", "-Command", &powershell_script(None)]));
        assert_eq!(console.dir, r"C:\code");
    }

    #[test]
    fn dropped_paths_are_written_as_a_terminal_drag_writes_them() {
        assert_eq!(
            drop_text(&s(&["/tmp/Screenshot 2026-11-06 at 14.03.22.png"]), false),
            r"/tmp/Screenshot\ 2026-11-06\ at\ 14.03.22.png "
        );
        assert_eq!(drop_text(&s(&["/a/b.txt", "/c/it's (1).md"]), false), r"/a/b.txt /c/it\'s\ \(1\).md ");
        assert_eq!(drop_text(&s(&[r"C:\Users\me\a.png"]), true), r"C:\Users\me\a.png ");
        assert_eq!(
            drop_text(&s(&[r"C:\Users\me\My Shots\a.png", r"D:\x.txt"]), true),
            r#""C:\Users\me\My Shots\a.png" D:\x.txt "#
        );
    }
}
