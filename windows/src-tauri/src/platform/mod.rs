// Everything that differs between operating systems, behind one set of names.
//
// The rest of the app calls `platform::…` and never touches Win32 or a Linux
// API directly. Each OS file exposes the same functions; the compiler picks one.

use std::path::PathBuf;

#[cfg(windows)]
mod windows;
#[cfg(windows)]
pub use self::windows::*;

#[cfg(target_os = "linux")]
mod linux;
#[cfg(target_os = "linux")]
pub use self::linux::*;
// "Open terminal" on Linux: the process tree from /proc, then KWin, EWMH, kitty.
#[cfg(target_os = "linux")]
mod linux_focus;
#[cfg(target_os = "linux")]
pub use self::linux_focus::{focus_session_window, process_ancestors, runs_in_terminal, window_owners};

/// Wall-clock time in the user's time zone, for log lines and backup names.
pub struct LocalTime {
    pub year: u32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    pub second: u32,
}

/// The user's home directory, where `.claude/settings.json` lives.
pub fn home_dir() -> PathBuf {
    std::env::var_os(HOME_VAR)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

/// How the desktop Mochi's window can be placed and clicked on this system.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum DesktopMode {
    /// Windows: placed anywhere, and a cursor poll drives click-through, the
    /// eyes and the drag, exactly like the island.
    Poll,
    /// Linux on X11: an ordinary window the window manager lets us place; the
    /// input region is the click-through and the page drives the drag.
    Window,
    /// Linux on a layer-shell compositor (KDE, COSMIC, wlroots): a layer
    /// surface anchored to the top-left corner of the island's display, placed
    /// with margins.
    Layer,
    /// Wayland without layer-shell (GNOME): no way to put a window where the
    /// user dropped it, so Mochi stays in the island.
    Off,
}

impl DesktopMode {
    pub fn as_str(self) -> &'static str {
        match self {
            DesktopMode::Poll => "poll",
            DesktopMode::Window => "window",
            DesktopMode::Layer => "layer",
            DesktopMode::Off => "off",
        }
    }

    /// The space a saved spot is measured in. A spot from another space (the
    /// same machine once on X11, once on Wayland) is not trusted.
    pub fn space(self) -> &'static str {
        match self {
            // Physical pixels of the whole desktop, as the OS reports monitors.
            DesktopMode::Poll | DesktopMode::Window => "screen",
            // Logical pixels from the top-left corner of the island's display.
            DesktopMode::Layer | DesktopMode::Off => "layer",
        }
    }
}

/// Which part of the desktop Mochi's window takes the mouse.
#[derive(Clone, Copy, PartialEq, Debug)]
#[cfg_attr(windows, allow(dead_code))]
pub enum MouseShape {
    /// Nothing: every click goes to what is underneath (during a flight).
    Empty,
    /// The whole window (while he is being dragged across the screen).
    Whole,
    /// A disc, in window-logical pixels: Mochi's body.
    Disc { cx: f64, cy: f64, r: f64 },
}
