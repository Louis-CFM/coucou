// GitLab pulse and activity — the pure half of the GitLab integration, next to
// github.rs. Parsing, URL rules and the contribution grid live here, away from
// the network, so they can be tested. The pollers are in integrations.rs.
//
// GitLab's answers are turned into the very types github.rs uses for GitHub
// (GitHubPulse, GitHubPr, GitHubRepoCi, GitHubActivity): a merge request is
// the `GitHubPr` shape, a project's default-branch pipeline the `GitHubRepoCi`
// one. The island therefore reads both providers the same way, and the alert
// rules (headSha, first poll silent…) are the same code.

use std::collections::HashMap;

use serde_json::Value;

use crate::github::{CiState, ContributionDay, GitHubActivity, GitHubPr, GitHubPulse, GitHubRepoCi, ReviewState};

pub const DEFAULT_URL: &str = "https://gitlab.com";

// ── Instance URL ──────────────────────────────────────────────────────────────

/// The instance the token belongs to: the stored URL, or gitlab.com when none.
/// Only https is accepted, plus http on this machine (a local test instance):
/// the token travels in a header and must not cross a network in clear text.
/// A path (GitLab under a sub-path) is kept; query, fragment and a trailing
/// slash are dropped.
pub fn normalize_base(raw: Option<&str>) -> Option<String> {
    let raw = raw.map(str::trim).filter(|s| !s.is_empty()).unwrap_or(DEFAULT_URL);
    let url = reqwest::Url::parse(raw).ok()?;
    let host = url.host_str()?;
    let local = matches!(host, "localhost" | "127.0.0.1" | "[::1]");
    match url.scheme() {
        "https" => {}
        "http" if local => {}
        _ => return None,
    }
    let mut base = format!("{}://{}", url.scheme(), host);
    if let Some(port) = url.port() {
        base.push_str(&format!(":{port}"));
    }
    let path = url.path().trim_end_matches('/');
    if !path.is_empty() {
        base.push_str(path);
    }
    Some(base)
}

pub fn api_url(base: &str, path: &str) -> String {
    format!("{base}/api/v4/{path}")
}

// ── States ────────────────────────────────────────────────────────────────────

impl CiState {
    /// A GitLab pipeline `status` → our four states. A pipeline that was
    /// cancelled, skipped or waits for a click says nothing about the code.
    pub fn from_gitlab(raw: Option<&str>) -> Self {
        match raw {
            Some("created" | "waiting_for_resource" | "preparing" | "pending" | "running" | "scheduled") => {
                CiState::Pending
            }
            Some("success" | "success_with_warnings") => CiState::Success,
            Some("failed") => CiState::Failure,
            _ => CiState::Unknown,
        }
    }
}

fn str_at<'a>(v: &'a Value, key: &str) -> Option<&'a str> {
    v.get(key).and_then(Value::as_str)
}

// ── Merge requests ────────────────────────────────────────────────────────────

/// "group/project" out of a MR item: `references.full` ("group/project!12"),
/// else the path of its web URL before "/-/merge_requests".
pub(crate) fn project_path(item: &Value) -> Option<String> {
    if let Some(full) = item.get("references").and_then(|r| str_at(r, "full")) {
        if let Some((repo, _)) = full.rsplit_once('!') {
            if !repo.is_empty() {
                return Some(repo.to_string());
            }
        }
    }
    let url = reqwest::Url::parse(str_at(item, "web_url")?).ok()?;
    let path = url.path();
    let (repo, _) = path.split_once("/-/merge_requests")?;
    let repo = repo.trim_matches('/');
    (!repo.is_empty()).then(|| repo.to_string())
}

/// One item of `GET /merge_requests`. None when a required field is missing
/// (that item is skipped, as for GitHub). `pipeline` is the MR's head pipeline
/// status, which the list does not carry (see `head_pipeline_status`).
pub fn parse_mr(item: &Value, pipeline: Option<&str>, with_ci: bool) -> Option<GitHubPr> {
    let number = item.get("iid")?.as_i64()?;
    let title = str_at(item, "title")?.to_string();
    let url = str_at(item, "web_url")?.to_string();
    let repo = project_path(item)?;
    let is_draft = item
        .get("draft")
        .or_else(|| item.get("work_in_progress"))
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let review = if with_ci {
        match str_at(item, "detailed_merge_status") {
            Some("not_approved") => ReviewState::Pending,
            _ => ReviewState::Unknown,
        }
    } else {
        ReviewState::Pending
    };
    Some(GitHubPr {
        id: format!("{repo}!{number}"),
        title,
        url,
        repo,
        number,
        is_draft,
        ci: if with_ci { CiState::from_gitlab(pipeline) } else { CiState::Unknown },
        review,
        head_sha: if with_ci { str_at(item, "sha").map(str::to_string) } else { None },
    })
}

/// `head_pipeline.status` of one `GET /projects/:id/merge_requests/:iid`.
pub fn head_pipeline_status(detail: &Value) -> Option<String> {
    detail
        .get("head_pipeline")
        .filter(|p| p.is_object())
        .and_then(|p| str_at(p, "status"))
        .map(str::to_string)
}

/// My open merge requests. `ci` maps "project_id!iid" → pipeline status. The
/// first occurrence of an id wins.
pub fn parse_my_mrs(list: &Value, ci: &HashMap<String, String>) -> Vec<GitHubPr> {
    let mut out: Vec<GitHubPr> = Vec::new();
    for item in list.as_array().map(Vec::as_slice).unwrap_or(&[]) {
        let key = mr_key(item);
        let status = key.as_ref().and_then(|k| ci.get(k)).map(String::as_str);
        let Some(mr) = parse_mr(item, status, true) else { continue };
        if !out.iter().any(|m| m.id == mr.id) {
            out.push(mr);
        }
    }
    out
}

/// Key of the pipeline-status map: "project_id!iid".
pub fn mr_key(item: &Value) -> Option<String> {
    Some(format!("{}!{}", item.get("project_id")?.as_i64()?, item.get("iid")?.as_i64()?))
}

/// Merge requests waiting for me: those where I am a reviewer, then those
/// assigned to me; my own (assigned to myself) and duplicates left out.
pub fn parse_to_review(reviewer: &Value, assigned: &Value, me: &str) -> Vec<GitHubPr> {
    let mut out: Vec<GitHubPr> = Vec::new();
    for list in [reviewer, assigned] {
        for item in list.as_array().map(Vec::as_slice).unwrap_or(&[]) {
            if item.get("author").and_then(|a| str_at(a, "username")) == Some(me) {
                continue;
            }
            let Some(mr) = parse_mr(item, None, false) else { continue };
            if !out.iter().any(|m| m.id == mr.id) {
                out.push(mr);
            }
        }
    }
    out
}

// ── Pipelines of the default branches ─────────────────────────────────────────

/// A project and the latest pipeline on its default branch. Archived projects,
/// and projects without a default branch (empty), are left out.
pub fn parse_repo_ci(project: &Value, latest_pipeline: Option<&Value>) -> Option<GitHubRepoCi> {
    if project.get("archived").and_then(Value::as_bool).unwrap_or(false) {
        return None;
    }
    let repo = str_at(project, "path_with_namespace")?.to_string();
    let url = str_at(project, "web_url")?.to_string();
    let branch = str_at(project, "default_branch")?.to_string();
    let pipeline = latest_pipeline.filter(|p| p.is_object());
    Some(GitHubRepoCi {
        repo,
        url,
        branch,
        ci: CiState::from_gitlab(pipeline.and_then(|p| str_at(p, "status"))),
        head_sha: pipeline.and_then(|p| str_at(p, "sha")).map(str::to_string),
    })
}

pub fn build_pulse(login: &str, my_mrs: Vec<GitHubPr>, to_review: Vec<GitHubPr>, main_ci: Vec<GitHubRepoCi>, now_ms: u64) -> GitHubPulse {
    GitHubPulse { login: login.to_string(), my_prs: my_mrs, to_review, main_ci, fetched_at: now_ms }
}

// ── Stats ─────────────────────────────────────────────────────────────────────

/// (projects, stars) over the user's own projects (`GET /projects?owned=true`).
pub fn parse_stats(projects: &Value) -> (i64, i64) {
    let list = projects.as_array().map(Vec::as_slice).unwrap_or(&[]);
    let stars = list.iter().filter_map(|p| p.get("star_count").and_then(Value::as_i64)).sum();
    (list.len() as i64, stars)
}

// ── Activity grid ─────────────────────────────────────────────────────────────
//
// GitLab has no contribution-calendar API, so the grid counts the user's own
// events (`GET /events`: pushes, merge requests, comments…) per day. That is
// close to GitLab's own calendar, not identical to it.

/// Days since 1970-01-01 → (year, month, day). Howard Hinnant's civil_from_days.
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// (year, month, day) → days since 1970-01-01. Howard Hinnant's days_from_civil.
fn days_from_civil(y: i64, m: u32, d: u32) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let mp = if m > 2 { m - 3 } else { m + 9 } as i64;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

fn format_date(days: i64) -> String {
    let (y, m, d) = civil_from_days(days);
    format!("{y:04}-{m:02}-{d:02}")
}

/// "YYYY-MM-DD" → days since the epoch; also takes a full ISO timestamp.
pub(crate) fn parse_date(raw: &str) -> Option<i64> {
    let date = raw.get(..10)?;
    let mut parts = date.split('-');
    let y: i64 = parts.next()?.parse().ok()?;
    let m: u32 = parts.next()?.parse().ok()?;
    let d: u32 = parts.next()?.parse().ok()?;
    ((1..=12).contains(&m) && (1..=31).contains(&d)).then(|| days_from_civil(y, m, d))
}

/// The date a poll starts from (`after` is exclusive): a year back.
pub fn events_after(now_ms: u64) -> String {
    format_date((now_ms / 86_400_000) as i64 - 366)
}

/// The date `days` days before now, "YYYY-MM-DD" (the `after` of an events poll).
pub fn date_days_ago(now_ms: u64, days: i64) -> String {
    format_date((now_ms / 86_400_000) as i64 - days)
}

/// Counts events per day over the last 53 weeks (Sunday first, the last week
/// ends today) and grades each day 0…4 against the busiest one.
pub fn parse_activity(events: &[Value], now_ms: u64) -> GitHubActivity {
    let today = (now_ms / 86_400_000) as i64;
    let mut counts: HashMap<i64, i64> = HashMap::new();
    for e in events {
        if let Some(day) = str_at(e, "created_at").and_then(parse_date) {
            if day <= today && day > today - 366 {
                *counts.entry(day).or_insert(0) += 1;
            }
        }
    }
    let total: i64 = counts.values().sum();
    let max = counts.values().copied().max().unwrap_or(0);

    let weekday = |day: i64| (day + 4).rem_euclid(7); // 1970-01-01 was a Thursday
    // Sunday of the current week, then 52 weeks back.
    let this_sunday = today - weekday(today);
    let mut weeks = Vec::new();
    for w in (0..53).rev() {
        let sunday = this_sunday - 7 * w;
        let mut days = Vec::new();
        for dow in 0..7 {
            let day = sunday + dow;
            if day > today {
                break;
            }
            let count = counts.get(&day).copied().unwrap_or(0);
            let level = if count == 0 || max == 0 { 0 } else { ((count * 4 + max - 1) / max).clamp(1, 4) as u8 };
            days.push(ContributionDay { date: format_date(day), count, level, weekday: dow as u8 });
        }
        weeks.push(days);
    }
    GitHubActivity { total, weeks, fetched_at: now_ms }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::github::GitHubEvent;
    use serde_json::json;

    fn mr(iid: i64, project_id: i64, title: &str) -> Value {
        json!({
          "iid": iid, "project_id": project_id, "title": title,
          "web_url": format!("https://gitlab.com/group/sub/proj/-/merge_requests/{iid}"),
          "references": {"full": format!("group/sub/proj!{iid}")},
          "draft": false, "sha": "abc", "detailed_merge_status": "mergeable",
          "author": {"username": "me"}
        })
    }

    #[test]
    fn base_url_defaults_to_gitlab_com() {
        assert_eq!(normalize_base(None).as_deref(), Some("https://gitlab.com"));
        assert_eq!(normalize_base(Some("  ")).as_deref(), Some("https://gitlab.com"));
    }

    #[test]
    fn base_url_is_cleaned() {
        assert_eq!(normalize_base(Some("https://git.corp.fr/")).as_deref(), Some("https://git.corp.fr"));
        assert_eq!(normalize_base(Some("https://git.corp.fr:8443/gitlab/?x=1#y")).as_deref(), Some("https://git.corp.fr:8443/gitlab"));
    }

    #[test]
    fn base_url_refuses_clear_text_off_machine() {
        assert_eq!(normalize_base(Some("http://git.corp.fr")), None);
        assert_eq!(normalize_base(Some("http://localhost:8080")).as_deref(), Some("http://localhost:8080"));
        assert_eq!(normalize_base(Some("ftp://git.corp.fr")), None);
        assert_eq!(normalize_base(Some("not a url")), None);
    }

    #[test]
    fn maps_pipeline_statuses() {
        assert_eq!(CiState::from_gitlab(Some("running")), CiState::Pending);
        assert_eq!(CiState::from_gitlab(Some("created")), CiState::Pending);
        assert_eq!(CiState::from_gitlab(Some("success")), CiState::Success);
        assert_eq!(CiState::from_gitlab(Some("failed")), CiState::Failure);
        assert_eq!(CiState::from_gitlab(Some("canceled")), CiState::Unknown);
        assert_eq!(CiState::from_gitlab(Some("manual")), CiState::Unknown);
        assert_eq!(CiState::from_gitlab(None), CiState::Unknown);
    }

    #[test]
    fn parses_my_mrs_with_their_pipeline() {
        let list = json!([mr(5, 10, "Add thing"), mr(6, 10, "Fix"), mr(5, 10, "dup")]);
        let ci = HashMap::from([("10!5".to_string(), "failed".to_string())]);
        let mrs = parse_my_mrs(&list, &ci);
        assert_eq!(mrs.len(), 2, "duplicate id dropped");
        assert_eq!(mrs[0].id, "group/sub/proj!5");
        assert_eq!(mrs[0].repo, "group/sub/proj");
        assert_eq!(mrs[0].number, 5);
        assert_eq!(mrs[0].ci, CiState::Failure);
        assert_eq!(mrs[0].head_sha.as_deref(), Some("abc"));
        assert_eq!(mrs[1].ci, CiState::Unknown, "no pipeline known");
    }

    #[test]
    fn repo_comes_from_the_url_without_references() {
        let mut item = mr(9, 1, "T");
        item.as_object_mut().unwrap().remove("references");
        assert_eq!(parse_mr(&item, None, true).unwrap().repo, "group/sub/proj");
    }

    #[test]
    fn skips_a_mr_missing_a_field() {
        let list = json!([{"iid": 1, "title": "no url"}, mr(2, 3, "ok")]);
        assert_eq!(parse_my_mrs(&list, &HashMap::new()).len(), 1);
    }

    #[test]
    fn draft_from_either_field() {
        let mut item = mr(1, 1, "T");
        item["draft"] = json!(true);
        assert!(parse_mr(&item, None, true).unwrap().is_draft);
        let old = json!({"iid": 1, "title": "T", "web_url": "https://gitlab.com/a/b/-/merge_requests/1", "work_in_progress": true});
        assert!(parse_mr(&old, None, true).unwrap().is_draft);
    }

    #[test]
    fn to_review_merges_reviewer_and_assigned_without_my_own() {
        let mut mine = mr(3, 1, "mine");
        mine["author"] = json!({"username": "me"});
        let mut theirs = mr(4, 1, "theirs");
        theirs["author"] = json!({"username": "bob"});
        let reviewer = json!([theirs.clone()]);
        let assigned = json!([theirs, mine]);
        let out = parse_to_review(&reviewer, &assigned, "me");
        assert_eq!(out.len(), 1);
        assert_eq!(out[0].id, "group/sub/proj!4");
        assert_eq!(out[0].review, ReviewState::Pending);
        assert_eq!(out[0].ci, CiState::Unknown);
    }

    #[test]
    fn default_branch_pipeline() {
        let project = json!({
          "path_with_namespace": "me/app", "web_url": "https://gitlab.com/me/app",
          "default_branch": "main", "archived": false
        });
        let pipeline = json!({"status": "failed", "sha": "def"});
        let r = parse_repo_ci(&project, Some(&pipeline)).unwrap();
        assert_eq!((r.repo.as_str(), r.branch.as_str(), r.ci), ("me/app", "main", CiState::Failure));
        assert_eq!(r.head_sha.as_deref(), Some("def"));
        assert_eq!(parse_repo_ci(&project, None).unwrap().ci, CiState::Unknown);
    }

    #[test]
    fn archived_and_empty_projects_are_left_out() {
        let archived = json!({"path_with_namespace": "a/b", "web_url": "u", "default_branch": "main", "archived": true});
        let empty = json!({"path_with_namespace": "a/c", "web_url": "u", "default_branch": null});
        assert!(parse_repo_ci(&archived, None).is_none());
        assert!(parse_repo_ci(&empty, None).is_none());
    }

    #[test]
    fn stats_sum_projects_and_stars() {
        let projects = json!([{"star_count": 2}, {"star_count": 5}, {}]);
        assert_eq!(parse_stats(&projects), (3, 7));
    }

    #[test]
    fn the_same_alert_rules_apply() {
        let old = build_pulse("me", vec![], vec![], vec![], 0);
        let mrs = parse_my_mrs(&json!([mr(1, 1, "T")]), &HashMap::from([("1!1".to_string(), "failed".to_string())]));
        let new = build_pulse("me", mrs, vec![], vec![], 1);
        assert!(GitHubPulse::events(None, &new).is_empty(), "first poll is silent");
        assert_eq!(
            GitHubPulse::events(Some(&old), &new),
            vec![GitHubEvent::CiFailed { pr_id: "group/sub/proj!1".into() }],
        );
    }

    #[test]
    fn civil_dates_round_trip() {
        assert_eq!(days_from_civil(1970, 1, 1), 0);
        assert_eq!(format_date(0), "1970-01-01");
        assert_eq!(parse_date("2026-02-28T10:00:00.000Z"), Some(days_from_civil(2026, 2, 28)));
        assert_eq!(format_date(days_from_civil(2024, 2, 29)), "2024-02-29");
        assert_eq!(parse_date("nope"), None);
    }

    #[test]
    fn activity_counts_events_per_day() {
        // 2026-01-14 is a Wednesday.
        let now = days_from_civil(2026, 1, 14) as u64 * 86_400_000 + 3_600_000;
        let events = vec![
            json!({"created_at": "2026-01-14T08:00:00.000Z"}),
            json!({"created_at": "2026-01-14T09:00:00.000Z"}),
            json!({"created_at": "2026-01-13T09:00:00.000Z"}),
            json!({"created_at": "2024-01-01T09:00:00.000Z"}), // too old
            json!({"no": "date"}),
        ];
        let a = parse_activity(&events, now);
        assert_eq!(a.total, 3);
        assert_eq!(a.weeks.len(), 53);
        let last = a.weeks.last().unwrap();
        assert_eq!(last.len(), 4, "Sunday to Wednesday, no future days");
        assert_eq!(last[3].date, "2026-01-14");
        assert_eq!((last[3].count, last[3].level, last[3].weekday), (2, 4, 3));
        assert_eq!((last[2].count, last[2].level), (1, 2));
        assert_eq!(last[1].level, 0);
        assert!(a.weeks[..52].iter().all(|w| w.len() == 7));
    }

    #[test]
    fn events_start_a_year_back() {
        let now = days_from_civil(2026, 6, 1) as u64 * 86_400_000;
        assert_eq!(events_after(now), "2025-05-31");
    }
}
