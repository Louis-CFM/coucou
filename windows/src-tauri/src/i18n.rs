// Interface language for what Rust shows: the tray menu, the settings window
// title and error messages. Mirrors Settings.language ("en" or "es"); the
// webviews have their own copy in src/core/i18n.ts.

use std::sync::atomic::{AtomicBool, Ordering};

static SPANISH: AtomicBool = AtomicBool::new(false);

/// Records the language from Settings. Returns true when it changed.
pub fn set(language: &str) -> bool {
    let spanish = language == "es";
    SPANISH.swap(spanish, Ordering::Relaxed) != spanish
}

pub fn is_spanish() -> bool {
    SPANISH.load(Ordering::Relaxed)
}

/// English or Spanish, whichever the interface is in.
pub fn tr(en: &'static str, es: &'static str) -> &'static str {
    if is_spanish() { es } else { en }
}

/// `format!` in English or Spanish, whichever the interface is in.
macro_rules! trf {
    ($en:literal, $es:literal $(, $arg:expr)* $(,)?) => {
        if $crate::i18n::is_spanish() { format!($es $(, $arg)*) } else { format!($en $(, $arg)*) }
    };
}
pub(crate) use trf;
