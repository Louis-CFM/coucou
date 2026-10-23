// Jira: the active sprint of the user's board and the recent comments on the
// issues they follow. The polling lives in integrations.rs; this file holds the
// account and everything that turns Jira's answers into the card's data.
//
// Jira Cloud (an email and an API token, basic auth) and Jira Server / Data
// Center (a personal access token, bearer auth) both go through REST API v2,
// whose comment bodies are wiki markup: a mention is `[~accountid:…]` on Cloud
// and `[~login]` on Server, which is how a mention of the user is told apart.

use serde_json::{json, Value};

use crate::secrets;

pub const ID: &str = "integration_jira";
/// How far back the comments go.
pub const COMMENT_WINDOW_DAYS: i64 = 7;
/// Comments the card receives, newest first.
const MAX_COMMENTS: usize = 10;
const MAX_SNIPPET: usize = 160;

/// Where to reach Jira and how to sign in.
pub struct Account {
    pub base: String,
    pub auth: String,
    /// Cloud has its own search endpoint; Server keeps the classic one.
    pub cloud: bool,
}

/// Who the user is, as their comments and mentions name them.
#[derive(Default)]
pub struct Me {
    pub account_id: Option<String>,
    pub name: Option<String>,
    pub display_name: String,
}

pub fn account() -> Option<Account> {
    let base = base_url(&secrets::get("jira-url")?)?;
    let token = secrets::get("jira-token")?;
    let email = secrets::get("jira-email");
    Some(Account { base, auth: auth_header(email.as_deref(), token.trim()), cloud: email.is_some() })
}

/// The site's address without a trailing slash, or None when it is not a web address.
pub fn base_url(raw: &str) -> Option<String> {
    let parsed = reqwest::Url::parse(raw.trim()).ok()?;
    if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
        return None;
    }
    Some(parsed.as_str().trim_end_matches('/').to_string())
}

/// Basic auth with the email (Cloud), or the token alone as a bearer (Server).
fn auth_header(email: Option<&str>, token: &str) -> String {
    match email.map(str::trim).filter(|e| !e.is_empty()) {
        Some(email) => format!("Basic {}", crate::claude::base64_for(format!("{email}:{token}").as_bytes())),
        None => format!("Bearer {token}"),
    }
}

pub fn search_url(account: &Account, jql: &str, fields: &str, max: u32) -> String {
    let path = if account.cloud { "search/jql" } else { "search" };
    let mut url = reqwest::Url::parse(&format!("{}/rest/api/2/{path}", account.base)).expect("valid base");
    url.query_pairs_mut()
        .append_pair("jql", jql)
        .append_pair("fields", fields)
        .append_pair("maxResults", &max.to_string());
    url.into()
}

/// The issues the user follows, updated lately: where their comments come from.
pub fn followed_jql() -> String {
    format!(
        "(assignee = currentUser() OR reporter = currentUser() OR watcher = currentUser()) \
AND updated >= -{COMMENT_WINDOW_DAYS}d ORDER BY updated DESC"
    )
}

/// The user's most recently touched issue in an open sprint: the way to their board's sprint.
pub const SPRINT_JQL: &str = "sprint in openSprints() AND assignee = currentUser() ORDER BY updated DESC";

pub fn me(json: &Value) -> Me {
    let text = |k: &str| json.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string);
    Me {
        account_id: text("accountId"),
        name: text("name"),
        display_name: text("displayName").unwrap_or_default(),
    }
}

fn is_me(person: Option<&Value>, me: &Me) -> bool {
    let Some(person) = person else { return false };
    let field = |k: &str| person.get(k).and_then(Value::as_str);
    match (&me.account_id, &me.name) {
        (Some(id), _) if field("accountId") == Some(id.as_str()) => true,
        (_, Some(name)) => field("name") == Some(name.as_str()),
        _ => false,
    }
}

/// True when the wiki markup mentions the user.
pub fn mentions(body: &str, me: &Me) -> bool {
    let cloud = me.account_id.as_ref().is_some_and(|id| body.contains(&format!("[~accountid:{id}]")));
    let server = me.name.as_ref().is_some_and(|name| body.contains(&format!("[~{name}]")));
    cloud || server
}

/// The comment as one short line: mentions become `@name`, links and images
/// their text, and the rest of the markup is left as typed.
pub fn snippet(body: &str, me: &Me) -> String {
    let mut out = String::new();
    let mut rest = body;
    while let Some(start) = rest.find("[~") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        match after.find(']') {
            Some(end) => {
                let who = &after[..end];
                let mine = me.account_id.as_deref().is_some_and(|id| who == format!("accountid:{id}"))
                    || me.name.as_deref() == Some(who);
                out.push('@');
                out.push_str(if mine && !me.display_name.is_empty() { &me.display_name } else { "…" });
                rest = &after[end + 1..];
            }
            None => {
                out.push_str("[~");
                rest = after;
            }
        }
    }
    out.push_str(rest);
    let line = out
        .split_whitespace()
        .filter(|word| !(word.starts_with('!') && word.ends_with('!') && word.len() > 1))
        .collect::<Vec<_>>()
        .join(" ");
    if line.chars().count() <= MAX_SNIPPET {
        return line;
    }
    let cut: String = line.chars().take(MAX_SNIPPET - 1).collect();
    format!("{}…", cut.trim_end())
}

/// Jira's timestamps (`2026-10-22T12:51:23.606+0200`) in milliseconds since 1970.
pub fn timestamp_ms(raw: &str) -> Option<i64> {
    let (date, rest) = raw.split_once('T')?;
    let mut d = date.split('-').map(|p| p.parse::<i64>().ok());
    let (y, mo, da) = (d.next()??, d.next()??, d.next()??);
    let time_len = rest.find(['+', '-', 'Z']).unwrap_or(rest.len());
    let (time, zone) = rest.split_at(time_len);
    let mut t = time.split(':');
    let h: i64 = t.next()?.parse().ok()?;
    let mi: i64 = t.next()?.parse().ok()?;
    let seconds: f64 = t.next().unwrap_or("0").parse().ok()?;
    let offset_minutes = match zone {
        "" | "Z" => 0,
        z => {
            let sign = if z.starts_with('-') { -1 } else { 1 };
            let digits: String = z[1..].chars().filter(char::is_ascii_digit).collect();
            if digits.len() != 4 {
                return None;
            }
            sign * (digits[..2].parse::<i64>().ok()? * 60 + digits[2..].parse::<i64>().ok()?)
        }
    };
    let days = days_from_civil(y, mo, da);
    let secs = days * 86_400 + h * 3600 + mi * 60 - offset_minutes * 60;
    Some(secs * 1000 + (seconds * 1000.0).round() as i64)
}

/// Days since 1970-01-01 for a proleptic Gregorian date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// The comments others left on the followed issues since `since_ms`, newest first.
pub fn recent_comments(issues: &[Value], me: &Me, base: &str, since_ms: i64) -> Vec<Value> {
    let mut out: Vec<(i64, Value)> = Vec::new();
    for issue in issues {
        let Some(key) = issue.get("key").and_then(Value::as_str) else { continue };
        let fields = issue.get("fields");
        let summary = fields.and_then(|f| f.get("summary")).and_then(Value::as_str).unwrap_or("");
        let comments = fields
            .and_then(|f| f.pointer("/comment/comments"))
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or_default();
        for c in comments {
            if is_me(c.get("author"), me) {
                continue;
            }
            let Some(created) = c.get("created").and_then(Value::as_str).and_then(timestamp_ms) else { continue };
            if created < since_ms {
                continue;
            }
            let body = c.get("body").and_then(Value::as_str).unwrap_or("");
            let id = c.get("id").and_then(Value::as_str).unwrap_or_default();
            out.push((created, json!({
                "id": id,
                "key": key,
                "summary": summary,
                "author": c.pointer("/author/displayName").and_then(Value::as_str).unwrap_or(""),
                "text": snippet(body, me),
                "mention": mentions(body, me),
                "createdAt": created,
                "url": format!("{base}/browse/{key}?focusedCommentId={id}"),
            })));
        }
    }
    out.sort_by(|a, b| b.0.cmp(&a.0));
    out.into_iter().take(MAX_COMMENTS).map(|(_, v)| v).collect()
}

/// The active sprint's progress, from the agile API's sprint and its issues.
pub fn sprint_summary(sprint: &Value, issues: &[Value], me: &Me, base: &str, now_ms: i64) -> Option<Value> {
    let name = sprint.get("name").and_then(Value::as_str)?;
    let mut counts = [0u32; 3];
    let mut mine = [0u32; 3];
    for issue in issues {
        let slot = match issue.pointer("/fields/status/statusCategory/key").and_then(Value::as_str) {
            Some("done") => 2,
            Some("indeterminate") => 1,
            _ => 0,
        };
        counts[slot] += 1;
        if is_me(issue.pointer("/fields/assignee"), me) {
            mine[slot] += 1;
        }
    }
    let days_left = sprint
        .get("endDate")
        .and_then(Value::as_str)
        .and_then(timestamp_ms)
        .map(|end| ((end - now_ms).max(0) + 86_399_999) / 86_400_000);
    let board = sprint.get("originBoardId").and_then(Value::as_i64);
    Some(json!({
        "name": name,
        "daysLeft": days_left,
        "todo": counts[0],
        "inProgress": counts[1],
        "done": counts[2],
        "mineTodo": mine[0],
        "mineInProgress": mine[1],
        "mineDone": mine[2],
        "url": board.map(|b| format!("{base}/secure/RapidBoard.jspa?rapidView={b}")),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cloud_me() -> Me {
        Me { account_id: Some("712020:abc".into()), name: None, display_name: "Romain".into() }
    }

    #[test]
    fn cloud_signs_in_with_the_email_and_server_with_the_token_alone() {
        assert_eq!(auth_header(Some("a@b.c"), "tok"), format!("Basic {}", crate::claude::base64_for(b"a@b.c:tok")));
        assert_eq!(auth_header(None, "pat"), "Bearer pat");
        assert_eq!(auth_header(Some("  "), "pat"), "Bearer pat");
    }

    #[test]
    fn only_a_web_address_is_taken_as_the_site() {
        assert_eq!(base_url(" https://x.atlassian.net/ ").as_deref(), Some("https://x.atlassian.net"));
        assert_eq!(base_url("https://jira.corp/jira").as_deref(), Some("https://jira.corp/jira"));
        assert_eq!(base_url("file:///etc/passwd"), None);
        assert_eq!(base_url("x.atlassian.net"), None);
    }

    #[test]
    fn cloud_and_server_search_on_their_own_endpoint() {
        let cloud = Account { base: "https://x.atlassian.net".into(), auth: String::new(), cloud: true };
        let url = search_url(&cloud, "a = b", "summary", 5);
        assert!(url.starts_with("https://x.atlassian.net/rest/api/2/search/jql?jql=a+%3D+b&fields=summary&maxResults=5"), "{url}");
        let server = Account { cloud: false, base: "https://jira.corp".into(), ..cloud };
        assert!(search_url(&server, "a", "f", 1).starts_with("https://jira.corp/rest/api/2/search?"));
    }

    #[test]
    fn a_mention_is_found_by_account_id_on_cloud_and_by_login_on_server() {
        let me = cloud_me();
        assert!(mentions("Hi [~accountid:712020:abc], can you look?", &me));
        assert!(!mentions("Hi [~accountid:712020:abcd]", &me));
        assert!(!mentions("Hi Romain", &me));
        let server = Me { account_id: None, name: Some("rbrocheton".into()), display_name: String::new() };
        assert!(mentions("cc [~rbrocheton]", &server));
        assert!(!mentions("cc [~rbrocheton2]", &server));
    }

    #[test]
    fn the_snippet_names_the_user_hides_other_mentions_and_images_and_stays_short() {
        let me = cloud_me();
        assert_eq!(snippet("Hi [~accountid:712020:abc] and [~accountid:x],\nlook !shot.png|width=600!", &me), "Hi @Romain and @…, look");
        assert_eq!(snippet("broken [~ markup", &me), "broken [~ markup");
        let long = "word ".repeat(100);
        let s = snippet(&long, &me);
        assert_eq!(s.chars().count(), MAX_SNIPPET);
        assert!(s.ends_with('…'));
    }

    #[test]
    fn jira_timestamps_are_read_with_their_offset() {
        assert_eq!(timestamp_ms("1970-01-01T00:00:00.000+0000"), Some(0));
        assert_eq!(timestamp_ms("1970-01-01T02:00:00.000+0200"), Some(0));
        assert_eq!(timestamp_ms("2026-10-22T12:51:23.606+0200"), Some(1_792_666_283_606));
        assert_eq!(timestamp_ms("2026-10-22T10:51:23.606Z"), Some(1_792_666_283_606));
        assert_eq!(timestamp_ms("2026-10-22T05:51:23.606-05:00"), Some(1_792_666_283_606));
        assert_eq!(timestamp_ms("yesterday"), None);
    }

    #[test]
    fn recent_comments_from_others_come_newest_first() {
        let me = cloud_me();
        let issues = vec![json!({
            "key": "CC-1",
            "fields": { "summary": "Printer", "comment": { "comments": [
                { "id": "1", "created": "2026-10-20T10:00:00.000+0000", "author": { "accountId": "x", "displayName": "Ana" }, "body": "old one" },
                { "id": "2", "created": "2026-10-22T10:00:00.000+0000", "author": { "accountId": "712020:abc", "displayName": "Romain" }, "body": "mine" },
                { "id": "3", "created": "2026-10-22T11:00:00.000+0000", "author": { "accountId": "y", "displayName": "Bob" }, "body": "[~accountid:712020:abc] ping" },
                { "id": "4", "created": "2026-10-10T11:00:00.000+0000", "author": { "accountId": "y", "displayName": "Bob" }, "body": "too old" }
            ]}}
        })];
        let since = timestamp_ms("2026-10-15T00:00:00.000+0000").unwrap();
        let list = recent_comments(&issues, &me, "https://x.atlassian.net", since);
        let ids: Vec<&str> = list.iter().map(|c| c["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["3", "1"]);
        assert_eq!(list[0]["mention"], true);
        assert_eq!(list[0]["text"], "@Romain ping");
        assert_eq!(list[0]["author"], "Bob");
        assert_eq!(list[0]["url"], "https://x.atlassian.net/browse/CC-1?focusedCommentId=3");
        assert_eq!(list[1]["mention"], false);
    }

    #[test]
    fn the_sprint_counts_every_issue_and_the_users_own() {
        let me = cloud_me();
        let issue = |cat: &str, who: &str| json!({ "fields": { "status": { "statusCategory": { "key": cat } }, "assignee": { "accountId": who } } });
        let issues = vec![issue("new", "712020:abc"), issue("indeterminate", "z"), issue("done", "712020:abc"), issue("done", "z")];
        let now = timestamp_ms("2026-10-22T12:00:00.000+0000").unwrap();
        let sprint = json!({ "name": "Sprint 42", "endDate": "2026-10-24T10:00:00.000Z", "originBoardId": 7 });
        let s = sprint_summary(&sprint, &issues, &me, "https://x.atlassian.net", now).unwrap();
        assert_eq!(s["name"], "Sprint 42");
        assert_eq!((s["todo"].as_u64(), s["inProgress"].as_u64(), s["done"].as_u64()), (Some(1), Some(1), Some(2)));
        assert_eq!((s["mineTodo"].as_u64(), s["mineInProgress"].as_u64(), s["mineDone"].as_u64()), (Some(1), Some(0), Some(1)));
        assert_eq!(s["daysLeft"], 2);
        assert_eq!(s["url"], "https://x.atlassian.net/secure/RapidBoard.jspa?rapidView=7");
        let ended = json!({ "name": "S", "endDate": "2026-10-01T00:00:00.000Z" });
        assert_eq!(sprint_summary(&ended, &[], &me, "b", now).unwrap()["daysLeft"], 0);
        assert!(sprint_summary(&json!({}), &[], &me, "b", now).is_none());
    }
}
