// `coucou.exe --setup-agents [--dry-run]` and `coucou.exe --remove-agents
// [--dry-run]`: the one-step agent setup without the island.
//
// Handled before Tauri is built, so neither the single-instance plugin nor any
// window ever starts: running this next to an open Coucou is fine. coucou.exe
// is a GUI-subsystem program, so the output goes to the terminal it was started
// from (when there is one) and always to %LOCALAPPDATA%\Coucou\setup-report.txt.

use std::io::Write;

use crate::agent_hooks::Profile;
use crate::{hooks, setup};

#[derive(Debug, PartialEq, Eq)]
pub enum Command {
    Setup { dry_run: bool },
    Remove { dry_run: bool },
    Usage(String),
}

/// `None` = no agent-setup flag: start the app as usual.
pub fn parse<I, S>(args: I) -> Option<Command>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let args: Vec<String> = args.into_iter().skip(1).map(|a| a.as_ref().to_string()).collect();
    let setup = args.iter().any(|a| a.eq_ignore_ascii_case("--setup-agents"));
    let remove = args.iter().any(|a| a.eq_ignore_ascii_case("--remove-agents"));
    if !setup && !remove {
        return None;
    }
    if setup && remove {
        return Some(Command::Usage("Use either --setup-agents or --remove-agents, not both.".into()));
    }
    let dry_run = args.iter().any(|a| a.eq_ignore_ascii_case("--dry-run"));
    let known = ["--setup-agents", "--remove-agents", "--dry-run"];
    if let Some(other) = args.iter().find(|a| !known.iter().any(|k| a.eq_ignore_ascii_case(k))) {
        return Some(Command::Usage(format!("Unknown option: {other}")));
    }
    Some(if setup { Command::Setup { dry_run } } else { Command::Remove { dry_run } })
}

const USAGE: &str = "Usage:\r\n  coucou.exe --setup-agents [--dry-run]   install Coucou's hooks for every agent found\r\n  coucou.exe --remove-agents [--dry-run]  remove Coucou's hooks from every agent\r\n";

/// Runs the command and returns the process exit code.
pub fn run(command: Command) -> i32 {
    let mut out = Console::attach();
    let profile = Profile::from_env();
    let report = match command {
        Command::Usage(problem) => {
            out.print(&format!("{problem}\r\n\r\n{USAGE}"));
            return 1;
        }
        Command::Setup { dry_run } => {
            setup::setup_all_detected(&profile, &hooks::relay_candidates(None), dry_run)
        }
        Command::Remove { dry_run } => setup::remove_all(&profile, dry_run),
    };
    let mut text = setup::report_text(&report, &setup::local_stamp());
    match setup::write_report(&profile, &text) {
        Ok(path) => text.push_str(&format!("Report saved to {}\r\n", path.display())),
        Err(err) => {
            text.push_str(&format!("Could not save the report: {err}\r\n"));
        }
    }
    if !report.dry_run {
        crate::log::line(format!("--{}-agents: {}", report.action, if report.ok { "ok" } else { "errors" }));
    }
    out.print(&text);
    report.exit_code()
}

/// Where the text goes: inherited stdout when there is one (a pipe or a
/// redirect), else the console of the parent terminal, else nowhere.
struct Console(Option<Box<dyn Write>>);

impl Console {
    fn attach() -> Self {
        use windows::Win32::System::Console::{AttachConsole, GetStdHandle, ATTACH_PARENT_PROCESS, STD_OUTPUT_HANDLE};
        let inherited = unsafe { GetStdHandle(STD_OUTPUT_HANDLE) }
            .map(|h| !h.is_invalid() && !h.0.is_null())
            .unwrap_or(false);
        if inherited {
            return Self(Some(Box::new(std::io::stdout())));
        }
        if unsafe { AttachConsole(ATTACH_PARENT_PROCESS) }.is_ok() {
            if let Ok(con) = std::fs::OpenOptions::new().write(true).open("CONOUT$") {
                return Self(Some(Box::new(con)));
            }
        }
        Self(None)
    }

    fn print(&mut self, text: &str) {
        if let Some(out) = self.0.as_mut() {
            // The shell already printed its prompt (it does not wait for GUI
            // programs), so start on a fresh line.
            let _ = out.write_all(format!("\r\n{text}").as_bytes());
            let _ = out.flush();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(args: &[&str]) -> Option<Command> {
        parse(std::iter::once("coucou.exe").chain(args.iter().copied()))
    }

    #[test]
    fn arguments_are_parsed_strictly() {
        assert_eq!(p(&[]), None);
        assert_eq!(p(&["--autostart"]), None, "other launches start the app");
        assert_eq!(p(&["--setup-agents"]), Some(Command::Setup { dry_run: false }));
        assert_eq!(p(&["--setup-agents", "--dry-run"]), Some(Command::Setup { dry_run: true }));
        assert_eq!(p(&["--dry-run", "--SETUP-AGENTS"]), Some(Command::Setup { dry_run: true }));
        assert_eq!(p(&["--remove-agents"]), Some(Command::Remove { dry_run: false }));
        assert_eq!(p(&["--remove-agents", "--dry-run"]), Some(Command::Remove { dry_run: true }));
        assert!(matches!(p(&["--setup-agents", "--remove-agents"]), Some(Command::Usage(_))));
        assert!(matches!(p(&["--setup-agents", "--force"]), Some(Command::Usage(m)) if m.contains("--force")));
        assert_eq!(p(&["--dry-run"]), None, "--dry-run alone does nothing special");
    }

    #[test]
    fn usage_errors_exit_with_one() {
        assert_eq!(run(Command::Usage("bad".into())), 1);
    }
}
