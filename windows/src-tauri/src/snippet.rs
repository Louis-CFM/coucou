// The lines around an edit, for the island's code view.
//
// The hook only carries the edited text itself. To show it in place, with line
// numbers and a few lines of context, the island asks for the file's own lines.
// The path comes from a hook payload and is not trusted: only a regular file
// inside the session's folder, up to 2 MB, is ever read.

use std::path::Path;

use serde::Serialize;

const MAX_FILE: u64 = 2 * 1024 * 1024;
const MAX_LINE: usize = 200;
pub const MAX_CONTEXT: usize = 6;

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Snippet {
    /// Line number (1-based) of `lines[0]`.
    pub start: usize,
    pub lines: Vec<String>,
    /// Where the edited block begins in `lines`, and how many lines it spans.
    pub at: usize,
    pub len: usize,
}

/// `find` is the text the edit wrote; `context` lines are kept on each side.
pub fn around(cwd: &str, path: &str, find: &str, context: usize) -> Option<Snippet> {
    if find.is_empty() || cwd.is_empty() {
        return None;
    }
    let context = context.min(MAX_CONTEXT);
    let root = Path::new(cwd).canonicalize().ok()?;
    // A relative path is the session's, not this process's.
    let file = root.join(path).canonicalize().ok()?;
    if !file.starts_with(&root) {
        return None;
    }
    let meta = std::fs::metadata(&file).ok()?;
    if !meta.is_file() || meta.len() > MAX_FILE {
        return None;
    }
    let text = std::fs::read_to_string(&file).ok()?;
    let first = text[..text.find(find)?].matches('\n').count();
    let len = find.trim_end_matches('\n').matches('\n').count() + 1;

    let all: Vec<&str> = text.lines().collect();
    let from = first.saturating_sub(context);
    let to = (first + len + context).min(all.len());
    Some(Snippet {
        start: from + 1,
        lines: all[from..to].iter().map(|l| l.chars().take(MAX_LINE).collect()).collect(),
        at: first - from,
        len,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn temp(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("coucou-snippet-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn finds_the_block_with_its_context() {
        let dir = temp("find");
        let file = dir.join("a.ts");
        std::fs::write(&file, "l1\nl2\nl3\nconst X = 2\nreturn X\nl6\nl7\nl8\n").unwrap();
        let (cwd, path) = (dir.to_str().unwrap(), file.to_str().unwrap());

        let s = around(cwd, path, "const X = 2\nreturn X", 2).unwrap();
        assert_eq!((s.start, s.at, s.len), (2, 2, 2));
        assert_eq!(s.lines, ["l2", "l3", "const X = 2", "return X", "l6", "l7"]);

        // At the top of the file, and a relative path read from the session's folder.
        let s = around(cwd, "a.ts", "l1", 3).unwrap();
        assert_eq!((s.start, s.at, s.len), (1, 0, 1));
        assert_eq!(s.lines.len(), 4);

        assert!(around(cwd, path, "not in the file", 2).is_none());
        assert!(around(cwd, path, "", 2).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn context_and_line_width_are_capped() {
        let dir = temp("caps");
        let file = dir.join("long.rs");
        let body: String = (1..=30).map(|i| format!("line {i}\n")).collect();
        std::fs::write(&file, format!("{body}{}\n{body}", "x".repeat(500))).unwrap();
        let s = around(dir.to_str().unwrap(), file.to_str().unwrap(), "xxx", 50).unwrap();
        assert_eq!(s.lines.len(), 2 * MAX_CONTEXT + 1);
        assert_eq!(s.lines[s.at].chars().count(), MAX_LINE);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn nothing_outside_the_session_folder_is_read() {
        let dir = temp("inside");
        let other = temp("outside");
        let secret = other.join("notes.txt");
        std::fs::write(&secret, "token=abc").unwrap();
        let cwd = dir.to_str().unwrap();

        assert!(around(cwd, secret.to_str().unwrap(), "token", 2).is_none());
        assert!(around(cwd, "../coucou-snippet-outside-x/notes.txt", "token", 2).is_none());
        let up = format!("../{}/notes.txt", other.file_name().unwrap().to_str().unwrap());
        assert!(around(cwd, &up, "token", 2).is_none());
        // A folder is not a file, and no session folder means no read.
        assert!(around(cwd, cwd, "x", 2).is_none());
        assert!(around("", secret.to_str().unwrap(), "token", 2).is_none());

        #[cfg(unix)]
        {
            let link = dir.join("link.txt");
            std::os::unix::fs::symlink(&secret, &link).unwrap();
            assert!(around(cwd, link.to_str().unwrap(), "token", 2).is_none());
        }

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&other);
    }

    #[test]
    fn a_file_over_the_size_limit_is_not_read() {
        let dir = temp("big");
        let file = dir.join("big.txt");
        std::fs::write(&file, "a\n".repeat((MAX_FILE as usize) / 2 + 1)).unwrap();
        assert!(around(dir.to_str().unwrap(), file.to_str().unwrap(), "a", 1).is_none());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
