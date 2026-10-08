// The user's first name, for Mochi's system prompt — the same rules as
// UserIdentity.swift on the Mac. The full name comes from the OS account
// (platform::user_full_name); this file only decides whether it is something
// you would greet someone by.

use std::sync::OnceLock;

const MAX_FULL_NAME_CHARS: usize = 32;

/// Resolved once: the account name cannot change while the app runs.
pub fn first_name() -> Option<&'static str> {
    static NAME: OnceLock<Option<String>> = OnceLock::new();
    NAME.get_or_init(|| crate::platform::user_full_name().as_deref().and_then(first_name_from))
        .as_deref()
}

/// "Théodore Riant" gives "Théodore"; a login handle such as "theodoreriant"
/// or "t.riant2" gives nothing, because "Hey theodoreriant!" reads worse than
/// a greeting with no name at all.
pub fn first_name_from(full_name: &str) -> Option<String> {
    let full = full_name.trim();
    if full.is_empty() || full.chars().count() > MAX_FULL_NAME_CHARS || looks_like_login_handle(full) {
        return None;
    }
    let first = full.split(' ').find(|p| !p.is_empty())?;
    first.chars().all(is_name_part).then(|| first.to_string())
}

/// Where no full name is set the OS hands back the account name, so a single
/// lowercase word, or one carrying digits or separators, is taken as a handle.
fn looks_like_login_handle(name: &str) -> bool {
    if name.contains(' ') {
        return false;
    }
    name.to_lowercase() == name || name.chars().any(|c| c.is_numeric() || "._-@".contains(c))
}

fn is_name_part(c: char) -> bool {
    c.is_alphabetic() || c == '\'' || c == '-'
}

#[cfg(test)]
mod tests {
    use super::first_name_from;

    #[test]
    fn a_real_full_name_gives_its_first_word() {
        assert_eq!(first_name_from("Théodore Riant").as_deref(), Some("Théodore"));
        assert_eq!(first_name_from("  Louis Raille ").as_deref(), Some("Louis"));
        assert_eq!(first_name_from("Jean-Luc Picard").as_deref(), Some("Jean-Luc"));
        assert_eq!(first_name_from("O'Brien Miles").as_deref(), Some("O'Brien"));
        assert_eq!(first_name_from("Louis").as_deref(), Some("Louis"));
        assert_eq!(first_name_from("Zoë").as_deref(), Some("Zoë"));
    }

    #[test]
    fn login_handles_and_odd_names_give_nothing() {
        for name in ["", "   ", "theodoreriant", "t.riant2", "Louis2", "louis_r", "me@example", "Admin_01"] {
            assert_eq!(first_name_from(name), None, "{name}");
        }
        // A first word that is not a name.
        assert_eq!(first_name_from("R2-D2 Unit"), None);
        assert_eq!(first_name_from("Dr. Who"), None);
        // Too long to be a person's name.
        assert_eq!(first_name_from(&format!("Louis {}", "a".repeat(40))), None);
    }
}
