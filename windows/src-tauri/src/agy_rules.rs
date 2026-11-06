// Antigravity's own `command(...)` rules, read from its config files, so the island only asks
// about the shell commands Antigravity has no rule for (Settings → Agents → Antigravity →
// Approve commands from the notch). Port of AgyPermissionRules.swift (Mac, PR #934), same
// files, same matching, same tests.
//
// This never allows anything. A verdict only decides whether Coucou shows a card:
// - `Allowed` / `Denied`: no card, the relay answers "ask" and Antigravity applies its rule.
// - `Unknown`: the card shows, and only a click on Allow lets the command run.
// Both mistakes are safe: a command wrongly read as allowed gets Antigravity's own prompt,
// one wrongly read as new gets a card it did not need.

use std::path::Path;

use serde_json::{Map, Value};

#[derive(Debug, Default, Clone, PartialEq, Eq)]
pub struct AgyRules {
    /// The text inside each `command(...)` rule.
    pub allow: Vec<String>,
    pub deny: Vec<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Allowed,
    Denied,
    Unknown,
}

/// A command line read as a shell reads it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Parsed {
    /// Each part of the command line (split on && || ; | & and new lines), as words.
    pub segments: Vec<Vec<String>>,
    /// The line runs another command through $(…) or backticks.
    pub has_substitution: bool,
}

impl AgyRules {
    #[cfg(test)]
    pub fn new(allow: &[&str], deny: &[&str]) -> Self {
        Self {
            allow: allow.iter().map(|s| s.to_string()).collect(),
            deny: deny.iter().map(|s| s.to_string()).collect(),
        }
    }

    /// Adds the `command(...)` entries of a grants object: `{"allow": [...], "deny": [...]}`.
    /// Other rule kinds (read_file, mcp, read_url…) do not apply to shell commands.
    pub fn add_grants(&mut self, grants: &Value) {
        self.allow.extend(command_rules(&string_list(grants.get("allow"))));
        self.deny.extend(command_rules(&string_list(grants.get("deny"))));
    }

    /// What Antigravity's rules say about `command`.
    pub fn verdict(&self, command: &str) -> Verdict {
        let Some(parsed) = parse(command) else { return Verdict::Unknown };
        if parsed.segments.is_empty() {
            return Verdict::Unknown;
        }
        let deny_rules: Vec<Parsed> = self.deny.iter().filter_map(|r| parse(r)).collect();
        let allow_rules: Vec<Parsed> = self.allow.iter().filter_map(|r| parse(r)).collect();
        // A deny rule wins: Antigravity blocks the command itself, no card is needed.
        if deny_rules.iter().any(|rule| matches(rule, &parsed)) {
            return Verdict::Denied;
        }
        // A chained command saved as one rule ("git fetch && git rebase") matches exactly.
        if allow_rules.iter().any(|r| r.segments.len() > 1 && r.segments == parsed.segments) {
            return Verdict::Allowed;
        }
        // A command run inside $(…) or backticks is hidden from the rules below.
        if parsed.has_substitution {
            return if allow_rules.iter().any(|r| r.segments == parsed.segments) {
                Verdict::Allowed
            } else {
                Verdict::Unknown
            };
        }
        let every_part_allowed = parsed.segments.iter().all(|segment| {
            allow_rules.iter().any(|r| r.segments.len() == 1 && has_prefix(segment, &r.segments[0]))
        });
        if every_part_allowed { Verdict::Allowed } else { Verdict::Unknown }
    }

    /// The rules that apply to a session working in `cwd`: the CLI's settings, the shared
    /// global grants, and the grants of the Antigravity project(s) holding `cwd` (or of
    /// "Outside of Project" when none does). Missing or unreadable files add nothing.
    pub fn load(home: &Path, cwd: &str) -> AgyRules {
        let mut rules = AgyRules::default();
        let gemini = home.join(".gemini");
        if let Some(permissions) = read_object(&gemini.join("antigravity-cli").join("settings.json"))
            .and_then(|s| s.get("permissions").filter(|p| p.is_object()).cloned())
        {
            rules.add_grants(&permissions);
        }
        if let Some(grants) = read_object(&gemini.join("config").join("config.json"))
            .and_then(|c| c.get("userSettings")?.get("globalPermissionGrants").filter(|g| g.is_object()).cloned())
        {
            rules.add_grants(&grants);
        }
        let projects_dir = gemini.join("config").join("projects");
        let mut files: Vec<_> = std::fs::read_dir(&projects_dir)
            .map(|dir| dir.filter_map(Result::ok).map(|e| e.path()).collect())
            .unwrap_or_default();
        files.sort_by(|a, b| a.file_name().cmp(&b.file_name()));
        let mut in_project = false;
        for file in files {
            let name = file.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
            if file.extension().and_then(|e| e.to_str()) != Some("json") || name == "outside-of-project.json" {
                continue;
            }
            let Some(project) = read_object(&file) else { continue };
            if !project_folders(&project).iter().any(|f| folder_contains(f, cwd)) {
                continue;
            }
            in_project = true;
            rules.add_grants(&project_grants(&project));
        }
        if !in_project {
            if let Some(outside) = read_object(&projects_dir.join("outside-of-project.json")) {
                rules.add_grants(&project_grants(&outside));
            }
        }
        rules
    }
}

/// A JSON list of strings, as Swift's `as? [String]` reads it: anything else is empty.
fn string_list(value: Option<&Value>) -> Vec<String> {
    let Some(items) = value.and_then(Value::as_array) else { return Vec::new() };
    let strings: Vec<String> = items.iter().filter_map(|v| v.as_str().map(str::to_string)).collect();
    if strings.len() == items.len() { strings } else { Vec::new() }
}

/// A rule's words start every part (single-part rule) or match the whole chain.
fn matches(rule: &Parsed, command: &Parsed) -> bool {
    if rule.segments.len() > 1 {
        return rule.segments == command.segments;
    }
    let Some(words) = rule.segments.first() else { return false };
    command.segments.iter().any(|s| has_prefix(s, words))
}

/// True when `segment` starts with every word of `words`. A rule with no words
/// (`command()`, `command(   )`) matches nothing, as in Antigravity.
fn has_prefix(segment: &[String], words: &[String]) -> bool {
    !words.is_empty() && segment.len() >= words.len() && segment[..words.len()] == *words
}

/// `["command(git log)", "mcp(x/y)"]` → `["git log"]`.
pub fn command_rules(entries: &[String]) -> Vec<String> {
    entries
        .iter()
        .filter_map(|entry| {
            let trimmed = entry.trim();
            let inner = trimmed.strip_prefix("command(")?.strip_suffix(')')?;
            Some(inner.to_string())
        })
        .collect()
}

/// Splits a command line into parts and words, the way a POSIX shell reads quotes
/// and backslashes. None when a quote is left open: the line cannot be read reliably.
pub fn parse(line: &str) -> Option<Parsed> {
    let mut chars: Vec<char> = line.chars().collect();
    chars.push(' ');
    let mut segments: Vec<Vec<String>> = Vec::new();
    let mut words: Vec<String> = Vec::new();
    let mut word = String::new();
    let mut in_word = false;
    let mut substitution = false;
    let mut quote: Option<char> = None;
    let mut i = 0;

    fn end_word(words: &mut Vec<String>, word: &mut String, in_word: &mut bool) {
        if *in_word {
            words.push(std::mem::take(word));
        }
        word.clear();
        *in_word = false;
    }
    fn end_segment(segments: &mut Vec<Vec<String>>, words: &mut Vec<String>, word: &mut String, in_word: &mut bool) {
        end_word(words, word, in_word);
        if !words.is_empty() {
            segments.push(std::mem::take(words));
        }
    }

    while i < chars.len() {
        let c = chars[i];
        let next = chars.get(i + 1).copied();
        if let Some(q) = quote {
            if c == q {
                quote = None;
            } else if q == '"' && c == '\\' && next.is_some_and(|n| "\"\\$`".contains(n)) {
                word.push(next.unwrap());
                i += 1;
            } else {
                if q == '"' && (c == '`' || (c == '$' && next == Some('('))) {
                    substitution = true;
                }
                word.push(c);
            }
            i += 1;
            continue;
        }
        match c {
            '\'' | '"' => {
                quote = Some(c);
                in_word = true;
            }
            '\\' => {
                if let Some(n) = next.filter(|n| *n != '\n') {
                    word.push(n);
                    in_word = true;
                }
                i += 1;
            }
            ' ' | '\t' => end_word(&mut words, &mut word, &mut in_word),
            '\n' | '\r' | ';' => end_segment(&mut segments, &mut words, &mut word, &mut in_word),
            // A redirection (2>&1, >&2, &>file), not a separator.
            '&' if (in_word && (word.ends_with('>') || word.ends_with('<'))) || next == Some('>') => {
                word.push(c);
                in_word = true;
            }
            '&' | '|' => {
                // && || & | all end the part; a doubled operator is one separator.
                if next == Some(c) {
                    i += 1;
                }
                end_segment(&mut segments, &mut words, &mut word, &mut in_word);
            }
            '`' => {
                substitution = true;
                word.push(c);
                in_word = true;
            }
            '$' if next == Some('(') => {
                substitution = true;
                word.push(c);
                in_word = true;
            }
            _ => {
                word.push(c);
                in_word = true;
            }
        }
        i += 1;
    }
    if quote.is_some() {
        return None;
    }
    end_segment(&mut segments, &mut words, &mut word, &mut in_word);
    Some(Parsed { segments, has_substitution: substitution })
}

// ── Antigravity's files ───────────────────────────────────────────────────────

/// Folder paths of an Antigravity project file (`projectResources.resources[]`).
pub fn project_folders(project: &Value) -> Vec<String> {
    let Some(resources) = project
        .get("projectResources")
        .and_then(|r| r.get("resources"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    resources
        .iter()
        .filter_map(|resource| {
            let uri = resource
                .get("folderUri")
                .and_then(Value::as_str)
                .or_else(|| resource.get("gitFolder")?.get("folderUri")?.as_str())?;
            file_uri_path(uri)
        })
        .collect()
}

/// `permissionGrants.permissionGrants` (current files) or `permissionGrants` (older ones).
pub fn project_grants(project: &Value) -> Value {
    let outer = match project.get("permissionGrants") {
        Some(Value::Object(o)) => o.clone(),
        _ => Map::new(),
    };
    match outer.get("permissionGrants") {
        Some(Value::Object(inner)) => Value::Object(inner.clone()),
        _ => Value::Object(outer),
    }
}

/// The path of a `file:` URI, percent-decoded; None for any other scheme. Windows forms
/// as Antigravity (a VS Code fork) writes them: `file:///c%3A/Users/me/app` is `c:/Users/me/app`,
/// and `file://server/share/x` is `//server/share/x`.
pub fn file_uri_path(uri: &str) -> Option<String> {
    let scheme_end = uri.find(':')?;
    if !uri[..scheme_end].eq_ignore_ascii_case("file") {
        return None;
    }
    let rest = &uri[scheme_end + 1..];
    let rest = rest.split(['?', '#']).next().unwrap_or_default();
    let path = match rest.strip_prefix("//") {
        Some(after) => {
            let slash = after.find('/').unwrap_or(after.len());
            let (host, path) = after.split_at(slash);
            if host.is_empty() || host.eq_ignore_ascii_case("localhost") {
                path.to_string()
            } else {
                format!("//{}{}", percent_decode(host)?, path)
            }
        }
        None => rest.to_string(),
    };
    let mut path = percent_decode(&path)?;
    // `/c:/Users` → `c:/Users`.
    let bytes = path.as_bytes();
    if bytes.len() >= 3 && bytes[0] == b'/' && bytes[1].is_ascii_alphabetic() && bytes[2] == b':' {
        path.remove(0);
    }
    (!path.is_empty()).then_some(path)
}

fn percent_decode(s: &str) -> Option<String> {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let hex = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// A path with `/` separators, no `.` or `..` parts, no doubled or trailing slash, the way
/// NSString.standardizingPath reads it. A Windows path (drive letter, backslashes) is
/// compared without case, as Windows does.
fn standard_path(path: &str) -> (String, bool) {
    let windows = path.contains('\\') || {
        let b = path.as_bytes();
        b.len() >= 2 && b[0].is_ascii_alphabetic() && b[1] == b':'
    };
    let slashed = path.replace('\\', "/");
    let unc = slashed.starts_with("//");
    let absolute = slashed.starts_with('/');
    let mut parts: Vec<&str> = Vec::new();
    for part in slashed.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                // Never above a drive letter.
                if parts.last().is_some_and(|p| !p.ends_with(':')) {
                    parts.pop();
                }
            }
            other => parts.push(other),
        }
    }
    let joined = parts.join("/");
    let mut out = if unc {
        format!("//{joined}")
    } else if absolute {
        format!("/{joined}")
    } else {
        joined
    };
    if windows {
        out = out.to_lowercase();
    }
    (out, windows)
}

/// `cwd` is `folder` or inside it. Never for a filesystem root.
pub fn folder_contains(folder: &str, cwd: &str) -> bool {
    let (root, _) = standard_path(folder);
    let (path, _) = standard_path(cwd);
    let is_drive_root = root.len() == 2 && root.ends_with(':');
    if root.is_empty() || root == "/" || root == "//" || is_drive_root || path.is_empty() {
        return false;
    }
    path == root || path.starts_with(&format!("{root}/"))
}

fn read_object(path: &Path) -> Option<Value> {
    let bytes = std::fs::read(path).ok()?;
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes);
    serde_json::from_slice::<Value>(bytes).ok().filter(Value::is_object)
}

// Same cases as tests/AgyPermissionRulesTests.swift, in the same order, plus Windows paths.
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn words(line: &str) -> Option<Vec<Vec<String>>> {
        parse(line).map(|p| p.segments)
    }

    fn w(parts: &[&[&str]]) -> Option<Vec<Vec<String>>> {
        Some(parts.iter().map(|p| p.iter().map(|s| s.to_string()).collect()).collect())
    }

    fn write(path: &Path, text: &str) {
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }

    #[test]
    fn shell_words_are_read_as_a_shell_reads_them() {
        assert_eq!(words("npm test"), w(&[&["npm", "test"]]));
        assert_eq!(words("  git   log  "), w(&[&["git", "log"]]));
        assert_eq!(words("git fetch && git rebase"), w(&[&["git", "fetch"], &["git", "rebase"]]));
        assert_eq!(words("a || b; c | d & e\nf"), w(&[&["a"], &["b"], &["c"], &["d"], &["e"], &["f"]]));
        assert_eq!(words("git log --grep=\"a|b\""), w(&[&["git", "log", "--grep=a|b"]]));
        assert_eq!(words("echo 'x && y'"), w(&[&["echo", "x && y"]]));
        assert_eq!(words("echo \"say \\\"hi\\\"\""), w(&[&["echo", "say \"hi\""]]));
        assert_eq!(words("echo a\\ b"), w(&[&["echo", "a b"]]));
        assert_eq!(words("npm test 2>&1"), w(&[&["npm", "test", "2>&1"]]));
        assert_eq!(words("npm test &> log.txt"), w(&[&["npm", "test", "&>", "log.txt"]]));
        assert_eq!(words("echo \"\""), w(&[&["echo", ""]]));
        assert_eq!(words("echo 'open"), None); // open quote: unreadable
        assert!(parse("echo $(whoami)").unwrap().has_substitution);
        assert!(parse("echo \"`whoami`\"").unwrap().has_substitution);
        assert!(!parse("echo '$(whoami)'").unwrap().has_substitution);
    }

    #[test]
    fn only_command_entries_count() {
        let entries: Vec<String> =
            ["command(git log)", "mcp(x/y)", "read_file(/tmp)", " command(ls) "].iter().map(|s| s.to_string()).collect();
        assert_eq!(command_rules(&entries), vec!["git log", "ls"]);
    }

    fn rules() -> AgyRules {
        AgyRules::new(
            &["git log", "git status", "ls", "npm test", "git fetch && git rebase", "curl -s \"http://localhost:3000/\"", "", "   "],
            &["rm -rf", "git push"],
        )
    }

    #[test]
    fn allowed_when_every_part_starts_with_a_rules_words() {
        let r = rules();
        assert_eq!(r.verdict("git log --oneline -5"), Verdict::Allowed);
        assert_eq!(r.verdict("ls -la && git status"), Verdict::Allowed);
        assert_eq!(r.verdict("npm test 2>&1"), Verdict::Allowed);
        assert_eq!(r.verdict("git fetch && git rebase"), Verdict::Allowed);
        assert_eq!(r.verdict("curl -s http://localhost:3000/"), Verdict::Allowed);
    }

    #[test]
    fn unknown_when_a_part_is_not_covered_hidden_unreadable_or_empty() {
        let r = rules();
        // A part no rule covers, a shorter command, a word that only shares a prefix.
        assert_eq!(r.verdict("ls && npm install"), Verdict::Unknown);
        assert_eq!(r.verdict("git"), Verdict::Unknown);
        assert_eq!(r.verdict("lsof -i :3000"), Verdict::Unknown);
        assert_eq!(r.verdict("npm testing"), Verdict::Unknown);
        assert_eq!(r.verdict("git fetch"), Verdict::Unknown); // the chain rule is exact
        assert_eq!(r.verdict("git fetch && git rebase -i"), Verdict::Unknown);
        // A hidden command, an unreadable line, an empty one.
        assert_eq!(r.verdict("ls $(rm -rf ~)"), Verdict::Unknown);
        assert_eq!(r.verdict("ls `whoami`"), Verdict::Unknown);
        assert_eq!(r.verdict("ls 'open"), Verdict::Unknown);
        assert_eq!(r.verdict(""), Verdict::Unknown);
        assert_eq!(r.verdict(" ; "), Verdict::Unknown);
        // Empty rules match nothing.
        assert_eq!(AgyRules::new(&[""], &[]).verdict("anything"), Verdict::Unknown);
    }

    #[test]
    fn denied_when_any_part_is_covered_by_a_deny_rule() {
        let r = rules();
        assert_eq!(r.verdict("rm -rf build"), Verdict::Denied);
        assert_eq!(r.verdict("git status && git push origin main"), Verdict::Denied);
        assert_eq!(r.verdict("rm build"), Verdict::Unknown);
    }

    #[test]
    fn a_rule_with_a_substitution_only_matches_that_exact_command() {
        let exact = AgyRules::new(&["TOKEN=$(gcloud auth print-access-token) terraform apply"], &[]);
        assert_eq!(exact.verdict("TOKEN=$(gcloud auth print-access-token) terraform apply"), Verdict::Allowed);
        assert_eq!(
            exact.verdict("TOKEN=$(gcloud auth print-access-token) terraform apply -auto-approve"),
            Verdict::Unknown
        );
    }

    #[test]
    fn grants_objects_give_their_allow_and_deny_lists() {
        let mut added = AgyRules::default();
        added.add_grants(&json!({ "allow": ["command(make)", "mcp(a/b)"], "deny": ["command(sudo)"], "ask": ["command(x)"] }));
        assert_eq!(added, AgyRules::new(&["make"], &["sudo"]));
        added.add_grants(&json!({ "allow": "not a list" }));
        assert_eq!(added, AgyRules::new(&["make"], &["sudo"]));
        // Like Swift's `as? [String]`: a list with anything but strings is no list.
        added.add_grants(&json!({ "allow": ["command(a)", 3] }));
        assert_eq!(added, AgyRules::new(&["make"], &["sudo"]));
    }

    #[test]
    fn project_folders_are_plain_and_git_folders_percent_decoded() {
        let project = json!({ "projectResources": { "resources": [
            { "folderUri": "file:///Users/me/My%20App" },
            { "gitFolder": { "folderUri": "file:///Users/me/repo", "defaultBranch": "main" } },
            { "folderUri": "https://example.com/x" },
        ]}});
        assert_eq!(project_folders(&project), vec!["/Users/me/My App", "/Users/me/repo"]);
        assert!(folder_contains("/Users/me/repo", "/Users/me/repo"));
        assert!(folder_contains("/Users/me/repo", "/Users/me/repo/sub/dir"));
        assert!(folder_contains("/Users/me/repo/", "/Users/me/repo/sub"));
        assert!(!folder_contains("/Users/me/repo", "/Users/me/repo-2"));
        assert!(!folder_contains("/", "/Users/me"));
        assert!(!folder_contains("", "/Users/me"));
    }

    #[test]
    fn windows_folders_match_a_windows_working_directory() {
        assert_eq!(file_uri_path("file:///c%3A/Users/me/My%20App").as_deref(), Some("c:/Users/me/My App"));
        assert_eq!(file_uri_path("file:///C:/work/app").as_deref(), Some("C:/work/app"));
        assert_eq!(file_uri_path("file://server/share/app").as_deref(), Some("//server/share/app"));
        assert_eq!(file_uri_path("vscode-remote://wsl+Ubuntu/home/me"), None);
        assert!(folder_contains("c:/Users/me/My App", r"C:\Users\me\My App\src"));
        assert!(folder_contains("c:/Users/me/repo", r"C:\Users\me\repo"));
        assert!(!folder_contains("c:/Users/me/repo", r"C:\Users\me\repo-2"));
        assert!(!folder_contains("c:/", r"C:\Users\me"));
        assert!(!folder_contains("C:", r"C:\Users\me"));
        assert!(folder_contains("//server/share/app", r"\\server\share\app\x"));
        // Linux paths keep their case.
        assert!(!folder_contains("/home/me/App", "/home/me/app"));
    }

    #[test]
    fn current_files_nest_the_grants_twice_older_ones_once() {
        let current = project_grants(&json!({ "permissionGrants": { "permissionGrants": { "allow": ["command(a)"] } } }));
        assert_eq!(current["allow"], json!(["command(a)"]));
        let older = project_grants(&json!({ "permissionGrants": { "allow": ["command(b)"] } }));
        assert_eq!(older["allow"], json!(["command(b)"]));
    }

    #[test]
    fn rules_load_from_a_home_folder_laid_out_like_antigravitys() {
        let home = std::env::temp_dir().join(format!(
            "coucou-agy-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let gemini = home.join(".gemini");
        write(
            &gemini.join("antigravity-cli/settings.json"),
            r#"{"permissions":{"allow":["command(ls)"],"deny":["command(rm -rf)"]}}"#,
        );
        write(
            &gemini.join("config/config.json"),
            r#"{"userSettings":{"globalPermissionGrants":{"allow":["command(git status)"]}}}"#,
        );
        write(
            &gemini.join("config/projects/p1.json"),
            r#"{"projectResources":{"resources":[{"folderUri":"file:///work/app"}]},"permissionGrants":{"permissionGrants":{"allow":["command(npm test)"]}}}"#,
        );
        write(
            &gemini.join("config/projects/p2.json"),
            r#"{"projectResources":{"resources":[{"folderUri":"file:///work/other"}]},"permissionGrants":{"permissionGrants":{"allow":["command(make)"]}}}"#,
        );
        write(
            &gemini.join("config/projects/outside-of-project.json"),
            r#"{"permissionGrants":{"permissionGrants":{"allow":["command(cat)"]}}}"#,
        );
        write(&gemini.join("config/projects/broken.json"), "not json");

        let in_app = AgyRules::load(&home, "/work/app/src");
        assert_eq!(in_app, AgyRules::new(&["ls", "git status", "npm test"], &["rm -rf"]));
        assert_eq!(in_app.verdict("npm test"), Verdict::Allowed);
        assert_eq!(in_app.verdict("make"), Verdict::Unknown); // another project's grant
        assert_eq!(in_app.verdict("rm -rf /tmp/x"), Verdict::Denied);
        let outside = AgyRules::load(&home, "/elsewhere");
        assert_eq!(outside, AgyRules::new(&["ls", "git status", "cat"], &["rm -rf"]));
        // No Antigravity files at all: no rules, every command is unknown.
        let empty = AgyRules::load(&home.join("nobody"), "/work/app");
        assert_eq!(empty, AgyRules::default());
        assert_eq!(empty.verdict("ls"), Verdict::Unknown);
        let _ = std::fs::remove_dir_all(&home);
    }
}
