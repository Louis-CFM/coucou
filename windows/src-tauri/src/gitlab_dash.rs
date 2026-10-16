// The GitLab panel's data — the pure half: what a merge request line holds, which
// discussion threads wait for my answer, the four lists, and the alerts between
// two polls. Away from the network so it can be tested; gitlab_panel.rs fetches.
//
// "A thread waits for me" (decided with the user):
// - a resolvable thread (a code or a threaded comment) that is not resolved,
//   whose last message is not mine, on a merge request that is mine or where I
//   wrote in that thread;
// - a plain comment (not resolvable) whose last message is not mine, on such a
//   merge request, and that is newer than anything I wrote there — GitLab has
//   no "resolved" for it, so my own later message is what clears it.
// System notes ("added 2 commits", "approved this merge request") are no message,
// and neither are those of automated accounts (SonarQube, dependabot, project
// bots…) nor SonarQube's report, which often comes under an ordinary account
// (its author is a person's name, only its text gives it away): the panel is for
// what people wrote. A thread that only holds such notes is not shown, nor
// counted among the open threads of a merge request.

use std::collections::HashMap;

use serde::Serialize;
use serde_json::Value;

use crate::github::{CiState, GitHubEvent};
use crate::gitlab;

// ── Shapes sent to the panel ──────────────────────────────────────────────────

#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Approvals {
    pub given: i64,
    /// 0 when the project asks for none.
    pub required: i64,
}

/// One merge request line.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DashMr {
    /// "group/project!12"
    pub id: String,
    /// "group/project"
    pub project: String,
    pub project_id: i64,
    pub iid: i64,
    pub title: String,
    pub url: String,
    pub is_draft: bool,
    pub ci: CiState,
    /// Unix time in milliseconds, 0 when unknown.
    pub updated_at: u64,
    pub approvals: Option<Approvals>,
    /// Resolvable threads not resolved yet; None when the discussions were not read.
    pub unresolved: Option<i64>,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct ThreadNote {
    pub id: i64,
    pub author: String,
    pub username: String,
    pub body: String,
    pub created_at: u64,
    pub is_me: bool,
}

/// Where a thread hangs in the code: enough to read the lines around it.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CodePosition {
    pub file: String,
    pub line: i64,
    /// "new" (the line exists after the change) or "old" (a removed line).
    pub side: String,
    /// The commit to read the file at.
    pub sha: String,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PendingThread {
    /// The discussion's id.
    pub id: String,
    /// Changes with the last message: a reply to a thread I answered is new again.
    pub key: String,
    pub project: String,
    pub project_id: i64,
    pub mr_iid: i64,
    pub mr_ref: String,
    pub mr_title: String,
    pub mr_url: String,
    pub resolvable: bool,
    pub notes: Vec<ThreadNote>,
    pub position: Option<CodePosition>,
    pub last_at: u64,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Dashboard {
    pub me: String,
    /// The instance the data comes from: links open only on its host.
    pub base_url: String,
    /// Whether the token may write (scope `api`); None when GitLab did not say.
    pub can_write: Option<bool>,
    pub to_review: Vec<DashMr>,
    pub mine: Vec<DashMr>,
    pub approved: Vec<DashMr>,
    pub comments: Vec<PendingThread>,
    pub fetched_at: u64,
}

// ── Dates ─────────────────────────────────────────────────────────────────────

/// "2026-01-14T08:00:00.000Z" or "…+02:00" → Unix milliseconds.
pub fn parse_iso_ms(raw: &str) -> Option<u64> {
    let days = gitlab::parse_date(raw)?;
    let time = raw.get(11..19)?;
    let mut parts = time.split(':');
    let h: i64 = parts.next()?.parse().ok()?;
    let m: i64 = parts.next()?.parse().ok()?;
    let s: i64 = parts.next()?.parse().ok()?;
    let mut rest = raw.get(19..)?;
    let mut ms = 0;
    if let Some(frac) = rest.strip_prefix('.') {
        let digits: String = frac.chars().take_while(char::is_ascii_digit).collect();
        rest = &frac[digits.len()..];
        let three = format!("{digits:0<3}");
        ms = three[..3].parse::<i64>().ok()?;
    }
    let offset_min = match rest.as_bytes().first() {
        Some(b'+') | Some(b'-') => {
            let sign = if rest.starts_with('-') { -1 } else { 1 };
            let mut p = rest[1..].split(':');
            let oh: i64 = p.next()?.parse().ok()?;
            let om: i64 = p.next().unwrap_or("0").parse().ok()?;
            sign * (oh * 60 + om)
        }
        _ => 0,
    };
    let total = days * 86_400_000 + h * 3_600_000 + m * 60_000 + s * 1000 + ms - offset_min * 60_000;
    u64::try_from(total).ok()
}

/// Names of accounts that post by themselves, matched whole (lower case) against
/// the words of an account's username and name.
const AUTOMATED_WORDS: &[&str] = &[
    "bot", "dependabot", "renovate", "renovatebot", "codecov", "snyk", "danger", "dangerbot", "sonar", "sonarqube",
    "sonarcloud", "sonarscanner", "coveralls", "semgrep", "mergify", "reviewdog",
];

/// True for an account that posts automated messages (a CI analysis, a dependency
/// bot): GitLab's own `bot` flag when it gives one, a project or group access
/// token's bot user (`project_12_bot_…`), a name with "[bot]", or a username or
/// name made of the words of a known tool. "sonar" matches wherever it is, since
/// SonarQube runs under many names (sonarqube, sonar-bot, sonarqube-service…).
pub fn is_automated(author: Option<&Value>) -> bool {
    let Some(author) = author else { return false };
    if author.get("bot").and_then(Value::as_bool) == Some(true) {
        return true;
    }
    let username = str_at(author, "username").unwrap_or("").to_lowercase();
    let name = str_at(author, "name").unwrap_or("").to_lowercase();
    if username.contains("sonar") || name.contains("sonar") || name.contains("[bot]") || username.contains("[bot]") {
        return true;
    }
    // project_123_bot / group_45_bot_abcdef: access tokens' users.
    let words = |text: &str| -> Vec<String> {
        text.split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .map(str::to_string)
            .collect()
    };
    let token_user = (username.starts_with("project_") || username.starts_with("group_")) && username.contains("_bot");
    token_user
        || words(&username).iter().chain(words(&name).iter()).any(|w| AUTOMATED_WORDS.contains(&w.as_str()))
}

/// True for the text of a code-analysis report posted by a tool, whoever's account
/// it was posted from: SonarQube's "Quality Gate" comment on a merge request.
pub fn is_automated_text(body: &str) -> bool {
    let lower = body.trim_start().to_lowercase();
    lower.starts_with("sonarqube")
        || lower.starts_with("sonarcloud")
        || lower.starts_with("**sonar")
        || lower.contains("see analysis details on sonar")
        || (lower.contains("quality gate") && lower.contains("sonar"))
}

/// A note nobody wrote to be read: from an automated account, or a tool's report.
fn is_automated_note(note: &Value) -> bool {
    is_automated(note.get("author")) || is_automated_text(str_at(note, "body").unwrap_or(""))
}

fn str_at<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

fn array(v: Option<&Value>) -> &[Value] {
    v.and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

// ── One merge request ─────────────────────────────────────────────────────────

/// Everything read about one merge request: its line, whether I approved it, and
/// the threads that wait for me.
#[derive(Clone, Debug, PartialEq)]
pub struct MrEntry {
    pub mr: DashMr,
    pub author: String,
    pub open: bool,
    pub approved_by_me: bool,
    pub threads: Vec<PendingThread>,
}

/// The approvals answer: how many gave one, how many are asked, and whether I did.
pub fn parse_approvals(approvals: &Value, me: &str) -> (Approvals, bool) {
    let given_by = array(approvals.get("approved_by"));
    let by_me = given_by
        .iter()
        .any(|a| a.get("user").and_then(|u| str_at(u, "username")) == Some(me));
    let required = approvals.get("approvals_required").and_then(Value::as_i64).unwrap_or(0);
    (Approvals { given: given_by.len() as i64, required }, by_me)
}

/// The pending threads of one merge request, and how many resolvable threads are
/// still open (the "unresolved" count of its line).
pub fn pending_threads(discussions: &[Value], me: &str, i_am_author: bool, mr: &DashMr) -> (Vec<PendingThread>, i64) {
    struct Thread<'a> {
        id: &'a str,
        notes: Vec<ThreadNote>,
        resolvable: bool,
        resolved: bool,
        position: Option<CodePosition>,
    }

    let mut threads: Vec<Thread> = Vec::new();
    for d in discussions {
        let Some(id) = str_at(d, "id") else { continue };
        let raw = array(d.get("notes"));
        let mut notes = Vec::new();
        let from_people = |n: &&Value| {
            !n.get("system").and_then(Value::as_bool).unwrap_or(false) && !is_automated_note(n)
        };
        for n in raw.iter().filter(from_people) {
            let username = n.get("author").and_then(|a| str_at(a, "username")).unwrap_or("").to_string();
            notes.push(ThreadNote {
                id: n.get("id").and_then(Value::as_i64).unwrap_or(0),
                author: n
                    .get("author")
                    .and_then(|a| str_at(a, "name"))
                    .filter(|s| !s.is_empty())
                    .unwrap_or(&username)
                    .to_string(),
                is_me: username == me,
                username,
                body: str_at(n, "body").unwrap_or("").to_string(),
                created_at: str_at(n, "created_at").and_then(parse_iso_ms).unwrap_or(0),
            });
        }
        if notes.is_empty() {
            continue;
        }
        let resolvables: Vec<&Value> = raw
            .iter()
            .filter(|n| n.get("resolvable").and_then(Value::as_bool).unwrap_or(false))
            .collect();
        let resolvable = !resolvables.is_empty();
        let resolved = resolvable
            && resolvables.iter().all(|n| n.get("resolved").and_then(Value::as_bool).unwrap_or(false));
        let position = raw.iter().find_map(|n| n.get("position").filter(|p| p.is_object())).and_then(code_position);
        threads.push(Thread { id, notes, resolvable, resolved, position });
    }

    let unresolved = threads.iter().filter(|t| t.resolvable && !t.resolved).count() as i64;
    // My latest message anywhere in this merge request clears the plain comments before it.
    let my_last = threads
        .iter()
        .flat_map(|t| t.notes.iter())
        .filter(|n| n.is_me)
        .map(|n| n.created_at)
        .max()
        .unwrap_or(0);

    let mut out = Vec::new();
    for t in threads {
        let last = t.notes.last().expect("a thread has a message");
        if last.is_me {
            continue;
        }
        let wrote_in_it = t.notes.iter().any(|n| n.is_me);
        if !(i_am_author || wrote_in_it) {
            continue;
        }
        let waiting = if t.resolvable { !t.resolved } else { last.created_at > my_last };
        if !waiting {
            continue;
        }
        out.push(PendingThread {
            id: t.id.to_string(),
            key: format!("{}:{}", t.id, last.id),
            project: mr.project.clone(),
            project_id: mr.project_id,
            mr_iid: mr.iid,
            mr_ref: mr.id.clone(),
            mr_title: mr.title.clone(),
            mr_url: mr.url.clone(),
            resolvable: t.resolvable,
            position: t.position,
            last_at: last.created_at,
            notes: t.notes,
        });
    }
    (out, unresolved)
}

/// A note's position → where to read the code. The new side when the line exists
/// after the change, else the old one (a removed line) at the base commit.
fn code_position(p: &Value) -> Option<CodePosition> {
    if let (Some(file), Some(line)) = (str_at(p, "new_path"), p.get("new_line").and_then(Value::as_i64)) {
        return Some(CodePosition {
            file: file.to_string(),
            line,
            side: "new".into(),
            sha: str_at(p, "head_sha")?.to_string(),
        });
    }
    let (file, line) = (str_at(p, "old_path")?, p.get("old_line").and_then(Value::as_i64)?);
    Some(CodePosition { file: file.to_string(), line, side: "old".into(), sha: str_at(p, "base_sha")?.to_string() })
}

/// A merge request's line out of its detail (`GET /projects/:id/merge_requests/:iid`).
pub fn parse_dash_mr(detail: &Value, approvals: Option<Approvals>, unresolved: Option<i64>) -> Option<DashMr> {
    let iid = detail.get("iid")?.as_i64()?;
    let project_id = detail.get("project_id")?.as_i64()?;
    let project = gitlab::project_path(detail)?;
    let ci = detail
        .get("head_pipeline")
        .filter(|p| p.is_object())
        .and_then(|p| str_at(p, "status"));
    Some(DashMr {
        id: format!("{project}!{iid}"),
        project,
        project_id,
        iid,
        title: str_at(detail, "title")?.to_string(),
        url: str_at(detail, "web_url")?.to_string(),
        is_draft: detail
            .get("draft")
            .or_else(|| detail.get("work_in_progress"))
            .and_then(Value::as_bool)
            .unwrap_or(false),
        ci: CiState::from_gitlab(ci),
        updated_at: str_at(detail, "updated_at").and_then(parse_iso_ms).unwrap_or(0),
        approvals,
        unresolved,
    })
}

/// Reads one merge request whole. None when it lacks a required field.
pub fn build_entry(detail: &Value, approvals: Option<&Value>, discussions: Option<&[Value]>, me: &str) -> Option<MrEntry> {
    let author = detail.get("author").and_then(|a| str_at(a, "username")).unwrap_or("").to_string();
    let (approvals, approved_by_me) = match approvals {
        Some(a) => {
            let (counts, by_me) = parse_approvals(a, me);
            (Some(counts), by_me)
        }
        None => (None, false),
    };
    let mut mr = parse_dash_mr(detail, approvals, None)?;
    let mut threads = Vec::new();
    if let Some(discussions) = discussions {
        let (found, unresolved) = pending_threads(discussions, me, author == me, &mr);
        threads = found;
        mr.unresolved = Some(unresolved);
    }
    Some(MrEntry {
        mr,
        open: str_at(detail, "state") == Some("opened"),
        author,
        approved_by_me,
        threads,
    })
}

// ── The four lists ────────────────────────────────────────────────────────────

/// How a merge request came into the perimeter.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Roles {
    pub reviewer: bool,
    pub assigned: bool,
    pub approved_event: bool,
}

pub const LIST_MAX: usize = 30;

fn newest_first(mut list: Vec<DashMr>) -> Vec<DashMr> {
    list.sort_by_key(|m| std::cmp::Reverse(m.updated_at));
    list.truncate(LIST_MAX);
    list
}

pub fn build_dashboard(me: &str, base_url: &str, can_write: Option<bool>, entries: &[(MrEntry, Roles)], now_ms: u64) -> Dashboard {
    let mut to_review = Vec::new();
    let mut mine = Vec::new();
    let mut approved = Vec::new();
    let mut comments: Vec<PendingThread> = Vec::new();
    for (e, roles) in entries.iter().filter(|(e, _)| e.open) {
        if e.author == me {
            mine.push(e.mr.clone());
        } else if roles.reviewer || roles.assigned {
            to_review.push(e.mr.clone());
        }
        if roles.approved_event && e.approved_by_me {
            approved.push(e.mr.clone());
        }
        comments.extend(e.threads.iter().cloned());
    }
    comments.sort_by_key(|t| std::cmp::Reverse(t.last_at));
    comments.truncate(LIST_MAX);
    Dashboard {
        me: me.to_string(),
        base_url: base_url.to_string(),
        can_write,
        to_review: newest_first(to_review),
        mine: newest_first(mine),
        approved: newest_first(approved),
        comments,
        fetched_at: now_ms,
    }
}

impl Dashboard {
    /// Alerts between two polls: a thread that is new, or has a new last message.
    /// The first poll (no `old`) stays silent.
    pub fn events(old: Option<&Dashboard>, new: &Dashboard) -> Vec<GitHubEvent> {
        let Some(old) = old else { return Vec::new() };
        let known: std::collections::HashSet<&str> = old.comments.iter().map(|t| t.key.as_str()).collect();
        new.comments
            .iter()
            .filter(|t| !known.contains(t.key.as_str()))
            .map(|t| GitHubEvent::CommentPending { thread_id: t.id.clone() })
            .collect()
    }
}

// ── Candidates from the events ────────────────────────────────────────────────

/// (project id, merge request iid) of the merge requests my events point at —
/// `action=approved` events carry the merge request as their target,
/// `action=commented` ones a note whose `noteable_type` is MergeRequest. Newest
/// first, without duplicates, at most `max`.
pub fn event_targets(events: &Value, max: usize) -> Vec<(i64, i64)> {
    let mut out: Vec<(i64, i64)> = Vec::new();
    for e in array(Some(events)) {
        let Some(project_id) = e.get("project_id").and_then(Value::as_i64) else { continue };
        let iid = if str_at(e, "target_type") == Some("MergeRequest") {
            e.get("target_iid").and_then(Value::as_i64)
        } else {
            e.get("note")
                .filter(|n| str_at(n, "noteable_type") == Some("MergeRequest"))
                .and_then(|n| n.get("noteable_iid"))
                .and_then(Value::as_i64)
        };
        let Some(iid) = iid else { continue };
        if !out.contains(&(project_id, iid)) {
            out.push((project_id, iid));
            if out.len() >= max {
                break;
            }
        }
    }
    out
}

/// The lines around `line` (1-based) in `text`: up to `context` before and
/// after, numbered. Empty when the file is shorter.
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct SnippetLine {
    pub number: i64,
    pub text: String,
    pub target: bool,
}

pub fn snippet(text: &str, line: i64, context: i64) -> Vec<SnippetLine> {
    if line < 1 {
        return Vec::new();
    }
    let from = (line - context).max(1);
    text.lines()
        .enumerate()
        .map(|(i, l)| (i as i64 + 1, l))
        .filter(|(n, _)| *n >= from && *n <= line + context)
        .map(|(number, l)| SnippetLine {
            number,
            // A very long line (minified code) would swell the panel.
            text: l.chars().take(300).collect(),
            target: number == line,
        })
        .collect()
}

/// MRs whose cached read is still good: same update time and no running pipeline.
pub fn is_fresh(cached: Option<&(String, MrEntry)>, updated_at: Option<&str>) -> bool {
    match (cached, updated_at) {
        (Some((at, entry)), Some(now)) => at == now && entry.mr.ci != CiState::Pending,
        _ => false,
    }
}

/// A map of the roles a candidate has, merged: a merge request reached from several lists.
pub fn merge_roles(map: &mut HashMap<(i64, i64), Roles>, key: (i64, i64), f: impl FnOnce(&mut Roles)) {
    f(map.entry(key).or_default());
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn detail(iid: i64, author: &str) -> Value {
        json!({
          "iid": iid, "project_id": 7, "title": "Add thing", "state": "opened",
          "web_url": format!("https://gitlab.com/g/p/-/merge_requests/{iid}"),
          "references": {"full": format!("g/p!{iid}")},
          "draft": false, "updated_at": "2026-01-14T08:00:00.000Z",
          "author": {"username": author},
          "head_pipeline": {"status": "running"}
        })
    }

    fn note(id: i64, who: &str, at: &str, body: &str) -> Value {
        json!({"id": id, "author": {"username": who, "name": who.to_uppercase()},
               "created_at": at, "body": body, "system": false})
    }

    fn thread(id: &str, notes: Vec<Value>, resolvable: bool, resolved: bool) -> Value {
        let notes: Vec<Value> = notes
            .into_iter()
            .map(|mut n| {
                n["resolvable"] = json!(resolvable);
                n["resolved"] = json!(resolved);
                n
            })
            .collect();
        json!({"id": id, "individual_note": !resolvable, "notes": notes})
    }

    fn mr() -> DashMr {
        parse_dash_mr(&detail(5, "me"), None, None).unwrap()
    }

    #[test]
    fn iso_dates_become_milliseconds() {
        assert_eq!(parse_iso_ms("1970-01-01T00:00:00.000Z"), Some(0));
        assert_eq!(parse_iso_ms("1970-01-01T00:00:01.500Z"), Some(1500));
        assert_eq!(parse_iso_ms("1970-01-01T01:00:00.000+01:00"), Some(0));
        assert_eq!(parse_iso_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_iso_ms("1970-01-01T00:00:00.5Z"), Some(500));
        assert_eq!(parse_iso_ms("nope"), None);
    }

    #[test]
    fn a_line_holds_what_the_panel_shows() {
        let m = parse_dash_mr(&detail(5, "me"), Some(Approvals { given: 1, required: 2 }), Some(3)).unwrap();
        assert_eq!((m.id.as_str(), m.project.as_str(), m.project_id, m.iid), ("g/p!5", "g/p", 7, 5));
        assert_eq!(m.ci, CiState::Pending);
        assert_eq!(m.approvals, Some(Approvals { given: 1, required: 2 }));
        assert!(m.updated_at > 0);
        assert!(!m.is_draft);
    }

    #[test]
    fn approvals_count_and_say_if_i_gave_one() {
        let a = json!({"approvals_required": 2, "approved_by": [{"user": {"username": "bob"}}, {"user": {"username": "me"}}]});
        let (counts, by_me) = parse_approvals(&a, "me");
        assert_eq!(counts, Approvals { given: 2, required: 2 });
        assert!(by_me);
        let (none, by_me) = parse_approvals(&json!({}), "me");
        assert_eq!(none, Approvals { given: 0, required: 0 });
        assert!(!by_me);
    }

    #[test]
    fn an_open_thread_with_their_answer_waits_for_me() {
        let d = vec![thread("t1", vec![note(1, "me", "2026-01-14T08:00:00Z", "why?"), note(2, "bob", "2026-01-14T09:00:00Z", "because")], true, false)];
        let (found, unresolved) = pending_threads(&d, "me", false, &mr());
        assert_eq!(unresolved, 1);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].id, "t1");
        assert_eq!(found[0].key, "t1:2");
        assert_eq!(found[0].notes.len(), 2);
        assert!(found[0].notes[0].is_me);
        assert_eq!(found[0].notes[1].author, "BOB");
        assert_eq!(found[0].mr_ref, "g/p!5");
    }

    #[test]
    fn my_own_last_word_or_a_resolved_thread_does_not_wait() {
        let mine_last = thread("t1", vec![note(1, "bob", "2026-01-14T08:00:00Z", "q"), note(2, "me", "2026-01-14T09:00:00Z", "a")], true, false);
        let resolved = thread("t2", vec![note(3, "bob", "2026-01-14T08:00:00Z", "q")], true, true);
        let (found, unresolved) = pending_threads(&[mine_last, resolved], "me", true, &mr());
        assert!(found.is_empty());
        assert_eq!(unresolved, 1, "only the open one counts");
    }

    #[test]
    fn a_thread_on_someone_elses_mr_waits_only_if_i_wrote_in_it() {
        let theirs = thread("t1", vec![note(1, "bob", "2026-01-14T08:00:00Z", "x"), note(2, "carol", "2026-01-14T09:00:00Z", "y")], true, false);
        let (found, _) = pending_threads(std::slice::from_ref(&theirs), "me", false, &mr());
        assert!(found.is_empty(), "I took no part in it");
        let (found, _) = pending_threads(&[theirs], "me", true, &mr());
        assert_eq!(found.len(), 1, "but it is on my merge request");
    }

    fn bot_note(id: i64, username: &str, name: &str, at: &str) -> Value {
        json!({"id": id, "author": {"username": username, "name": name}, "created_at": at, "body": "Quality gate failed", "system": false})
    }

    #[test]
    fn automated_accounts_are_told_from_people() {
        let user = |username: &str, name: &str| Some(json!({"username": username, "name": name}));
        for (username, name) in [
            ("sonarqube", "SonarQube"),
            ("svc-sonar", "Analysis service"),
            ("jenkins", "SonarCloud"),
            ("project_123_bot_a1b2c3", "ci-token"),
            ("group_9_bot", "x"),
            ("dependabot", "Dependabot"),
            ("renovate-bot", "Renovate Bot"),
            ("gitlab-bot", "GitLab Bot"),
            ("ci", "Release [bot]"),
            ("codecov", "Codecov"),
        ] {
            assert!(is_automated(user(username, name).as_ref()), "{username} / {name}");
        }
        for (username, name) in [
            ("bob", "Bob Martin"),
            ("jtalbot", "John Talbot"),
            ("abbot", "Anne Abbot"),
            ("robotics-team", "Robotics Team"),
            ("elodie", "Élodie Botrel"),
            ("projet_x", "Project X"),
        ] {
            assert!(!is_automated(user(username, name).as_ref()), "{username} / {name}");
        }
        assert!(is_automated(Some(&json!({"username": "ci", "name": "CI", "bot": true}))), "GitLab's own flag");
        assert!(!is_automated(Some(&json!({"username": "bob", "bot": false}))));
        assert!(!is_automated(None));
    }

    const SONAR_REPORT: &str = "SonarQube Code Analysis\nQuality Gate passed\nIssues  \n[![](https://codequality.example.io/static/passed-16px.png '')](https://codequality.example.io/project/issues?id=X&pullRequest=13355&resolved=false) 0 New issues  \nMeasures  \n22.2% Coverage on New Code  \n16.7% Duplication on New Code  \nSee analysis details on SonarQube";

    #[test]
    fn sonarqubes_report_is_told_by_its_text_whoever_posts_it() {
        assert!(is_automated_text(SONAR_REPORT));
        assert!(is_automated_text("  SonarCloud Quality Gate failed"));
        assert!(is_automated_text("Quality Gate failed\nsee Sonar for details"));
        assert!(is_automated_text("**SonarQube** found 3 issues"));
        assert!(!is_automated_text("Sonar says it is fine, but I disagree with the naming here"));
        assert!(!is_automated_text("The quality gate of our pipeline is too strict"));
        assert!(!is_automated_text("why this?"));
    }

    #[test]
    fn a_report_from_an_ordinary_account_is_not_shown() {
        // Posted by a person's account, as in the wild: only the text gives it away.
        let report = json!({"id": 1, "author": {"username": "adminMeyclub", "name": "adminMeyclub"},
                            "created_at": "2026-01-14T08:00:00Z", "body": SONAR_REPORT, "system": false});
        let d = vec![thread("t1", vec![report], false, false)];
        let (found, unresolved) = pending_threads(&d, "me", true, &mr());
        assert!(found.is_empty());
        assert_eq!(unresolved, 0);
        // …and a real comment from the same account is.
        let real = json!({"id": 2, "author": {"username": "adminMeyclub", "name": "adminMeyclub"},
                          "created_at": "2026-01-14T09:00:00Z", "body": "please rename this", "system": false});
        let (found, _) = pending_threads(&[thread("t2", vec![real], false, false)], "me", true, &mr());
        assert_eq!(found.len(), 1);
    }

    #[test]
    fn a_thread_of_automated_notes_is_not_shown_nor_counted() {
        let sonar = thread("t1", vec![bot_note(1, "sonarqube", "SonarQube", "2026-01-14T08:00:00Z")], true, false);
        let (found, unresolved) = pending_threads(&[sonar], "me", true, &mr());
        assert!(found.is_empty());
        assert_eq!(unresolved, 0, "an analysis nobody answers is no open thread of mine");
    }

    #[test]
    fn a_person_answering_an_automated_note_is_still_heard() {
        let d = vec![thread(
            "t1",
            vec![
                bot_note(1, "sonarqube", "SonarQube", "2026-01-14T08:00:00Z"),
                note(2, "bob", "2026-01-14T09:00:00Z", "this one is a false positive?"),
            ],
            true,
            false,
        )];
        let (found, unresolved) = pending_threads(&d, "me", true, &mr());
        assert_eq!(unresolved, 1);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].notes.len(), 1, "only the person's message is left");
        assert_eq!(found[0].notes[0].username, "bob");
    }

    #[test]
    fn an_automated_note_after_my_answer_does_not_bring_the_thread_back() {
        let d = vec![thread(
            "t1",
            vec![
                note(1, "bob", "2026-01-14T08:00:00Z", "please fix"),
                note(2, "me", "2026-01-14T09:00:00Z", "done"),
                bot_note(3, "sonarqube", "SonarQube", "2026-01-14T10:00:00Z"),
            ],
            true,
            false,
        )];
        let (found, _) = pending_threads(&d, "me", true, &mr());
        assert!(found.is_empty(), "my message is the last one a person wrote");
    }

    #[test]
    fn system_notes_are_no_message() {
        let mut system = note(2, "bob", "2026-01-14T09:00:00Z", "approved this merge request");
        system["system"] = json!(true);
        let d = vec![thread("t1", vec![note(1, "me", "2026-01-14T08:00:00Z", "q"), system], true, false)];
        let (found, _) = pending_threads(&d, "me", true, &mr());
        assert!(found.is_empty(), "my message is still the last one");
    }

    #[test]
    fn a_plain_comment_waits_until_i_write_after_it() {
        let c1 = thread("c1", vec![note(1, "bob", "2026-01-14T08:00:00Z", "nice")], false, false);
        let c2 = thread("c2", vec![note(2, "bob", "2026-01-14T10:00:00Z", "and this")], false, false);
        let reply = thread("r", vec![note(3, "me", "2026-01-14T09:00:00Z", "thanks")], false, false);
        let (found, unresolved) = pending_threads(&[c1, c2, reply], "me", true, &mr());
        assert_eq!(unresolved, 0, "plain comments are not resolvable");
        assert_eq!(found.iter().map(|t| t.id.as_str()).collect::<Vec<_>>(), vec!["c2"]);
    }

    #[test]
    fn a_code_thread_knows_its_line() {
        let mut n = note(1, "bob", "2026-01-14T08:00:00Z", "rename");
        n["position"] = json!({"new_path": "src/a.rs", "new_line": 42, "old_path": "src/a.rs", "old_line": null,
                               "head_sha": "H", "base_sha": "B"});
        let d = vec![thread("t1", vec![n], true, false)];
        let (found, _) = pending_threads(&d, "me", true, &mr());
        assert_eq!(
            found[0].position,
            Some(CodePosition { file: "src/a.rs".into(), line: 42, side: "new".into(), sha: "H".into() })
        );
        let mut removed = note(2, "bob", "2026-01-14T08:00:00Z", "why drop");
        removed["position"] = json!({"new_path": "src/a.rs", "new_line": null, "old_path": "src/a.rs", "old_line": 9,
                                     "head_sha": "H", "base_sha": "B"});
        let (found, _) = pending_threads(&[thread("t2", vec![removed], true, false)], "me", true, &mr());
        assert_eq!(found[0].position.as_ref().map(|p| (p.side.as_str(), p.line, p.sha.as_str())), Some(("old", 9, "B")));
    }

    #[test]
    fn an_entry_carries_its_threads_and_unresolved_count() {
        let d = vec![thread("t1", vec![note(1, "bob", "2026-01-14T08:00:00Z", "x")], true, false)];
        let a = json!({"approvals_required": 1, "approved_by": [{"user": {"username": "me"}}]});
        let e = build_entry(&detail(5, "me"), Some(&a), Some(&d), "me").unwrap();
        assert_eq!(e.threads.len(), 1);
        assert_eq!(e.mr.unresolved, Some(1));
        assert!(e.approved_by_me && e.open);
        assert_eq!(e.author, "me");
        let unread = build_entry(&detail(6, "me"), None, None, "me").unwrap();
        assert_eq!(unread.mr.unresolved, None, "discussions not read");
    }

    fn entry(iid: i64, author: &str, state: &str, updated: &str) -> MrEntry {
        let mut d = detail(iid, author);
        d["state"] = json!(state);
        d["updated_at"] = json!(updated);
        build_entry(&d, Some(&json!({"approved_by": [{"user": {"username": "me"}}]})), Some(&[]), "me").unwrap()
    }

    #[test]
    fn the_lists_follow_the_roles() {
        let entries = vec![
            (entry(1, "me", "opened", "2026-01-14T08:00:00Z"), Roles::default()),
            (entry(2, "bob", "opened", "2026-01-14T09:00:00Z"), Roles { reviewer: true, ..Default::default() }),
            (entry(3, "bob", "opened", "2026-01-14T10:00:00Z"), Roles { assigned: true, ..Default::default() }),
            (entry(4, "bob", "opened", "2026-01-14T11:00:00Z"), Roles { approved_event: true, ..Default::default() }),
            (entry(5, "bob", "merged", "2026-01-14T12:00:00Z"), Roles { reviewer: true, approved_event: true, ..Default::default() }),
        ];
        let d = build_dashboard("me", "https://gitlab.com", Some(true), &entries, 99);
        assert_eq!(d.mine.iter().map(|m| m.iid).collect::<Vec<_>>(), vec![1]);
        assert_eq!(d.to_review.iter().map(|m| m.iid).collect::<Vec<_>>(), vec![3, 2], "newest first");
        assert_eq!(d.approved.iter().map(|m| m.iid).collect::<Vec<_>>(), vec![4], "merged ones are left out");
        assert_eq!((d.me.as_str(), d.can_write, d.fetched_at), ("me", Some(true), 99));
        assert_eq!(d.base_url, "https://gitlab.com");
    }

    #[test]
    fn an_approval_that_was_taken_back_is_no_longer_listed() {
        let mut e = entry(4, "bob", "opened", "2026-01-14T11:00:00Z");
        e.approved_by_me = false;
        let d = build_dashboard("me", "https://gitlab.com", None, &[(e, Roles { approved_event: true, ..Default::default() })], 1);
        assert!(d.approved.is_empty());
    }

    #[test]
    fn alerts_come_from_new_threads_only() {
        let t = |id: &str, last: i64| PendingThread {
            id: id.into(), key: format!("{id}:{last}"), project: "g/p".into(), project_id: 7, mr_iid: 5,
            mr_ref: "g/p!5".into(), mr_title: "T".into(), mr_url: String::new(), resolvable: true,
            notes: vec![], position: None, last_at: 0,
        };
        let empty = build_dashboard("me", "https://gitlab.com", None, &[], 0);
        let mut old = empty.clone();
        old.comments = vec![t("a", 1)];
        let mut new = empty;
        new.comments = vec![t("a", 1), t("b", 3)];
        assert!(Dashboard::events(None, &new).is_empty(), "first poll is silent");
        assert_eq!(Dashboard::events(Some(&old), &new), vec![GitHubEvent::CommentPending { thread_id: "b".into() }]);
        // A new answer in a thread I had cleared brings it back.
        new.comments = vec![t("a", 2)];
        assert_eq!(Dashboard::events(Some(&old), &new), vec![GitHubEvent::CommentPending { thread_id: "a".into() }]);
        // A thread that went away raises nothing.
        new.comments = vec![];
        assert!(Dashboard::events(Some(&old), &new).is_empty());
    }

    #[test]
    fn events_point_at_merge_requests() {
        let events = json!([
          {"project_id": 1, "target_type": "MergeRequest", "target_iid": 10, "action_name": "approved"},
          {"project_id": 1, "target_type": "DiffNote", "action_name": "commented on",
           "note": {"noteable_type": "MergeRequest", "noteable_iid": 11}},
          {"project_id": 1, "target_type": "Note", "note": {"noteable_type": "Issue", "noteable_iid": 12}},
          {"project_id": 1, "target_type": "MergeRequest", "target_iid": 10},
          {"project_id": 2, "target_type": "MergeRequest", "target_iid": 3},
          {"target_type": "MergeRequest", "target_iid": 99}
        ]);
        assert_eq!(event_targets(&events, 10), vec![(1, 10), (1, 11), (2, 3)]);
        assert_eq!(event_targets(&events, 2), vec![(1, 10), (1, 11)]);
        assert!(event_targets(&json!({}), 5).is_empty());
    }

    #[test]
    fn a_snippet_is_the_lines_around_the_target() {
        let text = "a\nb\nc\nd\ne\nf\ng\n";
        let s = snippet(text, 4, 2);
        assert_eq!(s.iter().map(|l| l.number).collect::<Vec<_>>(), vec![2, 3, 4, 5, 6]);
        assert_eq!(s.iter().find(|l| l.target).map(|l| l.text.as_str()), Some("d"));
        assert_eq!(snippet(text, 1, 2).iter().map(|l| l.number).collect::<Vec<_>>(), vec![1, 2, 3]);
        assert!(snippet(text, 40, 2).is_empty());
        assert!(snippet(text, 0, 2).is_empty());
        assert_eq!(snippet(&"x".repeat(1000), 1, 0)[0].text.len(), 300);
    }

    #[test]
    fn a_cached_read_is_fresh_while_nothing_moved() {
        let mut e = entry(1, "me", "opened", "2026-01-14T08:00:00Z");
        e.mr.ci = CiState::Success;
        let cached = ("2026-01-14T08:00:00Z".to_string(), e.clone());
        assert!(is_fresh(Some(&cached), Some("2026-01-14T08:00:00Z")));
        assert!(!is_fresh(Some(&cached), Some("2026-01-14T09:00:00Z")), "the merge request changed");
        assert!(!is_fresh(Some(&cached), None), "unknown update time: read again");
        assert!(!is_fresh(None, Some("2026-01-14T08:00:00Z")));
        let mut running = e;
        running.mr.ci = CiState::Pending;
        assert!(!is_fresh(Some(&("2026-01-14T08:00:00Z".to_string(), running)), Some("2026-01-14T08:00:00Z")), "pipeline still running");
    }
}
