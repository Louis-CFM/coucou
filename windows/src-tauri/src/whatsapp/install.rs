// "Install WhatsApp": one click instead of GitHub, a zip and a command line (port of
// WhatsAppGOWAInstaller.swift). Downloads GOWA's own latest build for this system from its GitHub
// releases, checks its SHA-256 against the one GOWA publishes, puts the binary in Coucou's GOWA
// folder (next to the WhatsApp session it keeps) and turns on "Start GOWA automatically".
// The only network call is to GitHub, after the click; no message ever goes there.

use std::io::Write;
use std::time::Duration;

use serde::Serialize;

use super::archive;
use super::gateway::release::{self, Asset};
use super::process;

/// GOWA's zips are about 15 MB; anything far bigger is not one.
const MAX_ZIP: u64 = 150 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "step", rename_all = "camelCase")]
pub enum Step {
    Idle,
    Checking,
    Downloading { megabytes: u64 },
    Verifying,
    Installing,
    Done { version: String },
    /// `reason`: noBuild | noChecksum | downloadFailed | badChecksum | unzipFailed.
    Failed { reason: String },
}

impl Step {
    pub fn busy(&self) -> bool {
        matches!(self, Step::Checking | Step::Downloading { .. } | Step::Verifying | Step::Installing)
    }
}

fn fail(reason: &str) -> String {
    reason.to_string()
}

/// GitHub only: no cookie, a bare user agent, redirects followed only to GitHub over https.
fn github_client(timeout: Duration) -> Result<reqwest::Client, String> {
    let policy = reqwest::redirect::Policy::custom(|attempt| {
        if attempt.previous().len() >= 5 {
            attempt.error("too many redirects")
        } else if attempt.url().scheme() == "https" && crate::update::allowed_host(attempt.url().host_str()) {
            attempt.follow()
        } else {
            attempt.stop()
        }
    });
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(timeout)
        .user_agent("Coucou")
        .redirect(policy)
        .build()
        .map_err(|_| fail("downloadFailed"))
}

async fn get(client: &reqwest::Client, url: &str, accept: &str) -> Result<reqwest::Response, String> {
    if !crate::update::allowed_url(url) {
        return Err(fail("downloadFailed"));
    }
    let response = client.get(url).header("Accept", accept).send().await.map_err(|_| fail("downloadFailed"))?;
    if response.status().as_u16() != 200 || response.url().scheme() != "https" || !crate::update::allowed_host(response.url().host_str()) {
        return Err(fail("downloadFailed"));
    }
    Ok(response)
}

/// SHA-256 of `data`, lowercase hex.
pub fn sha256(data: &[u8]) -> String {
    super::gateway::hex(ring::digest::digest(&ring::digest::SHA256, data).as_ref())
}

/// The zip as GOWA published it: exactly its size and its SHA-256, else nothing.
pub fn verified(zip: Vec<u8>, asset: &Asset, expected: &str) -> Result<Vec<u8>, String> {
    if (asset.size != 0 && zip.len() as u64 != asset.size) || sha256(&zip) != expected {
        return Err(fail("badChecksum"));
    }
    Ok(zip)
}

/// The binary out of the zip, for this system.
pub fn binary_from(zip: &[u8], os: &str, arch: &str) -> Result<Vec<u8>, String> {
    let entries = archive::entries(zip).ok_or_else(|| fail("unzipFailed"))?;
    let names: Vec<String> = entries.iter().map(|e| e.name.clone()).collect();
    let name = release::binary_entry(&names, os, arch).ok_or_else(|| fail("noBuild"))?;
    let entry = entries.iter().find(|e| &e.name == name).ok_or_else(|| fail("noBuild"))?;
    archive::read(zip, entry).ok_or_else(|| fail("unzipFailed"))
}

/// Writes the binary beside its final place, then renames it there (GOWA stopped first, so
/// Windows lets go of the old one).
fn put_in_place(binary: &[u8]) -> Result<(), String> {
    let dir = process::working_dir();
    crate::platform::ensure_private_dir(&dir).map_err(|_| fail("unzipFailed"))?;
    let dest = process::installed_binary();
    let temp = dest.with_extension("download");
    let written = (|| -> std::io::Result<()> {
        let mut f = std::fs::File::create(&temp)?;
        f.write_all(binary)?;
        f.flush()?;
        drop(f);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o755))?;
        }
        process::stop_now();
        let _ = std::fs::remove_file(&dest);
        std::fs::rename(&temp, &dest)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
        return Err(fail("unzipFailed"));
    }
    Ok(())
}

/// The whole install; `progress` hears each step. Returns GOWA's version.
pub async fn run(progress: impl Fn(Step)) -> Result<String, String> {
    let (os, arch) = (release::this_os(), release::this_arch());
    let client = github_client(Duration::from_secs(600))?;

    // 1. Which build: GOWA's latest release, the zip for this system.
    let meta = get(&client, release::LATEST_URL, "application/vnd.github+json").await?;
    let meta = crate::net::read_capped(meta, crate::net::MAX_BODY).await.map_err(|_| fail("downloadFailed"))?;
    let (version, assets) = release::parse(&meta).ok_or_else(|| fail("noBuild"))?;
    let (zip, sums) = release::pick(&assets, os, arch).ok_or_else(|| fail("noBuild"))?;
    let checksums = match sums {
        Some(sums) => {
            let r = get(&client, &sums.url, "application/octet-stream").await?;
            let body = crate::net::read_capped(r, 64 * 1024).await.map_err(|_| fail("downloadFailed"))?;
            Some(String::from_utf8_lossy(&body).into_owned())
        }
        None => None,
    };
    let expected = release::expected_sha256(zip, checksums.as_deref()).ok_or_else(|| fail("noChecksum"))?;
    if zip.size > MAX_ZIP {
        return Err(fail("badChecksum"));
    }

    // 2. Download, kept in memory (never a half-written file on disk).
    progress(Step::Downloading { megabytes: (zip.size / 1_000_000).max(1) });
    let response = get(&client, &zip.url, "application/octet-stream").await?;
    let limit = if zip.size > 0 { zip.size as usize } else { MAX_ZIP as usize };
    let data = crate::net::read_capped(response, limit).await.map_err(|_| fail("downloadFailed"))?;

    // 3. Verify: exactly the file GOWA published.
    progress(Step::Verifying);
    let data = verified(data, zip, &expected)?;

    // 4. Unzip, put the binary in place, make it runnable.
    progress(Step::Installing);
    let binary = binary_from(&data, os, arch)?;
    tauri::async_runtime::spawn_blocking(move || put_in_place(&binary)).await.map_err(|_| fail("unzipFailed"))??;
    Ok(version)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_zip_must_be_the_one_gowa_published() {
        let asset = Asset { name: "whatsapp_9.6.0_linux_amd64.zip".into(), url: "https://github.com/x".into(), size: 3, digest: None };
        let good = sha256(b"abc");
        assert_eq!(good, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
        assert_eq!(verified(b"abc".to_vec(), &asset, &good), Ok(b"abc".to_vec()));
        assert_eq!(verified(b"abd".to_vec(), &asset, &good), Err("badChecksum".into()));
        assert_eq!(verified(b"abcd".to_vec(), &asset, &sha256(b"abcd")), Err("badChecksum".into()), "not the published size");
    }

    #[test]
    fn the_binary_comes_out_of_a_real_zip_only() {
        assert_eq!(binary_from(b"not a zip", "linux", "amd64"), Err("unzipFailed".into()));
        assert!(!Step::Idle.busy() && Step::Verifying.busy() && !Step::Done { version: "1".into() }.busy());
    }
}
