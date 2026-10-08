// A Windows notification for a card that is waiting on you.
//
// The island opens itself and plays a sound, but a strip at the top of the
// screen is easy to miss when you are looking at something else - and for an
// agent that blocks (OpenCode's `permission.ask`, above all) "I never saw it"
// costs you the whole turn. So the card also says so, the way every other app
// on the PC asks for your attention.
//
// Best effort, always: a shell that says no, or Focus Assist that says no, must
// never disturb an agent. A failed notification is logged and dropped.

use tauri::{AppHandle, Runtime};

use crate::i18n::t;

/// The text a waiting card shows in the notification area.
fn waiting_body(agent: &str, tool: &str) -> String {
    if tool.is_empty() {
        format!("{agent} needs permission")
    } else {
        format!("{agent} needs permission - {tool}")
    }
}

#[cfg(windows)]
pub fn approval_waiting<R: Runtime>(app: &AppHandle<R>, agent: &str, tool: &str) {
    use tauri_plugin_notification::NotificationExt;

    let body = waiting_body(agent, tool);
    let title = t("Waiting for you in Coucou");
    if let Err(err) = app.notification().builder().title(title).body(&body).show() {
        crate::log::line(&format!("notify: {body} ({err})"));
        return;
    }
    crate::log::line(&format!("notify: {body}"));
}

/// Linux has its own island, its own sounds and its own notices; the card coming
/// up is the notice there, and the island already opens itself. Nothing to add.
#[cfg(not(windows))]
pub fn approval_waiting<R: Runtime>(_app: &AppHandle<R>, _agent: &str, _tool: &str) {}

#[cfg(test)]
mod tests {
    use super::waiting_body;

    /// No tool name (a question, say): the agent alone still says what is wanted.
    #[test]
    fn a_card_with_no_tool_still_says_what_is_wanted() {
        assert_eq!(waiting_body("OpenCode", ""), "OpenCode needs permission");
        assert_eq!(waiting_body("Claude Code", ""), "Claude Code needs permission");
    }

    /// With one: the tool is named, so the notification says what to look at.
    #[test]
    fn the_tool_is_named_when_there_is_one() {
        assert_eq!(waiting_body("OpenCode", "edit"), "OpenCode needs permission - edit");
    }
}