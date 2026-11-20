// Authoritative Windows System User Identity Service.
// Consolidates native Windows account detection, display name resolution,
// account name normalization, and sanitization for Flow Dictation & Mochi Companion.

use serde::{Deserialize, Serialize};

const MAX_NAME_CHARS: usize = 48;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct UserIdentity {
    pub windows_display_name: Option<String>,
    pub windows_account_name: Option<String>,
    pub detected_greeting_name: Option<String>,
    pub device_name: Option<String>,
    pub is_resolved: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub authoritative_greeting_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub identity_version: Option<String>,
}

static CACHED_IDENTITY: std::sync::RwLock<Option<UserIdentity>> = std::sync::RwLock::new(None);

/// The authoritative Windows system user identity, resolved and cached.
pub fn detect() -> UserIdentity {
    if let Ok(guard) = CACHED_IDENTITY.read() {
        if let Some(ref id) = *guard {
            return id.clone();
        }
    }
    refresh()
}

/// Forces a fresh resolution of the native Windows user identity.
pub fn refresh() -> UserIdentity {
    let fresh = resolve_native_identity();
    if let Ok(mut guard) = CACHED_IDENTITY.write() {
        *guard = Some(fresh.clone());
    }
    fresh
}

/// The detected greeting name (e.g. "Madhan", "Alex", "Sarah"), if available.
pub fn greeting_name() -> Option<String> {
    detect().detected_greeting_name
}

/// The device / computer name (e.g. "WORKSTATION", "WORK-PC").
#[allow(dead_code)]
pub fn device_name() -> Option<String> {
    detect().device_name
}

/// Backward-compatible alias for greeting_name.
pub fn first_name() -> Option<String> {
    greeting_name()
}

fn calculate_identity_hash(display: &str, account: &str, device: &str) -> u64 {
    let mut hash: u64 = 0xcbf29ce484222325;
    for byte in format!("{display}|{account}|{device}").bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }
    hash
}

fn resolve_native_identity() -> UserIdentity {
    let display_name = crate::platform::user_full_name()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let account_name = std::env::var("USERNAME")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    let device = std::env::var("COMPUTERNAME")
        .or_else(|_| std::env::var("HOSTNAME"))
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());

    // Priority 2: Windows account display name
    let mut greeting = display_name.as_deref().and_then(first_name_from_display);

    // Priority 3: Windows account username fallback
    if greeting.is_none() {
        if let Some(acc) = account_name.as_deref() {
            greeting = first_name_from_account(acc);
        }
    }

    // Safety check: ensure greeting doesn't match the device/computer name
    if let (Some(g), Some(d)) = (&greeting, &device) {
        if g.eq_ignore_ascii_case(d) {
            greeting = None;
        }
    }

    let is_resolved = greeting.is_some() || display_name.is_some() || account_name.is_some();
    let auth_greeting = greeting.clone();
    let id_version = format!(
        "{:x}",
        calculate_identity_hash(
            display_name.as_deref().unwrap_or(""),
            account_name.as_deref().unwrap_or(""),
            device.as_deref().unwrap_or(""),
        )
    );

    UserIdentity {
        windows_display_name: display_name,
        windows_account_name: account_name,
        detected_greeting_name: greeting,
        device_name: device,
        is_resolved,
        authoritative_greeting_name: auth_greeting,
        identity_version: Some(id_version),
    }
}

/// Checks if a token matches a common honorific / academic title.
fn is_honorific(token: &str) -> bool {
    let lower = token.trim_end_matches('.').trim().to_lowercase();
    matches!(
        lower.as_str(),
        "dr" | "mr" | "mrs" | "ms" | "prof" | "sir" | "rev" | "lord" | "lady"
    )
}

/// Prohibited machine, system, generic accounts, or hardware identifiers.
/// Principled separation: rejects OS accounts and placeholders, never legitimate human names.
fn is_prohibited_name(name: &str) -> bool {
    let lower = name.trim().to_lowercase();
    matches!(
        lower.as_str(),
        "administrator"
            | "admin"
            | "guest"
            | "default"
            | "defaultuser0"
            | "public"
            | "system"
            | "wdagutilityaccount"
            | "desktop"
            | "laptop"
            | "pc"
            | "computer"
            | "owner"
            | "user"
            | "root"
            | "local"
            | "test"
            | "temp"
            | "coucou"
            | "home"
            | "work"
            | "office"
            | "dr"
            | "mr"
            | "mrs"
            | "ms"
            | "prof"
            | "sir"
    ) || lower.ends_with(" pc")
        || lower.ends_with("-pc")
        || lower.ends_with("_pc")
        || lower.starts_with("desktop-")
        || lower.starts_with("laptop-")
}

fn is_name_char(c: char) -> bool {
    c.is_alphabetic() || c == '\'' || c == '-'
}

/// Capitalizes the first character of a name (supporting Unicode characters).
fn capitalize_name(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        None => String::new(),
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
    }
}

/// Extracts and validates first name from display name
/// (e.g. "Madhan Kumar" -> "Madhan", "Alex Johnson" -> "Alex", "Anne-Marie Smith" -> "Anne-Marie", "José García" -> "José").
pub fn first_name_from_display(full_name: &str) -> Option<String> {
    let full = full_name.trim();
    if full.is_empty() || full.chars().count() > MAX_NAME_CHARS || is_prohibited_name(full) {
        return None;
    }

    // Strip corporate tags / suffixes in parentheses or brackets (e.g. "David Miller (Contractor)" -> "David Miller")
    let unbracketed = if let Some(idx) = full.find(|c| c == '(' || c == '[') {
        full[..idx].trim()
    } else {
        full
    };
    if unbracketed.is_empty() {
        return None;
    }

    // Handle "Last, First" format if applicable (e.g. "Smith, John" -> "John")
    let candidate_str = if let Some((last, first)) = unbracketed.split_once(',') {
        if !first.trim().is_empty() && !last.trim().is_empty() {
            first.trim()
        } else {
            unbracketed
        }
    } else {
        unbracketed
    };

    // Iterate through whitespace tokens, skipping any leading honorifics/titles
    let mut tokens = candidate_str.split_whitespace();
    let mut selected_token = None;

    while let Some(tok) = tokens.next() {
        if is_honorific(tok) {
            continue; // Skip honorific ("Dr.", "Mr.", "Prof.", etc.)
        }
        selected_token = Some(tok);
        break;
    }

    let cleaned = selected_token?.trim();
    if cleaned.chars().count() < 2 || cleaned.chars().count() > 32 {
        return None;
    }

    if !cleaned.chars().all(is_name_char) {
        return None;
    }

    if is_prohibited_name(cleaned) {
        return None;
    }

    Some(capitalize_name(cleaned))
}

/// Extracts a friendly greeting name from a technical Windows account username
/// (e.g. "madhan.k" -> "Madhan", "sarah_smith" -> "Sarah", "alex2" -> "Alex", "john@corp.com" -> "John").
pub fn first_name_from_account(account: &str) -> Option<String> {
    let acc = account.trim();
    if acc.is_empty() || is_prohibited_name(acc) {
        return None;
    }

    // Strip email domain if present
    let raw = acc.split('@').next().unwrap_or(acc);

    // Take first token before dot or underscore if present
    let token = raw.split(['.', '_', '-']).next().unwrap_or(raw).trim();

    // Strip trailing digits if length >= 3 (e.g. "alex2" -> "alex")
    let letters: String = token.trim_end_matches(|c: char| c.is_ascii_digit()).to_string();

    if letters.chars().count() < 2 || letters.chars().count() > 24 {
        return None;
    }

    if !letters.chars().all(is_name_char) {
        return None;
    }

    if is_prohibited_name(&letters) {
        return None;
    }

    Some(capitalize_name(&letters))
}

/// Backward compatibility function
#[allow(dead_code)]
pub fn first_name_from(full_name: &str) -> Option<String> {
    first_name_from_display(full_name)
}

#[tauri::command]
pub fn get_user_identity() -> UserIdentity {
    detect().clone()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn display_names_extract_clean_first_names() {
        assert_eq!(first_name_from_display("Théodore Riant").as_deref(), Some("Théodore"));
        assert_eq!(first_name_from_display("  Louis Raille ").as_deref(), Some("Louis"));
        assert_eq!(first_name_from_display("Jean-Luc Picard").as_deref(), Some("Jean-Luc"));
        assert_eq!(first_name_from_display("O'Brien Miles").as_deref(), Some("O'Brien"));
        assert_eq!(first_name_from_display("Louis").as_deref(), Some("Louis"));
        assert_eq!(first_name_from_display("Zoë").as_deref(), Some("Zoë"));
        assert_eq!(first_name_from_display("Madhan Kumar").as_deref(), Some("Madhan"));
        assert_eq!(first_name_from_display("Alex Johnson").as_deref(), Some("Alex"));
        assert_eq!(first_name_from_display("Sarah").as_deref(), Some("Sarah"));
        assert_eq!(first_name_from_display("José García").as_deref(), Some("José"));
        assert_eq!(first_name_from_display("Wei Zhang").as_deref(), Some("Wei"));
        assert_eq!(first_name_from_display("Anne-Marie Smith").as_deref(), Some("Anne-Marie"));
        // Lowercase single name should be cleanly capitalized
        assert_eq!(first_name_from_display("alex").as_deref(), Some("Alex"));
        assert_eq!(first_name_from_display("sarah").as_deref(), Some("Sarah"));
        // Honorific stripping
        assert_eq!(first_name_from_display("Dr. Sarah Chen").as_deref(), Some("Sarah"));
        assert_eq!(first_name_from_display("Prof. Robert Lang").as_deref(), Some("Robert"));
        assert_eq!(first_name_from_display("Sir Arthur Conan").as_deref(), Some("Arthur"));
        // Corporate tags stripping
        assert_eq!(first_name_from_display("Alex Johnson (Contractor)").as_deref(), Some("Alex"));
        assert_eq!(first_name_from_display("Elena Rostova [CORP]").as_deref(), Some("Elena"));
        // "Last, First" Active Directory formatting with honorific
        assert_eq!(first_name_from_display("Chen, Dr. Sarah").as_deref(), Some("Sarah"));
        assert_eq!(first_name_from_display("Wright, Alexander").as_deref(), Some("Alexander"));
    }

    #[test]
    fn account_username_fallback_normalizes_correctly() {
        assert_eq!(first_name_from_account("madhan.k").as_deref(), Some("Madhan"));
        assert_eq!(first_name_from_account("sarah_smith").as_deref(), Some("Sarah"));
        assert_eq!(first_name_from_account("alex2").as_deref(), Some("Alex"));
        assert_eq!(first_name_from_account("john@company.com").as_deref(), Some("John"));
        assert_eq!(first_name_from_account("maria-clara").as_deref(), Some("Maria"));
    }

    #[test]
    fn prohibited_and_system_names_are_rejected() {
        for bad in [
            "",
            "   ",
            "Administrator",
            "admin",
            "Public",
            "Default",
            "defaultuser0",
            "System",
            "Desktop",
            "DESKTOP-XYZ",
            "Laptop-123",
            "Workstation PC",
            "User-PC",
            "R2-D2 Unit",
            "Dr.",
            "Mr.",
            "Sir",
        ] {
            assert_eq!(first_name_from_display(bad), None, "Should reject display: {bad}");
            assert_eq!(first_name_from_account(bad), None, "Should reject account: {bad}");
        }
    }

    #[test]
    fn identity_refresh_and_detect_contract() {
        let id1 = detect();
        let id2 = refresh();
        assert_eq!(id1.is_resolved, id2.is_resolved);
    }

    #[test]
    fn identity_concurrent_reads_during_refresh() {
        use std::thread;
        let mut handles = Vec::new();
        for _ in 0..8 {
            handles.push(thread::spawn(|| {
                for _ in 0..50 {
                    let id = detect();
                    assert!(id.identity_version.is_some());
                }
            }));
        }
        for _ in 0..2 {
            handles.push(thread::spawn(|| {
                for _ in 0..10 {
                    let id = refresh();
                    assert!(id.identity_version.is_some());
                }
            }));
        }
        for h in handles {
            h.join().unwrap();
        }
    }
}
