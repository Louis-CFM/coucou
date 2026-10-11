use std::collections::HashMap;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::models::{MCPServerConfig, MCPServerSource, MCPTransport};

/// Normalises template strings like ~/path, ${userHome}, ${env:VAR}, {env:VAR}, ${VAR}, and ${VAR:-fallback}.
pub fn normalise_value(raw: &str, home: &str, env: &HashMap<String, String>) -> String {
    let mut s = raw.to_string();
    if s.starts_with("~/") {
        s = format!("{home}/{}", &s[2..]);
    }
    s = s.replace("${userHome}", home);

    // Expand ${env:VAR} or {env:VAR} -> ${VAR}
    let mut replaced = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '$' && chars.peek() == Some(&'{') {
            chars.next();
            let mut inner = String::new();
            while let Some(&in_c) = chars.peek() {
                if in_c == '}' {
                    chars.next();
                    break;
                }
                inner.push(chars.next().unwrap());
            }
            if let Some(rest) = inner.strip_prefix("env:") {
                replaced.push_str(&format!("${{{rest}}}"));
            } else {
                replaced.push_str(&format!("${{{inner}}}"));
            }
        } else if c == '{' {
            let mut inner = String::new();
            let mut matched = false;
            while let Some(&in_c) = chars.peek() {
                if in_c == '}' {
                    chars.next();
                    matched = true;
                    break;
                }
                inner.push(chars.next().unwrap());
            }
            if matched && inner.starts_with("env:") {
                let rest = &inner["env:".len()..];
                replaced.push_str(&format!("${{{rest}}}"));
            } else {
                replaced.push('{');
                replaced.push_str(&inner);
                if matched {
                    replaced.push('}');
                }
            }
        } else {
            replaced.push(c);
        }
    }
    s = replaced;

    // Resolve ${VAR:-default} and ${VAR}
    let mut out = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '$' && chars.peek() == Some(&'{') {
            chars.next();
            let mut inner = String::new();
            while let Some(&in_c) = chars.peek() {
                if in_c == '}' {
                    chars.next();
                    break;
                }
                inner.push(chars.next().unwrap());
            }
            if let Some((var_name, fallback)) = inner.split_once(":-") {
                let val = env.get(var_name).map(String::as_str).unwrap_or(fallback);
                out.push_str(val);
            } else if let Some(val) = env.get(&inner) {
                out.push_str(val);
            }
        } else {
            out.push(c);
        }
    }
    out
}

pub struct CandidatePath {
    pub path: PathBuf,
    pub source: MCPServerSource,
}

/// Standard configuration file locations across Windows and Linux.
pub fn candidate_paths(home: &str) -> Vec<CandidatePath> {
    let mut paths = Vec::new();
    let home_path = Path::new(home);

    #[cfg(windows)]
    {
        if let Ok(appdata) = std::env::var("APPDATA") {
            let appdata_p = Path::new(&appdata);
            paths.push(CandidatePath {
                path: appdata_p.join("Claude").join("claude_desktop_config.json"),
                source: MCPServerSource::ClaudeDesktop,
            });
            paths.push(CandidatePath {
                path: appdata_p.join("Code").join("User").join("mcp.json"),
                source: MCPServerSource::Vscode,
            });
            paths.push(CandidatePath {
                path: appdata_p.join("opencode").join("opencode.json"),
                source: MCPServerSource::Opencode,
            });
        }
    }

    #[cfg(target_os = "linux")]
    {
        let config_dir = std::env::var("XDG_CONFIG_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|_| home_path.join(".config"));

        paths.push(CandidatePath {
            path: config_dir.join("Claude").join("claude_desktop_config.json"),
            source: MCPServerSource::ClaudeDesktop,
        });
        paths.push(CandidatePath {
            path: config_dir.join("Code").join("User").join("mcp.json"),
            source: MCPServerSource::Vscode,
        });
        paths.push(CandidatePath {
            path: config_dir.join("opencode").join("opencode.json"),
            source: MCPServerSource::Opencode,
        });
    }

    // Common portable/user paths across both systems
    paths.push(CandidatePath {
        path: home_path.join(".claude.json"),
        source: MCPServerSource::ClaudeCode,
    });
    paths.push(CandidatePath {
        path: home_path.join(".cursor").join("mcp.json"),
        source: MCPServerSource::Cursor,
    });

    paths
}

/// Parses standard `mcpServers` format (used by Claude Desktop, Claude Code, Cursor, Windsurf).
pub fn parse_standard_servers(data: &[u8], source: &MCPServerSource, home: &str, env: &HashMap<String, String>) -> Vec<MCPServerConfig> {
    let Ok(json) = serde_json::from_slice::<Value>(data) else {
        return Vec::new();
    };
    let mut result = Vec::new();

    if let Some(servers) = json.get("mcpServers").and_then(Value::as_object) {
        result.extend(parse_server_dict(servers, source, home, env));
    }
    if let Some(projects) = json.get("projects").and_then(Value::as_object) {
        for proj in projects.values() {
            if let Some(servers) = proj.get("mcpServers").and_then(Value::as_object) {
                result.extend(parse_server_dict(servers, source, home, env));
            }
        }
    }
    result
}

/// Parses VS Code format (`servers` or `mcpServers`).
pub fn parse_vscode_servers(data: &[u8], home: &str, env: &HashMap<String, String>) -> Vec<MCPServerConfig> {
    let Ok(json) = serde_json::from_slice::<Value>(data) else {
        return Vec::new();
    };
    let mut result = Vec::new();

    if let Some(servers) = json.get("servers").and_then(Value::as_object) {
        result.extend(parse_server_dict(servers, &MCPServerSource::Vscode, home, env));
    }
    if let Some(servers) = json.get("mcpServers").and_then(Value::as_object) {
        result.extend(parse_server_dict(servers, &MCPServerSource::Vscode, home, env));
    }
    result
}

fn parse_server_dict(
    dict: &serde_json::Map<String, Value>,
    source: &MCPServerSource,
    home: &str,
    env: &HashMap<String, String>,
) -> Vec<MCPServerConfig> {
    let mut result = Vec::new();
    let mut keys: Vec<&String> = dict.keys().collect();
    keys.sort();

    for name in keys {
        let Some(server_obj) = dict.get(name).and_then(Value::as_object) else {
            continue;
        };

        if let Some(url_val) = server_obj.get("url").and_then(Value::as_str) {
            let norm_url = normalise_value(url_val, home, env);
            let mut headers = HashMap::new();
            if let Some(h_obj) = server_obj.get("headers").and_then(Value::as_object) {
                for (k, v) in h_obj {
                    if let Some(vs) = v.as_str() {
                        headers.insert(k.clone(), normalise_value(vs, home, env));
                    }
                }
            }
            let is_sse = norm_url.to_ascii_lowercase().ends_with("/sse");
            let mut notes = Vec::new();
            if is_sse {
                notes.push("Legacy SSE transport is deprecated; streamable HTTP POST is recommended.".into());
            }

            result.push(MCPServerConfig {
                id: name.to_ascii_lowercase().replace(' ', "-"),
                name: name.clone(),
                sources: vec![source.clone()],
                transport: MCPTransport::Http { url: norm_url, headers },
                is_enabled: !is_sse,
                notes,
            });
            continue;
        }

        let Some(cmd_val) = server_obj.get("command").and_then(Value::as_str) else {
            continue;
        };
        let command = normalise_value(cmd_val, home, env);
        let args = server_obj
            .get("args")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(Value::as_str)
                    .map(|a| normalise_value(a, home, env))
                    .collect()
            })
            .unwrap_or_default();

        let mut env_map = HashMap::new();
        if let Some(env_obj) = server_obj.get("env").and_then(Value::as_object) {
            for (k, v) in env_obj {
                if let Some(vs) = v.as_str() {
                    env_map.insert(k.clone(), normalise_value(vs, home, env));
                }
            }
        }

        result.push(MCPServerConfig {
            id: name.to_ascii_lowercase().replace(' ', "-"),
            name: name.clone(),
            sources: vec![source.clone()],
            transport: MCPTransport::Stdio { command, args, env: env_map },
            is_enabled: true,
            notes: Vec::new(),
        });
    }
    result
}

/// Deduplicates discovered servers by command/args or URL.
pub fn deduplicate(servers: Vec<MCPServerConfig>) -> Vec<MCPServerConfig> {
    let mut merged: HashMap<String, MCPServerConfig> = HashMap::new();
    let mut order = Vec::new();

    for server in servers {
        let fp = match &server.transport {
            MCPTransport::Stdio { command, args, .. } => format!("stdio:{}:{}", command, args.join(" ")),
            MCPTransport::Http { url, .. } => format!("http:{url}"),
        };

        if let Some(existing) = merged.get_mut(&fp) {
            for s in server.sources {
                if !existing.sources.contains(&s) {
                    existing.sources.push(s);
                }
            }
        } else {
            merged.insert(fp.clone(), server);
            order.push(fp);
        }
    }

    order.into_iter().filter_map(|fp| merged.remove(&fp)).collect()
}

/// Scans standard directories and returns discovered MCP servers.
pub fn scan_all() -> Vec<MCPServerConfig> {
    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_default();
    let env_map: HashMap<String, String> = std::env::vars().collect();

    let candidates = candidate_paths(&home);
    let mut found = Vec::new();

    for candidate in candidates {
        let Ok(data) = std::fs::read(&candidate.path) else {
            continue;
        };
        match candidate.source {
            MCPServerSource::Vscode => {
                found.extend(parse_vscode_servers(&data, &home, &env_map));
            }
            _ => {
                found.extend(parse_standard_servers(&data, &candidate.source, &home, &env_map));
            }
        }
    }

    deduplicate(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalise_tokens() {
        let mut env = HashMap::new();
        env.insert("API_KEY".into(), "secret123".into());
        env.insert("PORT".into(), "8080".into());

        assert_eq!(
            normalise_value("~/dev", "/home/user", &env),
            "/home/user/dev"
        );
        assert_eq!(
            normalise_value("${env:API_KEY}", "/home/user", &env),
            "secret123"
        );
        assert_eq!(
            normalise_value("{env:API_KEY}", "/home/user", &env),
            "secret123"
        );
        assert_eq!(
            normalise_value("${HOST:-localhost}", "/home/user", &env),
            "localhost"
        );
        assert_eq!(
            normalise_value("${PORT:-3000}", "/home/user", &env),
            "8080"
        );
    }

    #[test]
    fn parse_and_deduplicate() {
        let raw = br#"{
            "mcpServers": {
                "sqlite": {
                    "command": "uvx",
                    "args": ["mcp-server-sqlite", "--db-path", "~/test.db"]
                },
                "remote": {
                    "url": "http://127.0.0.1:8000/mcp"
                }
            }
        }"#;
        let env = HashMap::new();
        let servers = parse_standard_servers(raw, &MCPServerSource::ClaudeDesktop, "/home/user", &env);
        assert_eq!(servers.len(), 2);
        let deduped = deduplicate(servers);
        assert_eq!(deduped.len(), 2);
        assert_eq!(deduped[0].id, "remote");
        assert_eq!(deduped[1].id, "sqlite");
    }
}
