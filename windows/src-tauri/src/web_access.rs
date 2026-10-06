use regex::Regex;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResult {
    pub title: String,
    pub url: String,
    pub snippet: String,
}

fn decode_entities(input: &str) -> String {
    input
        .replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&apos;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
        .replace("&#8211;", "-")
        .replace("&#8212;", "-")
        .replace("&#8217;", "'")
}

pub async fn search(query: &str) -> Result<Vec<SearchResult>, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {e}"))?;

    let response = client
        .post("https://lite.duckduckgo.com/lite/")
        .header(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        .header("Content-Type", "application/x-www-form-urlencoded")
        .body(format!("q={}", urlencoding::encode(query)))
        .send()
        .await
        .map_err(|e| format!("Search request failed: {e}"))?;

    if !response.status().is_success() {
        return Err(format!("Search request returned HTTP status {}", response.status()));
    }

    let html = response
        .text()
        .await
        .map_err(|e| format!("Failed to read search response body: {e}"))?;

    let tag_re = Regex::new(r#"<[^>]+>"#).map_err(|e| e.to_string())?;

    let mut results = Vec::new();
    
    let re = Regex::new(r#"(?is)<a[^>]*href="([^"]+)"[^>]*class=['"]result-link['"][^>]*>(.*?)</a>.*?<td[^>]*class=['"]result-snippet['"][^>]*>(.*?)</td>"#).map_err(|e| e.to_string())?;

    for cap in re.captures_iter(&html) {
        if results.len() >= 5 {
            break;
        }

        let raw_url = &cap[1];
        let raw_title = &cap[2];
        let raw_snippet = &cap[3];

        let clean_title = tag_re.replace_all(raw_title, "").trim().to_string();
        let clean_snippet = tag_re.replace_all(raw_snippet, "").trim().to_string();

        results.push(SearchResult {
            title: decode_entities(&clean_title),
            url: decode_entities(raw_url),
            snippet: decode_entities(&clean_snippet),
        });
    }

    crate::log::line(format!("web search '{query}' returned {} results", results.len()));
    Ok(results)
}

fn clean_html(html: &str) -> String {
    let mut intermediate = html.to_string();
    for tag in &["script", "style", "svg", "nav", "footer", "header"] {
        if let Ok(re) = Regex::new(&format!(r#"(?is)<{tag}[^>]*>.*?</{tag}>"#)) {
            intermediate = re.replace_all(&intermediate, " ").to_string();
        }
    }

    let tags_re = Regex::new(r#"<[^>]+>"#).unwrap();
    let text_no_tags = tags_re.replace_all(&intermediate, " ");

    let decoded = decode_entities(&text_no_tags);

    let ws_re = Regex::new(r#"\s+"#).unwrap();
    let collapsed = ws_re.replace_all(&decoded, " ").trim().to_string();

    if collapsed.chars().count() > 3500 {
        collapsed.chars().take(3500).collect::<String>()
    } else {
        collapsed
    }
}

pub async fn fetch(url: &str) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(8))
        .build()
        .map_err(|e| format!("Failed to build HTTP client: {e}"))?;

    let response = client
        .get(url)
        .header(
            "User-Agent",
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
        )
        .send()
        .await
        .map_err(|e| format!("Failed to fetch URL: {e}"))?;

    if !response.status().is_success() {
        return Err(format!("Fetch returned HTTP {}", response.status()));
    }

    let raw_html = response
        .text()
        .await
        .map_err(|e| format!("Failed to read response body: {e}"))?;

    let text = clean_html(&raw_html);
    crate::log::line(format!("web fetched '{url}', len={}", text.len()));
    Ok(text)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_clean_html() {
        let html = "<html><head><script>alert('bad');</script><style>.x{color:red}</style></head><body><h1>Hello &amp; World</h1><p>This is a &quot;test&quot;.</p></body></html>";
        let cleaned = clean_html(html);
        assert_eq!(cleaned, "Hello & World This is a \"test\".");
    }

    #[test]
    fn test_live_search() {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let res = search("cuaca jakarta hari ini").await;
            assert!(res.is_ok());
            let results = res.unwrap();
            assert!(!results.is_empty());
            assert!(!results[0].title.is_empty());
            assert!(results[0].url.starts_with("http"));
        });
    }
}
