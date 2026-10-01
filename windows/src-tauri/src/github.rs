// GitHub — CI for the branch you're on, and the pull requests waiting on you
// or on someone else.
//
// "The branch you're on" is the branch checked out in the folder of the last
// Claude Code session, read straight from its .git directory: no `git` process,
// no console flash, and nothing to configure. Everything else comes from one
// GraphQL query per poll, with the same token the macOS overview card uses.
//
// Events, at most one per poll, only for things that changed since the last
// poll: a CI run on that branch finishing, a new review on one of your pull
// requests, a new review requested from you. The first poll only fills the card.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{LazyLock, Mutex};

use serde_json::{json, Value};
use tauri::AppHandle;

use crate::integrations::{client, emit, status_error, IntegrationEvent, IntegrationUpdate};
use crate::log;
use crate::secrets;
use crate::time::{now_secs, parse_rfc3339};

const ID: &str = "integration_github";
const STALE_AFTER_SECS: i64 = 30 * 86_400;

// ── The session's branch ──────────────────────────────────────────────────────

static SESSION_CWD: Mutex<Option<PathBuf>> = Mutex::new(None);

/// Called for every Claude Code hook that carries a `cwd`.
pub fn note_cwd(cwd: &str) {
    if cwd.is_empty() {
        return;
    }
    *SESSION_CWD.lock().unwrap() = Some(PathBuf::from(cwd));
}

#[derive(Debug, PartialEq)]
struct BranchRef {
    owner: String,
    name: String,
    /// The branch's name on GitHub (its upstream), which is what CI ran on.
    branch: String,
}

/// The GitHub repository and branch checked out in `cwd`, if there is one.
fn branch_of(cwd: &Path) -> Option<BranchRef> {
    let (git_dir, common_dir) = find_git_dir(cwd)?;
    let head = std::fs::read_to_string(git_dir.join("HEAD")).ok()?;
    // Detached HEAD (rebase, bisect, checkout of a tag): no branch to follow.
    let local = head.trim().strip_prefix("ref: refs/heads/")?.to_string();
    let config = std::fs::read_to_string(common_dir.join("config")).ok()?;
    resolve_upstream(&config, &local)
}

/// `.git` is a directory in a normal checkout and a `gitdir: …` file in a
/// worktree, whose config then lives in the main repository (`commondir`).
fn find_git_dir(start: &Path) -> Option<(PathBuf, PathBuf)> {
    for dir in start.ancestors() {
        let dot_git = dir.join(".git");
        if dot_git.is_dir() {
            return Some((dot_git.clone(), dot_git));
        }
        if dot_git.is_file() {
            let text = std::fs::read_to_string(&dot_git).ok()?;
            let target = text.trim().strip_prefix("gitdir:")?.trim();
            let git_dir = dir.join(target);
            let common = std::fs::read_to_string(git_dir.join("commondir"))
                .map(|c| git_dir.join(c.trim()))
                .unwrap_or_else(|_| git_dir.clone());
            return Some((git_dir, common));
        }
    }
    None
}

/// Follows `branch.<local>.remote` / `.merge` to the GitHub repo and remote
/// branch name; a branch with no upstream is assumed to be pushed to origin
/// under the same name.
fn resolve_upstream(config: &str, local: &str) -> Option<BranchRef> {
    let sections = parse_git_config(config);
    let get = |section: &str, sub: &str, key: &str| -> Option<String> {
        sections
            .iter()
            .find(|(s, n, k, _)| s == section && n == sub && k == key)
            .map(|(_, _, _, v)| v.clone())
    };

    let remote = get("branch", local, "remote").unwrap_or_else(|| "origin".into());
    let branch = get("branch", local, "merge")
        .and_then(|m| m.strip_prefix("refs/heads/").map(str::to_string))
        .unwrap_or_else(|| local.to_string());

    let url = get("remote", &remote, "url").or_else(|| {
        // No such remote: take whichever remote points at GitHub.
        sections
            .iter()
            .filter(|(s, _, k, _)| s == "remote" && k == "url")
            .map(|(_, _, _, v)| v.clone())
            .find(|v| parse_github_url(v).is_some())
    })?;
    let (owner, name) = parse_github_url(&url)?;
    Some(BranchRef { owner, name, branch })
}

/// (section, subsection, key, value) — just enough of git-config(1) for
/// `[remote "x"]` and `[branch "x"]`. Section and key names are case-insensitive.
fn parse_git_config(text: &str) -> Vec<(String, String, String, String)> {
    let mut out = Vec::new();
    let (mut section, mut sub) = (String::new(), String::new());
    for raw in text.lines() {
        let line = raw.trim();
        if line.is_empty() || line.starts_with('#') || line.starts_with(';') {
            continue;
        }
        if let Some(header) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            match header.split_once(char::is_whitespace) {
                Some((s, n)) => {
                    section = s.to_ascii_lowercase();
                    sub = n.trim().trim_matches('"').to_string();
                }
                None => {
                    section = header.to_ascii_lowercase();
                    sub.clear();
                }
            }
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            let value = v.trim().trim_matches('"').to_string();
            out.push((section.clone(), sub.clone(), k.trim().to_ascii_lowercase(), value));
        }
    }
    out
}

/// `https://github.com/o/r(.git)`, `git@github.com:o/r.git`,
/// `ssh://git@github.com/o/r.git` → (o, r). Anything not on github.com → None.
fn parse_github_url(url: &str) -> Option<(String, String)> {
    let at = url.find("github.com")?;
    let rest = &url[at + "github.com".len()..];
    let rest = rest.strip_prefix(':').or_else(|| rest.strip_prefix('/'))?;
    let rest = rest.trim_end_matches('/');
    let rest = rest.strip_suffix(".git").unwrap_or(rest);
    let (owner, name) = rest.split_once('/')?;
    if owner.is_empty() || name.is_empty() || name.contains('/') {
        return None;
    }
    Some((owner.to_string(), name.to_string()))
}

// ── The query ─────────────────────────────────────────────────────────────────

const QUERY: &str = r#"
query($owner: String!, $name: String!, $ref: String!, $withRepo: Boolean!) {
  viewer {
    login
    repositories(ownerAffiliations: OWNER, first: 100, orderBy: {field: PUSHED_AT, direction: DESC}) {
      totalCount
      nodes { stargazerCount }
    }
    pullRequests(states: OPEN, first: 10, orderBy: {field: UPDATED_AT, direction: DESC}) {
      nodes {
        number title url isDraft headRefName reviewDecision updatedAt
        repository { nameWithOwner }
        latestReviews(first: 10) { nodes { id state author { login } } }
      }
    }
  }
  requests: search(query: "is:open is:pr user-review-requested:@me archived:false", type: ISSUE, first: 5) {
    issueCount
    nodes { ... on PullRequest { number title url author { login } repository { nameWithOwner } } }
  }
  repository(owner: $owner, name: $name) @include(if: $withRepo) {
    nameWithOwner
    ref(qualifiedName: $ref) {
      target {
        ... on Commit {
          oid url committedDate
          statusCheckRollup {
            state
            contexts(first: 50) {
              nodes {
                __typename
                ... on CheckRun { name conclusion detailsUrl }
                ... on StatusContext { context state targetUrl }
              }
            }
          }
        }
      }
    }
  }
}
"#;

pub async fn poll(app: AppHandle) {
    let Some(token) = secrets::get("github-token") else { return };
    let cwd = SESSION_CWD.lock().unwrap().clone();
    let target = cwd.as_deref().and_then(branch_of);

    let variables = match &target {
        Some(t) => json!({
            "owner": t.owner, "name": t.name,
            "ref": format!("refs/heads/{}", t.branch), "withRepo": true,
        }),
        None => json!({ "owner": "", "name": "", "ref": "", "withRepo": false }),
    };

    let response = client()
        .post("https://api.github.com/graphql")
        .header("Authorization", format!("Bearer {token}"))
        .header("User-Agent", "Coucou")
        .json(&json!({ "query": QUERY, "variables": variables }))
        .send()
        .await;
    let Ok(response) = response else { return };
    if !response.status().is_success() {
        emit(&app, IntegrationUpdate {
            id: ID,
            data: json!({}),
            error: Some(status_error(response.status().as_u16(), "Token lacks the needed scope")),
            event: None,
        });
        return;
    }
    let body: Value = response.json().await.unwrap_or(json!({}));
    let Some(data) = body.get("data").filter(|d| !d.is_null()) else {
        let message = body
            .pointer("/errors/0/message")
            .and_then(Value::as_str)
            .unwrap_or("Unexpected answer from GitHub");
        log::line(format!("github graphql: {message}"));
        emit(&app, IntegrationUpdate {
            id: ID,
            data: json!({}),
            error: Some(message.chars().take(80).collect()),
            event: None,
        });
        return;
    };

    let snapshot = Snapshot::parse(data, target.as_ref());
    let event = MEMORY.lock().unwrap().diff(&snapshot);
    emit(&app, IntegrationUpdate { id: ID, data: snapshot.to_json(), error: None, event });
}

// ── What the query says ───────────────────────────────────────────────────────

#[derive(Debug, Default)]
struct Snapshot {
    login: String,
    total_repos: i64,
    total_stars: i64,
    branch: Option<BranchState>,
    pulls: Vec<Pull>,
    requests: Vec<Request>,
    request_count: i64,
}

#[derive(Debug)]
struct BranchState {
    repo: String,
    branch: String,
    /// False when the branch only exists locally.
    pushed: bool,
    oid: String,
    /// SUCCESS, FAILURE, ERROR, PENDING, EXPECTED — None when no check ran.
    state: Option<String>,
    failing: Vec<String>,
    url: String,
    committed_at: String,
    pr: Option<i64>,
}

#[derive(Debug)]
struct Pull {
    repo: String,
    number: i64,
    title: String,
    url: String,
    draft: bool,
    head: String,
    /// APPROVED, CHANGES_REQUESTED, REVIEW_REQUIRED, or None.
    decision: Option<String>,
    reviews: Vec<Review>,
}

#[derive(Debug)]
struct Review {
    id: String,
    state: String,
    author: String,
}

#[derive(Debug)]
struct Request {
    repo: String,
    number: i64,
    title: String,
    url: String,
    author: String,
}

fn s(v: &Value, ptr: &str) -> String {
    v.pointer(ptr).and_then(Value::as_str).unwrap_or_default().to_string()
}

impl Snapshot {
    fn parse(data: &Value, target: Option<&BranchRef>) -> Self {
        let viewer = &data["viewer"];
        let login = s(viewer, "/login");

        let repos = &viewer["repositories"];
        let total_stars = repos["nodes"]
            .as_array()
            .map(|l| l.iter().filter_map(|r| r["stargazerCount"].as_i64()).sum())
            .unwrap_or(0);

        // Pull requests nobody has touched in a month are abandoned, not "on
        // the go" — bots opening them under your name leave plenty of those.
        // A new review bumps updatedAt, so one coming back to life reappears.
        let fresh_since = now_secs() - STALE_AFTER_SECS;
        let pulls: Vec<Pull> = viewer
            .pointer("/pullRequests/nodes")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter(|p| {
                        p["updatedAt"].as_str().and_then(parse_rfc3339).is_none_or(|t| t >= fresh_since)
                    })
                    .map(|p| Pull {
                        repo: s(p, "/repository/nameWithOwner"),
                        number: p["number"].as_i64().unwrap_or(0),
                        title: s(p, "/title"),
                        url: s(p, "/url"),
                        draft: p["isDraft"].as_bool().unwrap_or(false),
                        head: s(p, "/headRefName"),
                        decision: p["reviewDecision"].as_str().map(str::to_string),
                        reviews: p
                            .pointer("/latestReviews/nodes")
                            .and_then(Value::as_array)
                            .map(|rs| {
                                rs.iter()
                                    .map(|r| Review {
                                        id: s(r, "/id"),
                                        state: s(r, "/state"),
                                        author: s(r, "/author/login"),
                                    })
                                    .collect()
                            })
                            .unwrap_or_default(),
                    })
                    .collect()
            })
            .unwrap_or_default();

        let requests = data
            .pointer("/requests/nodes")
            .and_then(Value::as_array)
            .map(|list| {
                list.iter()
                    .filter(|n| n.get("url").is_some())
                    .map(|n| Request {
                        repo: s(n, "/repository/nameWithOwner"),
                        number: n["number"].as_i64().unwrap_or(0),
                        title: s(n, "/title"),
                        url: s(n, "/url"),
                        author: s(n, "/author/login"),
                    })
                    .collect()
            })
            .unwrap_or_default();

        let branch = target.and_then(|t| {
            // A repository the token can't see comes back null: no CI row then.
            let repo = data.get("repository").filter(|r| !r.is_null())?;
            let name_with_owner = s(repo, "/nameWithOwner");
            let pr = pulls
                .iter()
                .find(|p| p.head == t.branch && p.repo.eq_ignore_ascii_case(&name_with_owner))
                .map(|p| p.number);
            let commit = repo.pointer("/ref/target");
            let Some(commit) = commit.filter(|c| !c.is_null()) else {
                return Some(BranchState {
                    repo: name_with_owner,
                    branch: t.branch.clone(),
                    pushed: false,
                    oid: String::new(),
                    state: None,
                    failing: vec![],
                    url: String::new(),
                    committed_at: String::new(),
                    pr,
                });
            };
            let rollup = commit.get("statusCheckRollup").filter(|r| !r.is_null());
            let mut failing = Vec::new();
            let mut failing_url = None;
            if let Some(contexts) = rollup.and_then(|r| r.pointer("/contexts/nodes")).and_then(Value::as_array) {
                for c in contexts {
                    let (name, bad, url) = match c["__typename"].as_str() {
                        Some("CheckRun") => (
                            s(c, "/name"),
                            matches!(
                                c["conclusion"].as_str(),
                                Some("FAILURE" | "TIMED_OUT" | "STARTUP_FAILURE" | "ACTION_REQUIRED")
                            ),
                            s(c, "/detailsUrl"),
                        ),
                        Some("StatusContext") => (
                            s(c, "/context"),
                            matches!(c["state"].as_str(), Some("FAILURE" | "ERROR")),
                            s(c, "/targetUrl"),
                        ),
                        _ => continue,
                    };
                    if bad {
                        if failing_url.is_none() && !url.is_empty() {
                            failing_url = Some(url);
                        }
                        failing.push(name);
                    }
                }
            }
            Some(BranchState {
                repo: name_with_owner,
                branch: t.branch.clone(),
                pushed: true,
                oid: s(commit, "/oid"),
                state: rollup.and_then(|r| r["state"].as_str()).map(str::to_string),
                failing,
                // Straight to the failing job when there is one; the commit page
                // (which lists every check) otherwise.
                url: failing_url.unwrap_or_else(|| s(commit, "/url")),
                committed_at: s(commit, "/committedDate"),
                pr,
            })
        });

        Snapshot {
            login,
            total_repos: repos["totalCount"].as_i64().unwrap_or(0),
            total_stars,
            branch,
            pulls,
            requests,
            request_count: data.pointer("/requests/issueCount").and_then(Value::as_i64).unwrap_or(0),
        }
    }

    fn to_json(&self) -> Value {
        let branch = self.branch.as_ref().map(|b| {
            json!({
                "repo": b.repo,
                "branch": b.branch,
                "pushed": b.pushed,
                "state": b.state,
                "failing": b.failing,
                "url": b.url,
                "committedAt": b.committed_at,
                "pr": b.pr,
            })
        });
        let pulls: Vec<Value> = self
            .pulls
            .iter()
            .take(5)
            .map(|p| {
                json!({
                    "repo": p.repo, "number": p.number, "title": p.title, "url": p.url,
                    "draft": p.draft, "decision": p.decision,
                })
            })
            .collect();
        let requests: Vec<Value> = self
            .requests
            .iter()
            .map(|r| {
                json!({
                    "repo": r.repo, "number": r.number, "title": r.title, "url": r.url,
                    "author": r.author,
                })
            })
            .collect();
        json!({
            "login": self.login,
            "totalRepos": self.total_repos,
            "totalStars": self.total_stars,
            "branch": branch,
            "pulls": pulls,
            "requests": requests,
            "requestCount": self.request_count,
        })
    }
}

// ── What changed since the last poll ──────────────────────────────────────────

#[derive(Default)]
struct Memory {
    /// (repo@branch@commit, rollup state) at the last poll.
    ci: Option<(String, Option<String>)>,
    /// None until the first poll, which fills these without announcing anything.
    reviews: Option<HashSet<String>>,
    requests: Option<HashSet<String>>,
}

static MEMORY: LazyLock<Mutex<Memory>> = LazyLock::new(|| Mutex::new(Memory::default()));

fn is_pending(state: &Option<String>) -> bool {
    matches!(state.as_deref(), Some("PENDING" | "EXPECTED"))
}

impl Memory {
    /// Remembers this snapshot and returns the one event worth announcing.
    fn diff(&mut self, now: &Snapshot) -> Option<IntegrationEvent> {
        // (priority, event): lower wins. A red build beats everything else.
        let mut candidates: Vec<(u8, IntegrationEvent)> = Vec::new();

        // CI: only a run we watched go from pending to done. Switching to another
        // repo or branch, or a commit that was already finished when first seen,
        // says nothing — that's old news, not something that just happened.
        if let Some(b) = now.branch.as_ref().filter(|b| b.pushed) {
            let key = format!("{}@{}@{}", b.repo, b.branch, b.oid);
            if let Some((prev_key, prev_state)) = &self.ci {
                if *prev_key == key && is_pending(prev_state) {
                    match b.state.as_deref() {
                        Some("SUCCESS") => candidates.push((5, IntegrationEvent {
                            success: true,
                            label: format!("CI passed · {}", b.branch),
                            detail: Some(b.repo.clone()),
                            attention: false, item: None,
                        })),
                        Some("FAILURE" | "ERROR") => candidates.push((0, IntegrationEvent {
                            success: false,
                            label: format!("CI failed · {}", b.branch),
                            detail: Some(if b.failing.is_empty() {
                                b.repo.clone()
                            } else {
                                b.failing.join(", ")
                            }),
                            attention: false, item: None,
                        })),
                        _ => {}
                    }
                }
            }
            self.ci = Some((key, b.state.clone()));
        }

        // Reviews on your pull requests, by anyone but you.
        let mut review_ids = HashSet::new();
        for p in &now.pulls {
            for r in &p.reviews {
                if r.author == now.login || r.id.is_empty() {
                    continue;
                }
                review_ids.insert(r.id.clone());
                if self.reviews.as_ref().is_none_or(|seen| seen.contains(&r.id)) {
                    continue;
                }
                let on = format!("{} on {}", r.author, p.title);
                match r.state.as_str() {
                    "CHANGES_REQUESTED" => candidates.push((1, IntegrationEvent {
                        success: false,
                        label: format!("Changes requested · #{}", p.number),
                        detail: Some(on),
                        attention: false, item: None,
                    })),
                    "APPROVED" => candidates.push((4, IntegrationEvent {
                        success: true,
                        label: format!("Approved · #{}", p.number),
                        detail: Some(on),
                        attention: false, item: None,
                    })),
                    "COMMENTED" => candidates.push((3, IntegrationEvent {
                        success: true,
                        label: format!("New review · #{}", p.number),
                        detail: Some(on),
                        attention: true, item: None,
                    })),
                    _ => {}
                }
            }
        }
        self.reviews = Some(review_ids);

        // Reviews someone asked of you.
        let request_urls: HashSet<String> = now.requests.iter().map(|r| r.url.clone()).collect();
        if let Some(seen) = &self.requests {
            for r in now.requests.iter().filter(|r| !seen.contains(&r.url)) {
                candidates.push((2, IntegrationEvent {
                    success: true,
                    label: format!("Review requested · #{}", r.number),
                    detail: Some(format!("{}: {}", r.author, r.title)),
                    attention: true, item: None,
                }));
            }
        }
        self.requests = Some(request_urls);

        candidates.sort_by_key(|(p, _)| *p);
        candidates.into_iter().next().map(|(_, e)| e)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn github_urls() {
        let ok = |u: &str| parse_github_url(u).map(|(o, n)| format!("{o}/{n}"));
        assert_eq!(ok("https://github.com/Louis-CFM/coucou.git").as_deref(), Some("Louis-CFM/coucou"));
        assert_eq!(ok("https://github.com/Louis-CFM/coucou").as_deref(), Some("Louis-CFM/coucou"));
        assert_eq!(ok("https://me@github.com/a/b/").as_deref(), Some("a/b"));
        assert_eq!(ok("git@github.com:a/b.git").as_deref(), Some("a/b"));
        assert_eq!(ok("ssh://git@github.com/a/b.git").as_deref(), Some("a/b"));
        assert_eq!(ok("https://gitlab.com/a/b.git"), None);
        assert_eq!(ok("https://github.com/a"), None);
    }

    #[test]
    fn upstream_from_config() {
        let config = r#"
[core]
	bare = false
[remote "origin"]
	url = git@github.com:Louis-CFM/coucou.git
	fetch = +refs/heads/*:refs/remotes/origin/*
[remote "fork"]
	url = https://github.com/jhoan/coucou.git
[branch "main"]
	remote = origin
	merge = refs/heads/main
[branch "local-name"]
	remote = fork
	merge = refs/heads/remote-name
"#;
        let main = resolve_upstream(config, "main").unwrap();
        assert_eq!((main.owner.as_str(), main.name.as_str(), main.branch.as_str()), ("Louis-CFM", "coucou", "main"));
        let forked = resolve_upstream(config, "local-name").unwrap();
        assert_eq!((forked.owner.as_str(), forked.branch.as_str()), ("jhoan", "remote-name"));
        // Never pushed: same name on origin.
        let fresh = resolve_upstream(config, "feat/x").unwrap();
        assert_eq!((fresh.owner.as_str(), fresh.branch.as_str()), ("Louis-CFM", "feat/x"));
    }

    #[test]
    fn worktree_git_dir() {
        let root = std::env::temp_dir().join(format!("coucou-gh-{}", std::process::id()));
        let main_git = root.join("repo").join(".git");
        let wt_git = main_git.join("worktrees").join("wt");
        let wt = root.join("wt");
        std::fs::create_dir_all(&wt_git).unwrap();
        std::fs::create_dir_all(wt.join("sub")).unwrap();
        std::fs::write(main_git.join("config"), "[remote \"origin\"]\n\turl = https://github.com/a/b.git\n").unwrap();
        std::fs::write(wt_git.join("HEAD"), "ref: refs/heads/fix/thing\n").unwrap();
        std::fs::write(wt_git.join("commondir"), "../..\n").unwrap();
        std::fs::write(wt.join(".git"), format!("gitdir: {}\n", wt_git.display())).unwrap();

        let got = branch_of(&wt.join("sub")).unwrap();
        assert_eq!(got, BranchRef { owner: "a".into(), name: "b".into(), branch: "fix/thing".into() });
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn parses_a_graphql_answer() {
        let recent = crate::time::rfc3339_utc(now_secs() - 3600);
        let data = json!({
            "viewer": {
                "login": "me",
                "repositories": { "totalCount": 2, "nodes": [{ "stargazerCount": 3 }, { "stargazerCount": 4 }] },
                "pullRequests": { "nodes": [
                    { "number": 8, "title": "Calendar", "url": "u8", "isDraft": false, "headRefName": "feat/cal",
                      "reviewDecision": null, "updatedAt": recent,
                      "repository": { "nameWithOwner": "Louis-CFM/coucou" },
                      "latestReviews": { "nodes": [{ "id": "r1", "state": "COMMENTED", "author": { "login": "louis" } }] } },
                    { "number": 2, "title": "[Snyk] Fix", "url": "u2", "isDraft": false, "headRefName": "snyk-fix-1",
                      "reviewDecision": null, "updatedAt": "2025-12-14T14:33:19Z",
                      "repository": { "nameWithOwner": "me/old" }, "latestReviews": { "nodes": [] } },
                ] },
            },
            "requests": { "issueCount": 0, "nodes": [] },
            "repository": {
                "nameWithOwner": "Louis-CFM/coucou",
                "ref": { "target": {
                    "oid": "abc", "url": "commit-url", "committedDate": recent,
                    "statusCheckRollup": { "state": "FAILURE", "contexts": { "nodes": [
                        { "__typename": "CheckRun", "name": "lint", "conclusion": "SUCCESS", "detailsUrl": "l" },
                        { "__typename": "CheckRun", "name": "build", "conclusion": "FAILURE", "detailsUrl": "job-url" },
                    ] } },
                } },
            },
        });
        let target = BranchRef { owner: "Louis-CFM".into(), name: "coucou".into(), branch: "feat/cal".into() };
        let s = Snapshot::parse(&data, Some(&target));
        assert_eq!((s.total_repos, s.total_stars), (2, 7));
        // The ten-month-old bot PR is gone.
        assert_eq!(s.pulls.iter().map(|p| p.number).collect::<Vec<_>>(), vec![8]);
        let b = s.branch.unwrap();
        assert_eq!((b.state.as_deref(), b.failing.as_slice(), b.url.as_str(), b.pr), (Some("FAILURE"), &["build".to_string()][..], "job-url", Some(8)));
    }

    fn snapshot(state: Option<&str>, reviews: &[(&str, &str)], requests: &[&str]) -> Snapshot {
        Snapshot {
            login: "me".into(),
            branch: Some(BranchState {
                repo: "a/b".into(),
                branch: "fix".into(),
                pushed: true,
                oid: "abc".into(),
                state: state.map(str::to_string),
                failing: if state == Some("FAILURE") { vec!["build".into()] } else { vec![] },
                url: String::new(),
                committed_at: String::new(),
                pr: Some(7),
            }),
            pulls: vec![Pull {
                repo: "a/b".into(),
                number: 7,
                title: "Fix".into(),
                url: "u7".into(),
                draft: false,
                head: "fix".into(),
                decision: None,
                reviews: reviews
                    .iter()
                    .map(|(id, st)| Review { id: (*id).into(), state: (*st).into(), author: "louis".into() })
                    .collect(),
            }],
            requests: requests
                .iter()
                .map(|u| Request { repo: "a/b".into(), number: 9, title: "T".into(), url: (*u).into(), author: "x".into() })
                .collect(),
            ..Default::default()
        }
    }

    #[test]
    fn first_poll_is_silent_then_changes_are_announced() {
        let mut m = Memory::default();
        // Already red when first seen, an existing review, an existing request.
        assert!(m.diff(&snapshot(Some("FAILURE"), &[("r1", "COMMENTED")], &["p1"])).is_none());
        // Same again: nothing new.
        assert!(m.diff(&snapshot(Some("FAILURE"), &[("r1", "COMMENTED")], &["p1"])).is_none());

        // A new review request.
        let e = m.diff(&snapshot(Some("FAILURE"), &[("r1", "COMMENTED")], &["p1", "p2"])).unwrap();
        assert!(e.attention && e.label.starts_with("Review requested"));

        // An approval.
        let e = m.diff(&snapshot(Some("FAILURE"), &[("r2", "APPROVED")], &["p1", "p2"])).unwrap();
        assert!(e.success && e.label == "Approved · #7");
    }

    #[test]
    fn ci_is_announced_only_on_a_watched_transition() {
        let mut m = Memory::default();
        assert!(m.diff(&snapshot(Some("PENDING"), &[], &[])).is_none());
        let e = m.diff(&snapshot(Some("FAILURE"), &[], &[])).unwrap();
        assert!(!e.success && e.label == "CI failed · fix" && e.detail.as_deref() == Some("build"));
        // Still red on the next poll: already said.
        assert!(m.diff(&snapshot(Some("FAILURE"), &[], &[])).is_none());

        // A red build outranks an approval landing in the same poll.
        let mut m = Memory::default();
        m.diff(&snapshot(Some("PENDING"), &[], &[]));
        let e = m.diff(&snapshot(Some("FAILURE"), &[("r9", "APPROVED")], &[])).unwrap();
        assert!(e.label.starts_with("CI failed"));
    }
}
