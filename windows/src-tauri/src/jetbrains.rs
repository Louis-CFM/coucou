// The JetBrains IDEs that are open, from the lock files the Claude Code plugin
// writes in ~/.claude/ide, one per IDE window: `<port>.lock` holds the IDE's
// process, its name and the folders of its project. Claude Code started in that
// window's terminal has the port in CLAUDE_CODE_SSE_PORT, which names the file.
//
// Only what places a window is read. The file also holds a token that opens the
// plugin's connection: it is never deserialized, so it is never in memory here.

use serde::Deserialize;
use std::path::{Path, PathBuf};

/// One open IDE window.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OpenProject {
    pub port: u16,
    pub pid: u32,
    pub folders: Vec<PathBuf>,
}

#[derive(Deserialize)]
struct Lock {
    pid: Option<u32>,
    #[serde(rename = "ideName")]
    ide_name: Option<String>,
    #[serde(rename = "workspaceFolders")]
    workspace_folders: Option<Vec<String>>,
}

/// Where the plugin writes its lock files.
pub fn lock_dir() -> PathBuf {
    crate::platform::home_dir().join(".claude").join("ide")
}

/// The open windows of PhpStorm, every instance: a lock file of another IDE, of
/// a process that is gone, or that says nothing usable is left out.
pub fn open_projects(dir: &Path) -> Vec<OpenProject> {
    let Ok(entries) = std::fs::read_dir(dir) else { return Vec::new() };
    let mut out: Vec<OpenProject> = entries
        .flatten()
        .filter_map(|e| read_lock(&e.path()))
        .collect();
    out.sort_by_key(|p| p.port);
    out
}

fn read_lock(path: &Path) -> Option<OpenProject> {
    if path.extension()? != "lock" {
        return None;
    }
    let port: u16 = path.file_stem()?.to_str()?.parse().ok().filter(|p| *p > 0)?;
    // A lock file is small; anything else is not one.
    if std::fs::metadata(path).ok()?.len() > 64 * 1024 {
        return None;
    }
    let lock: Lock = serde_json::from_slice(&std::fs::read(path).ok()?).ok()?;
    let pid = lock.pid.filter(|p| *p > 1)?;
    if !lock.ide_name?.to_lowercase().contains("phpstorm") || !process_alive(pid) {
        return None;
    }
    let folders: Vec<PathBuf> = lock
        .workspace_folders?
        .into_iter()
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .collect();
    (!folders.is_empty()).then_some(OpenProject { port, pid, folders })
}

#[cfg(target_os = "linux")]
fn process_alive(pid: u32) -> bool {
    Path::new(&format!("/proc/{pid}")).exists()
}

#[cfg(not(target_os = "linux"))]
fn process_alive(_pid: u32) -> bool {
    true
}

/// A project window and the folder of it that was matched: its name is what the
/// window's title starts with.
#[derive(Debug, PartialEq, Eq)]
pub struct Match<'a> {
    pub project: &'a OpenProject,
    pub folder: &'a Path,
}

impl Match<'_> {
    pub fn name(&self) -> String {
        self.folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
    }
}

/// The window of the IDE a session is connected to, by the port its Claude Code
/// was given. Of several folders, the one `cwd` is in, else the first.
pub fn for_port<'a>(projects: &'a [OpenProject], port: u16, cwd: Option<&Path>) -> Option<Match<'a>> {
    let project = projects.iter().find(|p| p.port == port)?;
    let folder = cwd
        .and_then(|c| project.folders.iter().find(|f| c.starts_with(f)))
        .unwrap_or(&project.folders[0]);
    Some(Match { project, folder })
}

/// The open project a file belongs to: the one of the session's own window
/// (`prefer`, a port) when it holds the file, else the open project whose folder
/// is the deepest one above it, in any instance. None when no open project
/// holds it.
pub fn for_file<'a>(projects: &'a [OpenProject], file: &Path, prefer: Option<u16>) -> Option<Match<'a>> {
    let holding = |p: &'a OpenProject| {
        p.folders
            .iter()
            .filter(|f| file.starts_with(f))
            .max_by_key(|f| f.components().count())
            .map(|folder| Match { project: p, folder })
    };
    if let Some(own) = prefer.and_then(|port| projects.iter().find(|p| p.port == port)).and_then(holding) {
        return Some(own);
    }
    projects.iter().filter_map(holding).max_by_key(|m| m.folder.components().count())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn project(port: u16, pid: u32, folders: &[&str]) -> OpenProject {
        OpenProject { port, pid, folders: folders.iter().map(PathBuf::from).collect() }
    }

    #[test]
    fn a_session_is_in_the_window_its_port_names_and_the_folder_it_is_in() {
        let all = [project(1, 10, &["/p/meyclub"]), project(2, 10, &["/p/coucou", "/p/shared"])];
        let m = for_port(&all, 2, None).unwrap();
        assert_eq!((m.project.pid, m.name()), (10, "coucou".to_string()));
        // The session drifted into a sub-folder of the second folder.
        let m = for_port(&all, 2, Some(Path::new("/p/shared/src"))).unwrap();
        assert_eq!(m.name(), "shared");
        assert_eq!(for_port(&all, 3, None), None);
    }

    #[test]
    fn a_file_goes_to_the_deepest_open_project_that_holds_it() {
        let all = [project(1, 10, &["/p"]), project(2, 11, &["/p/coucou"]), project(3, 11, &["/p/meyclub"])];
        let file = Path::new("/p/coucou/src/a.php");
        assert_eq!(for_file(&all, file, None).unwrap().project.port, 2);
        // The session's own window wins when it holds the file, even a shallower one.
        assert_eq!(for_file(&all, file, Some(1)).unwrap().project.port, 1);
        // A window that does not hold it does not.
        assert_eq!(for_file(&all, file, Some(3)).unwrap().project.port, 2);
        assert_eq!(for_file(&all, Path::new("/elsewhere/a.php"), Some(1)), None);
        // A folder is not a prefix of a name that merely starts alike.
        assert_eq!(for_file(&all, Path::new("/p/coucou-old/a.php"), None).unwrap().project.port, 1);
    }

    #[test]
    fn lock_files_of_phpstorm_only_and_without_the_token() {
        let dir = std::env::temp_dir().join(format!("coucou-locks-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let me = std::process::id();
        let write = |name: &str, body: String| std::fs::write(dir.join(name), body).unwrap();
        let lock = |pid: u32, ide: &str, folders: &str| {
            format!(r#"{{"pid":{pid},"ideName":"{ide}","workspaceFolders":{folders},"authToken":"secret","transport":"ws"}}"#)
        };
        write("2000.lock", lock(me, "PhpStorm", r#"["/p/coucou"]"#));
        write("1000.lock", lock(me, "PhpStorm", r#"["/p/meyclub", "relative"]"#));
        write("3000.lock", lock(me, "WebStorm", r#"["/p/web"]"#));
        write("4000.lock", lock(u32::MAX - 1, "PhpStorm", r#"["/p/dead"]"#));
        write("5000.lock", lock(me, "PhpStorm", "[]"));
        write("6000.lock", "not json".into());
        write("notaport.lock", lock(me, "PhpStorm", r#"["/p/x"]"#));
        write("7000.txt", lock(me, "PhpStorm", r#"["/p/x"]"#));
        let found = open_projects(&dir);
        let got: Vec<(u16, Vec<String>)> = found
            .iter()
            .map(|p| (p.port, p.folders.iter().map(|f| f.to_string_lossy().into_owned()).collect()))
            .collect();
        assert_eq!(got, vec![(1000, vec!["/p/meyclub".to_string()]), (2000, vec!["/p/coucou".to_string()])]);
        assert!(open_projects(&dir.join("missing")).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
