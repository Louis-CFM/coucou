#!/usr/bin/env bash
# Checks the Mac app's String Catalog (NotchBuddy/Resources/Localizable.xcstrings):
#  - every text the code can show (see scripts/extract-strings.py) is a key of the catalog;
#  - every such key has a pt-BR value (plain, or one per plural case), unless the catalog marks it
#    shouldTranslate = false;
#  - every pt-BR value keeps the format placeholders of its reference text: the `en` value when the key has one
#    (dotted keys such as voice.pill-added, whose key has no placeholder), the key itself otherwise. Flags and
#    width count as part of a placeholder (%02lld);
#  - the other 8 languages (ar bn es fr hi id ru zh-Hans, translated upstream): a key has all of them or
#    none (the fork's own screens are pt-BR only and fall back to English); a key that has them has an
#    `en` value too (dotted keys such as plan.waiting) and keeps its placeholders;
#  - the extractor finds the String(localized:) / SwiftUI keys it is supposed to (sanity check).
# Needs only python3.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/extract-strings.py --json > "${TMPDIR:-/tmp}/coucou-extracted-keys.json"

python3 - "${TMPDIR:-/tmp}/coucou-extracted-keys.json" <<'PY'
import json, os, re, sys

CATALOG = os.environ.get("LOCALIZATION_CATALOG", "NotchBuddy/Resources/Localizable.xcstrings")
extracted = json.load(open(sys.argv[1], encoding="utf-8"))
catalog = json.load(open(CATALOG, encoding="utf-8"))
strings = catalog["strings"]
failures = []

def norm(key):
    """Compares keys whatever the guessed placeholder type: %@, %lld, %d... all become %#."""
    key = key.replace("%%", "%")
    return re.sub(r"%(?:\d+\$)?(?:l{0,2}|h{0,2})[@dDiufsS]", "%#", key)

def placeholders(text):
    """Conversion letters of the placeholders, positional or not, ignoring %%."""
    text = text.replace("%%", "")
    return sorted(m.group(1) for m in re.finditer(r"%(?:\d+\$)?[-+ #0]*\d*(?:\.\d+)?(?:l{0,2}|h{0,2})([@dDiufsS])", text))

def reference(cat_key, entry):
    """Text the placeholders of every translation are compared with: the en value, else the key."""
    en = units(entry, "en")
    return en[0]["value"] if en and en[0].get("value") else cat_key

OTHER_LANGS = ["ar", "bn", "es", "fr", "hi", "id", "ru", "zh-Hans"]

def units(entry, lang):
    """Translation units of a language: one stringUnit, or one per plural case. [] when absent."""
    loc = entry.get("localizations", {}).get(lang)
    if not loc:
        return []
    if "stringUnit" in loc:
        return [loc["stringUnit"]]
    plural = loc.get("variations", {}).get("plural", {})
    return [case["stringUnit"] for case in plural.values() if "stringUnit" in case]

def has_letters(key):
    return re.search(r"[A-Za-z]", re.sub(r"%(?:\d+\$)?(?:l{0,2}|h{0,2})[@dDiufsS]", "", key)) is not None

check = lambda ok, msg: print(("  ok  " if ok else "  FAIL ") + msg) or (None if ok else failures.append(msg))

print("catalog")
check(catalog.get("sourceLanguage") == "en", "source language is en")
by_norm = {}
for key in strings:
    by_norm.setdefault(norm(key), []).append(key)

def lookup(key):
    if key in strings:
        return key
    candidates = by_norm.get(norm(key), [])
    return candidates[0] if candidates else None

used = {}
for key, where in extracted.items():
    cat_key = lookup(key)
    if cat_key is None:
        # texts without letters (numbers, symbols, "%@/%@") need no entry
        if has_letters(key):
            failures.append("missing from the catalog: %r (%s)" % (key, where[0]))
        continue
    used[cat_key] = where[0]

missing_pt = []
lost_placeholders = []
for cat_key, where in sorted(used.items()):
    entry = strings[cat_key]
    if entry.get("shouldTranslate") is False:
        continue
    pt_units = units(entry, "pt-BR")
    if not pt_units or any(not u.get("value") or u.get("state") != "translated" for u in pt_units):
        missing_pt.append((cat_key, where))
        continue
    for u in pt_units:
        if placeholders(u["value"]) != placeholders(reference(cat_key, entry)):
            lost_placeholders.append((cat_key, u["value"], where))
            break

# a status text is told apart by its leading symbol (the Settings status bar colors "❌" in red): keep it
for cat_key, entry in strings.items():
    for u in units(entry, "pt-BR"):
        value = u.get("value")
        if value and cat_key[:1] in "❌✓" and value[:1] != cat_key[:1]:
            failures.append("pt-BR value loses the leading symbol: %r -> %r" % (cat_key, value))

# every catalog entry with a translation must also keep its placeholders (used or not)
for cat_key, entry in strings.items():
    for u in units(entry, "pt-BR"):
        value = u.get("value")
        if value and placeholders(value) != placeholders(reference(cat_key, entry)) and not any(cat_key == k for k, _, _ in lost_placeholders):
            lost_placeholders.append((cat_key, value, "catalog"))

# the other 8 languages: all or none, placeholders kept, `en` present
fork_only = 0
for cat_key, entry in strings.items():
    present = [lang for lang in OTHER_LANGS if units(entry, lang)]
    if not present:
        if entry.get("shouldTranslate") is not False:
            fork_only += 1
        continue
    if len(present) != len(OTHER_LANGS):
        failures.append("partly translated, missing %s: %r" % (", ".join(l for l in OTHER_LANGS if l not in present), cat_key))
    if not units(entry, "en"):
        failures.append("translated key without an en value: %r" % cat_key)
    for lang in present:
        for u in units(entry, lang):
            if u.get("state") == "translated" and placeholders(u.get("value", "")) != placeholders(reference(cat_key, entry)):
                failures.append("%s value changes the placeholders: %r -> %r" % (lang, cat_key, u.get("value")))
                break

print("keys")
print("  catalog keys:            %d" % len(strings))
print("  keys found in the code:  %d" % len(extracted))
print("  of which with a letter:  %d" % sum(1 for k in extracted if has_letters(k)))
print("  keys without pt-BR:      %d" % len(missing_pt))
print("  placeholder mismatches:  %d" % len(lost_placeholders))
print("  note: %d keys have pt-BR only (the fork's own screens; the other 8 languages fall back to English)" % fork_only)
unused = sorted(k for k in strings if k not in used)
if unused:
    print("  note: %d catalog keys are not found by the extractor (compiler-only forms are fine): %s"
          % (len(unused), ", ".join(repr(k) for k in unused[:6]) + (" ..." if len(unused) > 6 else "")))

for key, where in missing_pt:
    failures.append("no pt-BR value: %r (%s)" % (key, where))
for key, value, where in lost_placeholders:
    failures.append("pt-BR value changes the placeholders: %r -> %r (%s)" % (key, value, where))

# Shipped keys the Hermes approval card shares with the app on main: they must keep the languages (and the extraction state)
# they ship with, so a new screen cannot rename a shipped text by adding translations to its key. A comparison with main
# itself is not possible here (CI runs from a checkout). The card's own words have their own keys ("Scope: ...").
ALL_LANGS = ["ar", "bn", "en", "es", "fr", "hi", "id", "pt-BR", "ru", "zh-Hans"]
SHIPPED_PINS = {
    "Allow": ALL_LANGS, "Deny": ALL_LANGS, "Always": ALL_LANGS, "needs permission": ALL_LANGS,
    "Session": ["pt-BR"],   # the fallback name of a session pill and a text sent to the iPhone: pt-BR only on main
}
print("shipped keys the card relies on")
for key, langs in SHIPPED_PINS.items():
    entry = strings.get(key, {})
    have = sorted(entry.get("localizations", {}).keys())
    # Upstream keeps adding languages (16 now): a shipped key must keep at least the ones it shipped with.
    check(set(langs) <= set(have), "%r keeps its languages (%s)" % (key, ", ".join(langs) if len(langs) < 3 else "all 10"))
check(strings.get("Session", {}).get("extractionState") == "manual", "'Session' keeps extractionState manual")
check(strings["Session"]["localizations"]["pt-BR"]["stringUnit"]["value"] == "Sessão", "'Session' still reads 'Sessão' in pt-BR")
for scope in ("once", "session", "always"):
    entry = strings.get("Scope: " + scope, {})
    check(sorted(entry.get("localizations", {}).keys()) == sorted(ALL_LANGS), "'Scope: %s' (the selector word) has its own key in all 10 languages" % scope)
check("Once" not in strings, "no leftover 'Once' key")

# the extractor must see the forms the app relies on
for probe in ("Settings…", "Allow", "Language", "Open Coucou", "Connected · %@", "Hermes agents"):
    check(any(norm(k) == norm(probe) for k in extracted), "extractor finds %r" % probe)

# extractor behaviour on small synthetic sources
import importlib.util
spec = importlib.util.spec_from_file_location("extract_strings", "scripts/extract-strings.py")
ex = importlib.util.module_from_spec(spec); spec.loader.exec_module(ex)
def keys_of(src):
    return sorted(k for k, _ in ex.Scanner(src).scan())

print("extractor probes")
check("Uploading %@" in keys_of('Text("Uploading \\(state.file?.name ?? String(localized: "file"))")'),
      "keeps the outer key when an interpolation holds String(localized:)")
check(keys_of('Text(ok ? String(localized: "Yes") : "path/to")') == ["Yes"],
      "a String(localized:) at the argument level still disables extraction of the other literals")
check(keys_of('var advanceKey: LocalizedStringKey { isLast ? "Send" : "Next" }') == ["Next", "Send"],
      "extracts the literals of a LocalizedStringKey property")
check(keys_of('func title(_ n: Int) -> LocalizedStringKey {\n    n == 1 ? "One" : "Many"\n}') == ["Many", "One"],
      "extracts the literals of a function returning LocalizedStringKey")
check(keys_of('let k: LocalizedStringKey = "Constant"\nlet other = "not a key"') == ["Constant"],
      "extracts a LocalizedStringKey constant and ignores plain strings")
check(keys_of('var plain: String { "not a key" }') == [],
      "ignores a String property")
check(keys_of('String(localized: "\\(String(n)) items")') == ["%@ items"],
      "a number wrapped in String() is a %@ placeholder")
check(keys_of('Text(verbatim: "raw")') == [], "Text(verbatim:) is skipped")

if failures:
    print("\n%d failure(s):" % len(failures))
    for f in failures:
        print("  - " + f)
    sys.exit(1)
print("\nAll localization tests passed.")
PY
