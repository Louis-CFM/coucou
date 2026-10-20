// A calendar published as an ICS link: Outlook on the web's "Publish a calendar", iCloud's "Public
// calendar", Google's secret address, any other. Microsoft Graph would be the richer way into
// Outlook, but it needs the organisation to approve an app, and a managed tenant may refuse; a
// published link needs nobody's approval. The link is a secret (whoever holds it reads the
// calendar), so it lives in the keystore and never appears in a log or an error.

use std::time::Duration;

use reqwest::redirect::Policy;

use crate::i18n::{t, tf};

const TIMEOUT: Duration = Duration::from_secs(20);
/// A published calendar is a few hundred KB; this only stops a link that points at something else.
const MAX_BYTES: usize = 12 * 1024 * 1024;

/// `webcal://` is an https link with another name; anything but https is refused, since the link
/// carries a secret and must not cross the network in the clear.
pub fn normalise(link: &str) -> Result<String, String> {
    let link = link.trim();
    let link = match link.strip_prefix("webcal://") {
        Some(rest) => format!("https://{rest}"),
        None => link.to_string(),
    };
    if !link.starts_with("https://") {
        return Err(t("The link must start with https:// (or webcal://)"));
    }
    match reqwest::Url::parse(&link) {
        Ok(url) if url.host_str().is_some() => Ok(link),
        _ => Err(t("That link did not return a calendar")),
    }
}

/// The ICS text behind the link.
pub async fn fetch(link: &str) -> Result<String, String> {
    let link = normalise(link)?;
    let client = reqwest::Client::builder()
        .timeout(TIMEOUT)
        // Follow redirects, but never to anything that is not https.
        .redirect(Policy::custom(|attempt| {
            if attempt.url().scheme() != "https" {
                attempt.stop()
            } else if attempt.previous().len() > 5 {
                attempt.error("too many redirects")
            } else {
                attempt.follow()
            }
        }))
        .build()
        .map_err(|_| t("Could not reach the calendar"))?;
    // The reqwest error is dropped, not shown: it carries the address, and this address is a secret.
    let mut response = client
        .get(&link)
        .header("Accept", "text/calendar, */*;q=0.5")
        .send()
        .await
        .map_err(|_| t("Could not reach the calendar"))?;
    match response.status().as_u16() {
        200 => {}
        401 | 403 | 404 | 410 => {
            return Err(t("The link no longer works: publish the calendar again"))
        }
        code => return Err(tf("The calendar answered {code}", &[("code", &code.to_string())])),
    }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| t("Could not reach the calendar"))? {
        body.extend_from_slice(&chunk);
        if body.len() > MAX_BYTES {
            return Err(t("That link did not return a calendar"));
        }
    }
    Ok(String::from_utf8_lossy(&body).into_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn webcal_is_https_and_http_is_refused() {
        assert_eq!(normalise("webcal://outlook.office365.com/x.ics").unwrap(), "https://outlook.office365.com/x.ics");
        assert_eq!(normalise("  https://outlook.live.com/x.ics ").unwrap(), "https://outlook.live.com/x.ics");
        assert!(normalise("http://outlook.live.com/x.ics").is_err());
        assert!(normalise("file:///etc/passwd").is_err());
        assert!(normalise("javascript:alert(1)").is_err());
        assert!(normalise("https://").is_err());
        assert!(normalise("").is_err());
    }
}
