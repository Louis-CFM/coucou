// The lines around an edit, for the session view's editor pane.
//
// The hook only carries the edited text itself. To show it in place — line
// numbers and a few lines of context, like an editor — the island asks for the
// file's own lines. Only a regular file inside the session's folder, up to 2 MB,
// is ever read: the path arrives in a hook payload and is not trusted.

use std::path::Path;

use serde::Serialize;

const MAX_FILE: u64 = 2 * 1024 * 1024;
const MAX_LINE: usize = 200;

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
    if find.is_empty() {
        return None;
    }
    let root = Path::new(cwd).canonicalize().ok()?;
    let file = Path::new(path).canonicalize().ok()?;
    let meta = std::fs::metadata(&file).ok()?;
    if !file.starts_with(&root) || !meta.is_file() || meta.len() > MAX_FILE {
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

    #[test]
    fn finds_the_block_with_context_and_refuses_everything_else() {
        let dir = std::env::temp_dir().join(format!("coucou-snippet-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("a.ts");
        std::fs::write(&file, "l1\nl2\nl3\nconst X = 2\nreturn X\nl6\nl7\nl8\n").unwrap();
        let (cwd, path) = (dir.to_str().unwrap(), file.to_str().unwrap());

        let s = around(cwd, path, "const X = 2\nreturn X", 2).unwrap();
        assert_eq!((s.start, s.at, s.len), (2, 2, 2));
        assert_eq!(s.lines, ["l2", "l3", "const X = 2", "return X", "l6", "l7"]);

        assert!(around(cwd, path, "not in the file", 2).is_none());
        assert!(around(cwd, path, "", 2).is_none());
        // Outside the session folder: never read.
        assert!(around(dir.join("sub").to_str().unwrap(), path, "l1", 2).is_none());
        let other = std::env::temp_dir().join("coucou-snippet-other.txt");
        std::fs::write(&other, "secret").unwrap();
        assert!(around(cwd, other.to_str().unwrap(), "secret", 2).is_none());

        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_file(other);
    }
}
