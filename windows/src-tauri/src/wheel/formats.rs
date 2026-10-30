// What a dropped file is, and what the wheel offers for it: the formats it can
// become (the Convert ring), the tools that work on it (Tools) and what can be
// done with any file (Actions). Ids only: the wheel's page names them.

use std::path::Path;

use serde::Serialize;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Kind {
    Image,
    Video,
    Audio,
    Pdf,
    Document,
    Slides,
    Spreadsheet,
    Subtitle,
    Archive,
    Other,
}

/// The extension, lowercase, without the dot ("jpeg" is "jpg").
pub fn ext(path: &Path) -> String {
    let e = path.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
    match e.as_str() {
        "jpeg" | "jpe" | "jfif" => "jpg".into(),
        "tif" => "tiff".into(),
        _ => e,
    }
}

pub fn kind_of(path: &Path) -> Kind {
    match ext(path).as_str() {
        "jpg" | "png" | "webp" | "tiff" | "bmp" | "ico" | "gif" | "avif" | "heic" | "heif" => Kind::Image,
        "mp4" | "mov" | "mkv" | "webm" | "avi" | "wmv" | "m4v" | "flv" => Kind::Video,
        "mp3" | "m4a" | "wav" | "flac" | "ogg" | "opus" | "aiff" | "aif" | "wma" | "aac" => Kind::Audio,
        "pdf" => Kind::Pdf,
        "docx" | "doc" | "odt" | "rtf" | "md" | "markdown" | "txt" | "html" | "htm" | "epub" => Kind::Document,
        "pptx" | "ppt" | "odp" => Kind::Slides,
        "xlsx" | "xls" | "ods" | "csv" | "tsv" => Kind::Spreadsheet,
        "srt" | "vtt" => Kind::Subtitle,
        "zip" | "tar" | "gz" | "tgz" => Kind::Archive,
        _ => Kind::Other,
    }
}

/// The image formats Coucou reads and writes itself (wheel/image_ops.rs).
pub const IMAGE_TARGETS: &[&str] = &["jpg", "png", "webp", "tiff", "bmp", "ico", "gif", "pdf"];
/// The images it can read.
pub const IMAGE_INPUTS: &[&str] = &["jpg", "png", "webp", "tiff", "bmp", "ico", "gif"];

/// The image tools: those with an editor open the editor window.
pub const IMAGE_TOOLS: &[&str] = &["compress", "metadata", "crop", "edit", "annotate", "redact", "background"];

/// What videos and sounds become (wheel/media.rs, through FFmpeg).
pub const VIDEO_TARGETS: &[&str] = &["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3"];
pub const AUDIO_TARGETS: &[&str] = &["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"];

/// What can be done with any file or folder.
pub const ACTIONS: &[&str] = &["copy", "copyPath", "move", "terminal", "reveal"];

/// The three rings for a selection: one kind of file, or a mixed one.
#[derive(Debug, Clone, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Rings {
    /// The selection's kind; Other when the files are of different kinds.
    pub kind: Kind,
    pub convert: Vec<String>,
    pub tools: Vec<String>,
    pub actions: Vec<String>,
}

pub fn rings(paths: &[&Path]) -> Rings {
    let kinds: Vec<Kind> = paths.iter().map(|p| kind_of(p)).collect();
    let kind = match kinds.first() {
        Some(k) if kinds.iter().all(|x| x == k) => *k,
        _ => Kind::Other,
    };
    let actions = ACTIONS.iter().map(|s| s.to_string()).collect();
    let readable = |p: &&Path| IMAGE_INPUTS.contains(&ext(p).as_str());
    match kind {
        Kind::Image if paths.iter().all(readable) => {
            // A format they all have already is not offered (the rest of a mixed selection converts).
            let same = paths.first().map(|p| ext(p)).filter(|e| paths.iter().all(|p| ext(p) == *e));
            let convert = IMAGE_TARGETS.iter().filter(|t| same.as_deref() != Some(**t)).map(|s| s.to_string()).collect();
            let mut tools: Vec<String> = if paths.len() == 1 {
                IMAGE_TOOLS.iter().map(|s| s.to_string()).collect()
            } else {
                // Several images: the batch tools only (the editors take one image).
                vec!["compress".into(), "metadata".into()]
            };
            if paths.len() > 1 {
                tools.push("mergePdf".into());
            }
            Rings { kind, convert, tools, actions }
        }
        Kind::Video | Kind::Audio => {
            let targets = if kind == Kind::Video { VIDEO_TARGETS } else { AUDIO_TARGETS };
            let same = paths.first().map(|p| ext(p)).filter(|e| paths.iter().all(|p| ext(p) == *e));
            let convert = targets.iter().filter(|t| same.as_deref() != Some(**t)).map(|s| s.to_string()).collect();
            let mut tools = vec!["compress".to_string()];
            // Trimming needs the editor, for one file.
            if paths.len() == 1 {
                tools.push("trim".into());
            }
            if kind == Kind::Video {
                tools.push("mute".into());
            }
            Rings { kind, convert, tools, actions }
        }
        _ => Rings { kind, convert: Vec::new(), tools: Vec::new(), actions },
    }
}

/// A compressed result that isn't smaller than its original is no use: it is
/// removed. Err("already-small") when none of them came out smaller.
pub fn keep_smaller(pairs: Vec<(std::path::PathBuf, std::path::PathBuf)>) -> Result<Vec<std::path::PathBuf>, String> {
    let size = |p: &Path| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
    let mut kept = Vec::new();
    for (input, output) in pairs {
        if size(&output) > 0 && size(&output) < size(&input) {
            kept.push(output);
        } else {
            let _ = std::fs::remove_file(&output);
        }
    }
    if kept.is_empty() {
        return Err("already-small".into());
    }
    Ok(kept)
}

/// Where a result goes: next to the original, `stem.ext`, or `stem (2).ext` when
/// that name is taken. `suffix` names what was done ("compressed"): `stem (compressed).ext`.
pub fn output_path(input: &Path, suffix: Option<&str>, ext: &str) -> std::path::PathBuf {
    let dir = input.parent().unwrap_or_else(|| Path::new("."));
    let stem = input.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "file".into());
    let base = match suffix {
        Some(s) => format!("{stem} ({s})"),
        None => stem,
    };
    let first = dir.join(format!("{base}.{ext}"));
    if !first.exists() && first != input {
        return first;
    }
    (2..10_000)
        .map(|n| dir.join(format!("{base} ({n}).{ext}")))
        .find(|p| !p.exists())
        .unwrap_or(first)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn p(s: &str) -> PathBuf {
        PathBuf::from(s)
    }

    #[test]
    fn kinds_by_extension() {
        assert_eq!(kind_of(&p("C:/a/Photo.JPEG")), Kind::Image);
        assert_eq!(ext(&p("x.jpeg")), "jpg");
        assert_eq!(kind_of(&p("clip.mov")), Kind::Video);
        assert_eq!(kind_of(&p("song.flac")), Kind::Audio);
        assert_eq!(kind_of(&p("notes.pdf")), Kind::Pdf);
        assert_eq!(kind_of(&p("report.docx")), Kind::Document);
        assert_eq!(kind_of(&p("deck.pptx")), Kind::Slides);
        assert_eq!(kind_of(&p("data.csv")), Kind::Spreadsheet);
        assert_eq!(kind_of(&p("movie.srt")), Kind::Subtitle);
        assert_eq!(kind_of(&p("project.zip")), Kind::Archive);
        assert_eq!(kind_of(&p("setup.exe")), Kind::Other);
    }

    #[test]
    fn an_image_gets_every_format_but_its_own_and_every_tool() {
        let a = p("C:/x/tree.png");
        let r = rings(&[a.as_path()]);
        assert_eq!(r.kind, Kind::Image);
        assert!(!r.convert.contains(&"png".to_string()));
        assert!(r.convert.contains(&"jpg".to_string()) && r.convert.contains(&"pdf".to_string()));
        assert!(r.tools.contains(&"crop".to_string()) && !r.tools.contains(&"mergePdf".to_string()));
        assert_eq!(r.actions.len(), ACTIONS.len());
    }

    #[test]
    fn several_images_can_become_one_pdf_but_have_no_editor() {
        let (a, b) = (p("a.jpg"), p("b.png"));
        let r = rings(&[a.as_path(), b.as_path()]);
        assert!(r.convert.contains(&"png".to_string()), "a mixed selection may still convert to PNG");
        assert!(r.tools.contains(&"mergePdf".to_string()));
        assert!(!r.tools.contains(&"crop".to_string()));
    }

    #[test]
    fn videos_and_sounds_get_their_formats_and_tools() {
        let v = p("C:/x/clip.mov");
        let r = rings(&[v.as_path()]);
        assert_eq!(r.kind, Kind::Video);
        assert!(r.convert.contains(&"mp4".to_string()) && r.convert.contains(&"gif".to_string()) && r.convert.contains(&"mp3".to_string()));
        assert!(!r.convert.contains(&"mov".to_string()));
        assert_eq!(r.tools, vec!["compress", "trim", "mute"]);
        let a = p("song.flac");
        let r = rings(&[a.as_path()]);
        assert!(r.convert.contains(&"mp3".to_string()) && !r.convert.contains(&"flac".to_string()));
        assert_eq!(r.tools, vec!["compress", "trim"]);
        let (x, y) = (p("a.mp3"), p("b.wav"));
        assert_eq!(rings(&[x.as_path(), y.as_path()]).tools, vec!["compress"], "no trim for several");
    }

    #[test]
    fn anything_else_gets_the_actions() {
        let (a, b) = (p("a.jpg"), p("setup.exe"));
        let r = rings(&[a.as_path(), b.as_path()]);
        assert_eq!(r.kind, Kind::Other);
        assert!(r.convert.is_empty() && r.tools.is_empty());
        assert!(!r.actions.is_empty());
    }

    #[test]
    fn a_compressed_file_is_only_kept_when_smaller() {
        let dir = std::env::temp_dir().join(format!("coucou-small-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let (a, a2, b, b2) = (dir.join("a"), dir.join("a2"), dir.join("b"), dir.join("b2"));
        std::fs::write(&a, vec![0; 100]).unwrap();
        std::fs::write(&a2, vec![0; 40]).unwrap();
        std::fs::write(&b, vec![0; 10]).unwrap();
        std::fs::write(&b2, vec![0; 50]).unwrap();
        assert_eq!(keep_smaller(vec![(a, a2.clone()), (b, b2.clone())]).unwrap(), vec![a2]);
        assert!(!b2.exists(), "the bigger one is removed");
        let (c, c2) = (dir.join("c"), dir.join("c2"));
        std::fs::write(&c, vec![0; 10]).unwrap();
        std::fs::write(&c2, vec![0; 10]).unwrap();
        assert_eq!(keep_smaller(vec![(c, c2)]).unwrap_err(), "already-small");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn results_never_overwrite() {
        let dir = std::env::temp_dir().join(format!("coucou-wheel-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let input = dir.join("tree.png");
        std::fs::write(&input, b"x").unwrap();
        let first = output_path(&input, None, "jpg");
        assert_eq!(first.file_name().unwrap(), "tree.jpg");
        std::fs::write(&first, b"x").unwrap();
        assert_eq!(output_path(&input, None, "jpg").file_name().unwrap(), "tree (2).jpg");
        assert_eq!(output_path(&input, Some("compressed"), "png").file_name().unwrap(), "tree (compressed).png");
        assert_ne!(output_path(&input, None, "png"), input, "never the original itself");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
