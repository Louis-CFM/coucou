// Interface language: English or Spanish.
//
// The choice lives in Settings.language, but views are built once at startup and
// a few labels are module-level constants, so both windows also cache it in
// localStorage and read it synchronously before anything renders. Changing the
// language reloads the windows (see main.ts and settings/main.ts).

export type Language = "en" | "es";

const STORAGE_KEY = "coucou.language";

/** The OS language, used until the user picks one in Settings. */
export function systemLanguage(): Language {
  return navigator.language.toLowerCase().startsWith("es") ? "es" : "en";
}

function cached(): Language | null {
  try {
    const v = localStorage.getItem(STORAGE_KEY);
    return v === "en" || v === "es" ? v : null;
  } catch {
    return null;
  }
}

let current: Language = cached() ?? systemLanguage();
document.documentElement.lang = current;

export function language(): Language {
  return current;
}

/**
 * Records the language from Settings. Returns true when it differs from the one
 * this window was rendered with — the caller then reloads to redraw.
 */
export function adoptLanguage(lang: string | undefined): boolean {
  const next: Language = lang === "es" || lang === "en" ? lang : systemLanguage();
  if (next === current) return false;
  try {
    localStorage.setItem(STORAGE_KEY, next);
  } catch {
    // Without storage a reload would come back in the old language and reload
    // again, forever. Stay as drawn; tr() still answers in the new language.
    current = next;
    return false;
  }
  current = next;
  return true;
}

/** English or Spanish, whichever the interface is in. */
export function tr(en: string, es: string): string {
  return current === "es" ? es : en;
}
