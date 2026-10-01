// The few words that differ between the Windows and Linux builds. Everything
// else in the front end is the same on both.

export const IS_LINUX = navigator.userAgent.includes("Linux");

/** Where API keys live, as a sentence fragment. */
export const KEY_STORE = IS_LINUX ? "your system keyring" : "the Windows Credential Manager";

/** The relay's file name. */
export const HOOK_EXE = IS_LINUX ? "coucou-hook" : "coucou-hook.exe";
