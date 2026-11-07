// The wheel's video and audio work, through FFmpeg: Coucou's own copy, fetched
// once from gyan.dev's "release essentials" build and checked against the
// SHA-256 it publishes, or one already on this computer. Convert, compress,
// trim, remove the sound; a live percentage while it works.

use std::io::{BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use super::formats::output_path;

const ZIP_URL: &str = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip";
const SHA_URL: &str = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip.sha256";

pub fn dir() -> PathBuf {
    crate::platform::local_dir().join("ffmpeg")
}

fn exe(name: &str) -> String {
    if cfg!(windows) { format!("{name}.exe") } else { name.to_string() }
}

/// FFmpeg's (or ffprobe's) program: Coucou's copy, else one on the PATH.
fn tool(name: &str) -> Option<PathBuf> {
    let own = dir().join(exe(name));
    if own.exists() {
        return Some(own);
    }
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join(exe(name))).find(|p| p.exists())
}

pub fn ready() -> bool {
    tool("ffmpeg").is_some() && tool("ffprobe").is_some()
}

#[cfg(windows)]
fn quiet(cmd: &mut Command) -> &mut Command {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW)
}

#[cfg(not(windows))]
fn quiet(cmd: &mut Command) -> &mut Command {
    cmd
}

// ── Getting FFmpeg ──────────────────────────────────────────────────────────

/// The hex SHA-256 of `data`.
fn sha256_hex(data: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, data).as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

/// Downloads the build, checks it and keeps ffmpeg and ffprobe. `progress` gets 0..=1.
pub async fn install(progress: impl Fn(f64)) -> Result<(), String> {
    let url = reqwest::Url::parse(ZIP_URL).map_err(|e| e.to_string())?;
    let client = crate::net::client(&url, std::time::Duration::from_secs(900))?;
    let expected = client
        .get(SHA_URL)
        .send()
        .await
        .and_then(|r| r.error_for_status())
        .map_err(|e| format!("FFmpeg's checksum: {e}"))?
        .text()
        .await
        .map_err(|e| format!("FFmpeg's checksum: {e}"))?
        .split_whitespace()
        .next()
        .unwrap_or_default()
        .to_lowercase();
    if expected.len() != 64 {
        return Err("FFmpeg's checksum is not readable".into());
    }
    let mut response = client.get(url).send().await.and_then(|r| r.error_for_status()).map_err(|e| format!("FFmpeg: {e}"))?;
    let total = response.content_length().unwrap_or(0) as f64;
    // The package is about 110 MB: anything past 300 MB is not it.
    const LIMIT: usize = 300 * 1024 * 1024;
    let mut data = Vec::with_capacity(total as usize);
    while let Some(chunk) = response.chunk().await.map_err(|e| format!("FFmpeg: {e}"))? {
        data.extend_from_slice(&chunk);
        if data.len() > LIMIT {
            return Err("FFmpeg's download is larger than expected: nothing was kept".into());
        }
        if total > 0.0 {
            progress((data.len() as f64 / total).min(1.0) * 0.95);
        }
    }
    if sha256_hex(&data) != expected {
        return Err("FFmpeg's download does not match its checksum: nothing was kept".into());
    }
    tauri::async_runtime::spawn_blocking(move || unpack(data)).await.map_err(|e| e.to_string())??;
    progress(1.0);
    crate::log::line("wheel: FFmpeg installed".to_string());
    Ok(())
}

/// ffmpeg and ffprobe out of the package, into Coucou's folder.
fn unpack(data: Vec<u8>) -> Result<(), String> {
    let mut archive = zip::ZipArchive::new(std::io::Cursor::new(data)).map_err(|e| e.to_string())?;
    let target = dir();
    std::fs::create_dir_all(&target).map_err(|e| e.to_string())?;
    let mut found = 0;
    for i in 0..archive.len() {
        let mut entry = archive.by_index(i).map_err(|e| e.to_string())?;
        let name = entry.name().replace('\\', "/");
        let Some(file) = ["ffmpeg.exe", "ffprobe.exe"].into_iter().find(|f| name.ends_with(&format!("/bin/{f}"))) else { continue };
        let tmp = target.join(format!("{file}.part"));
        let mut out = std::fs::File::create(&tmp).map_err(|e| e.to_string())?;
        std::io::copy(&mut entry, &mut out).map_err(|e| e.to_string())?;
        out.flush().map_err(|e| e.to_string())?;
        drop(out);
        std::fs::rename(&tmp, target.join(file)).map_err(|e| e.to_string())?;
        found += 1;
    }
    if found < 2 {
        return Err("FFmpeg's package didn't hold ffmpeg and ffprobe".into());
    }
    Ok(())
}

// ── Running it ──────────────────────────────────────────────────────────────

/// The file's length in seconds.
pub fn duration(path: &Path) -> Option<f64> {
    let probe = tool("ffprobe")?;
    let out = quiet(Command::new(probe).args(["-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0"]).arg(path))
        .output()
        .ok()?;
    String::from_utf8_lossy(&out.stdout).trim().parse::<f64>().ok().filter(|d| *d > 0.0)
}

/// Whether the file has a picture (a video stream), not only sound.
pub fn has_video(path: &Path) -> bool {
    let Some(probe) = tool("ffprobe") else { return false };
    quiet(Command::new(probe).args(["-v", "error", "-select_streams", "v", "-show_entries", "stream=codec_type", "-of", "csv=p=0"]).arg(path))
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).contains("video"))
        .unwrap_or(false)
}

/// FFmpeg with `args` on `input` into `output`, reporting how far along it is.
fn ffmpeg(input: &Path, before_input: &[&str], args: &[String], output: &Path, length: Option<f64>, progress: &dyn Fn(f64)) -> Result<(), String> {
    let program = tool("ffmpeg").ok_or("needs-ffmpeg")?;
    let mut cmd = Command::new(program);
    cmd.args(["-hide_banner", "-nostdin", "-y", "-loglevel", "error", "-progress", "pipe:1", "-nostats"]);
    cmd.args(before_input).arg("-i").arg(input).args(args).arg(output);
    let mut child = quiet(&mut cmd).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    let stderr = child.stderr.take();
    let errors = std::thread::spawn(move || {
        let mut s = String::new();
        if let Some(mut e) = stderr {
            let _ = e.read_to_string(&mut s);
        }
        s
    });
    if let Some(stdout) = child.stdout.take() {
        for line in BufReader::new(stdout).lines().map_while(Result::ok) {
            if let (Some(us), Some(len)) = (line.strip_prefix("out_time_us="), length) {
                if let Ok(us) = us.trim().parse::<f64>() {
                    progress((us / 1_000_000.0 / len).clamp(0.0, 0.99));
                }
            }
        }
    }
    let status = child.wait().map_err(|e| e.to_string())?;
    let err = errors.join().unwrap_or_default();
    if !status.success() {
        let _ = std::fs::remove_file(output);
        let last = err.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("FFmpeg failed").trim().to_string();
        return Err(last);
    }
    progress(1.0);
    Ok(())
}

fn s(list: &[&str]) -> Vec<String> {
    list.iter().map(|x| x.to_string()).collect()
}

/// The encoding for a target format.
pub fn args_for(target: &str) -> Vec<String> {
    match target {
        "mp4" | "mov" | "mkv" => {
            let mut a = s(&["-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k"]);
            if target == "mp4" || target == "mov" {
                a.extend(s(&["-movflags", "+faststart"]));
            }
            a
        }
        "webm" => s(&["-c:v", "libvpx-vp9", "-crf", "33", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"]),
        "avi" => s(&["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-q:a", "4"]),
        // A small, sharp GIF: its own palette.
        "gif" => s(&["-vf", "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4", "-loop", "0"]),
        "mp3" => s(&["-vn", "-c:a", "libmp3lame", "-q:a", "2"]),
        "m4a" => s(&["-vn", "-c:a", "aac", "-b:a", "192k"]),
        "wav" => s(&["-vn", "-c:a", "pcm_s16le"]),
        "flac" => s(&["-vn", "-c:a", "flac"]),
        "ogg" => s(&["-vn", "-c:a", "libvorbis", "-q:a", "5"]),
        "opus" => s(&["-vn", "-c:a", "libopus", "-b:a", "128k"]),
        "aiff" => s(&["-vn", "-c:a", "pcm_s16be"]),
        _ => Vec::new(),
    }
}

pub fn convert(paths: &[PathBuf], target: &str, progress: &dyn Fn(f64)) -> Result<Vec<PathBuf>, String> {
    let mut out = Vec::new();
    let n = paths.len() as f64;
    for (i, path) in paths.iter().enumerate() {
        let dest = output_path(path, None, target);
        let each = |p: f64| progress((i as f64 + p) / n);
        ffmpeg(path, &[], &args_for(target), &dest, duration(path), &each)?;
        out.push(dest);
    }
    Ok(out)
}

/// Smaller files. Video: H.264 at the preset's quality, no taller than 1080 or
/// 720 lines; sound: MP3 at the preset's bitrate.
pub fn compress(paths: &[PathBuf], level: &str, progress: &dyn Fn(f64)) -> Result<Vec<PathBuf>, String> {
    let (crf, height, audio) = match level {
        "high" => ("23", None, "192k"),
        "small" => ("32", Some(720), "96k"),
        _ => ("28", Some(1080), "128k"),
    };
    let mut pairs = Vec::new();
    let n = paths.len() as f64;
    for (i, path) in paths.iter().enumerate() {
        let each = |p: f64| progress((i as f64 + p) / n);
        let (args, ext) = if has_video(path) {
            let mut a = s(&["-c:v", "libx264", "-preset", "medium", "-crf", crf, "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "128k", "-movflags", "+faststart"]);
            if let Some(h) = height {
                a.extend(["-vf".to_string(), format!("scale=-2:'min({h},ih)'")]);
            }
            (a, "mp4")
        } else {
            (s(&["-vn", "-c:a", "libmp3lame", "-b:a", audio]), "mp3")
        };
        let dest = output_path(path, Some("compressed"), ext);
        ffmpeg(path, &[], &args, &dest, duration(path), &each)?;
        pairs.push((path.clone(), dest));
    }
    super::formats::keep_smaller(pairs)
}

/// The same video, without its sound (the picture copied as it is).
pub fn mute(paths: &[PathBuf], progress: &dyn Fn(f64)) -> Result<Vec<PathBuf>, String> {
    let mut out = Vec::new();
    for path in paths {
        let ext = super::formats::ext(path);
        let dest = output_path(path, Some("no sound"), &ext);
        ffmpeg(path, &[], &s(&["-c:v", "copy", "-an"]), &dest, duration(path), progress)?;
        out.push(dest);
    }
    Ok(out)
}

/// From `start` to `end` seconds, re-encoded so the cut is exact.
pub fn trim(path: &Path, start: f64, end: f64, progress: &dyn Fn(f64)) -> Result<PathBuf, String> {
    if end <= start {
        return Err("the end comes before the start".into());
    }
    let ext = super::formats::ext(path);
    let dest = output_path(path, Some("trimmed"), &ext);
    let (ss, to) = (format!("{start:.3}"), format!("{end:.3}"));
    ffmpeg(path, &["-ss", &ss, "-to", &to], &[], &dest, Some(end - start), progress)?;
    Ok(dest)
}

/// One frame at `at` seconds, at most `max` px wide, as a JPEG data URL (the trim editor's picture).
pub fn frame(path: &Path, at: f64, max: u32) -> Option<String> {
    let program = tool("ffmpeg")?;
    let out = quiet(
        Command::new(program)
            .args(["-hide_banner", "-nostdin", "-loglevel", "error", "-ss", &format!("{at:.3}"), "-i"])
            .arg(path)
            .args(["-frames:v", "1", "-vf", &format!("scale='min({max},iw)':-2"), "-f", "image2pipe", "-c:v", "mjpeg", "-q:v", "4", "pipe:1"]),
    )
    .output()
    .ok()?;
    (!out.stdout.is_empty()).then(|| format!("data:image/jpeg;base64,{}", crate::claude::base64_for(&out.stdout)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_target_has_its_encoding() {
        for t in ["mp4", "mov", "mkv", "webm", "avi", "gif", "mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff"] {
            assert!(!args_for(t).is_empty(), "{t}");
        }
        assert!(args_for("mp3").contains(&"-vn".to_string()), "sound only");
        assert!(args_for("gif").iter().any(|a| a.contains("palettegen")), "a GIF gets its own palette");
        assert!(args_for("webm").contains(&"libvpx-vp9".to_string()));
    }

    #[test]
    fn checksums_are_lowercase_hex() {
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }
}
