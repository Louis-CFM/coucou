#!/usr/bin/env python3
"""Lists the localizable texts of the Mac app (candidate keys of Localizable.xcstrings).

xcodebuild does not fill a String Catalog by itself, so this script reads the Swift sources and
prints every literal that reaches the screen through a localizing API:

  - the first argument of Text, Button, Toggle, Picker, TextField, SecureField, GroupBox, Label,
    Section, Menu, Link, and of the project's own components (PrimaryButton, SecondaryButton, ...);
  - the title:/label: argument of the project's own components (SettingsSidebarRow, AgentWho,
    MailField, StatusBadge, ...);
  - the argument of the .help, .navigationTitle, .alert, .confirmationDialog modifiers;
  - every String(localized:) call, and the first argument of every NSLocalizedString( call (the menu bar).

Interpolations become format placeholders (\\(x) -> %@, or %lld when the expression is clearly an
integer). Text(verbatim:) is never localized and is skipped.

Usage:
  scripts/extract-strings.py          one "key<TAB>file:line" per line, sorted
  scripts/extract-strings.py --json   {key: [file:line, ...]} as JSON

Standard library only.
"""
import json
import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
SOURCE_DIRS = ["NotchBuddy/Sources/App", "NotchBuddy/Sources/CoucouKit"]

# Calls whose first argument is a localized key (SwiftUI initializers and the project's components).
CALLS = {
    "Text", "Button", "Toggle", "Picker", "TextField", "SecureField", "GroupBox", "Label", "Section",
    "Menu", "Link", "PrimaryButton", "SecondaryButton", "conflictTag",
}
# Modifiers taking a localized title as first argument.
MODIFIERS = {"help", "navigationTitle", "alert", "confirmationDialog"}
# Component arguments typed LocalizedStringKey: call -> label.
LABELLED = {
    "SettingsSidebarRow": "title", "AgentWho": "label", "MailField": "label", "StatusBadge": "label",
    "GaugeRowView": "label", "GitHubStatRow": "label", "StatRow": "label", "IntegrationFilterRow": "label",
}

INT_HINT = re.compile(r"\.count\b|\bInt\(|\bInt32\(|\bmin\(|\bmax\(|\+ 1\b|\bn\b|\bmins\b|\bcode\b|\bday\b|\.number\b|^\s*s\s*$")  # `s`: the Int of ForEach([10, 15, 30])
IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class Scanner:
    """Walks one Swift file and returns (key, line) for the literals worth extracting."""

    def __init__(self, text):
        self.t = text
        self.n = len(text)
        self.interps = []  # (start, end) of the interpolations met by parse_string, scanned by scan()

    def line_of(self, pos):
        return self.t.count("\n", 0, pos) + 1

    # --- string literals -------------------------------------------------------------------
    def parse_string(self, i):
        """Parses the literal whose opening quote is at i. Returns (key or None, index after it).
        Multi-line literals give None."""
        t = self.t
        if t.startswith('"""', i):
            end = t.find('"""', i + 3)
            return None, (end + 3) if end >= 0 else self.n
        i += 1
        out = []
        while i < self.n:
            c = t[i]
            if c == '"':
                return "".join(out), i + 1
            if c == "\\":
                nxt = t[i + 1] if i + 1 < self.n else ""
                if nxt == "(":
                    expr, i = self.parse_interpolation(i + 2)
                    # a number wrapped in String(...) is a string placeholder (no locale grouping)
                    is_int = INT_HINT.search(expr) and not expr.lstrip().startswith("String(")
                    out.append("%lld" if is_int else "%@")
                    continue
                simple = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\", "'": "'", "0": "\0"}
                if nxt in simple:
                    out.append(simple[nxt]); i += 2; continue
                if nxt == "u" and t[i + 2:i + 3] == "{":
                    j = t.find("}", i)
                    out.append(chr(int(t[i + 3:j], 16))); i = j + 1; continue
                out.append(nxt); i += 2; continue
            if c == "\n":
                return None, i
            out.append(c); i += 1
        return None, self.n

    def parse_interpolation(self, i):
        """From just after `\\(`. Returns (expression text, index after the closing paren)."""
        depth = 1
        start = i
        while i < self.n and depth > 0:
            c = self.t[i]
            if c == '"':
                _, i = self.parse_string(i)
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
            i += 1
        self.interps.append((start, i - 1))
        return self.t[start:i - 1], i

    # --- argument expressions --------------------------------------------------------------
    def argument_literals(self, i):
        """From just after an opening paren, or after a `label:`: the literals of that argument at its own
        level (ternary branches included, nested calls and closures excluded). Returns [(key, pos)]."""
        t = self.t
        found = []
        depth = 0
        already_string = False
        while i < self.n:
            c = t[i]
            if c == '"':
                key, j = self.parse_string(i)
                if key is not None and depth == 0:
                    found.append((key, i))
                i = j
                continue
            if depth == 0 and t.startswith("String(localized:", i):
                already_string = True
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif c == "," and depth == 0:
                break
            elif t.startswith("//", i):
                j = t.find("\n", i)
                i = j if j >= 0 else self.n
                continue
            i += 1
        # `cond ? String(localized: "A") : "path"` is already a String: its other literals are not keys.
        # Only a String(localized:) at the argument's own level counts, not one inside an interpolation.
        if already_string:
            return []
        return found

    def labelled_literals(self, i, label):
        """Literals of the `label:` argument among the arguments of the call opened just before i."""
        t = self.t
        out = []
        depth = 0
        at_start = True
        while i < self.n:
            c = t[i]
            if c == '"':
                _, i = self.parse_string(i)
                at_start = False
                continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if depth == 0:
                    break
                depth -= 1
            elif c == "," and depth == 0:
                at_start = True
                i += 1
                continue
            if at_start and depth == 0 and not c.isspace():
                m = IDENT.match(t, i)
                if m and m.group(0) == label and t[m.end():m.end() + 1] == ":":
                    out.extend(self.argument_literals(m.end() + 1))
                at_start = False
            i += 1
        return out

    # --- literals typed LocalizedStringKey -------------------------------------------------
    TYPED = re.compile(
        r"^[ \t]*(?:[@\w.()]+[ \t]+)*?(?:var|let|func)[ \t]+\w+[^\n{=]*?(?::|->)[ \t]*LocalizedStringKey\??[ \t]*(?P<next>[={])",
        re.M)

    def typed_literals(self):
        """Literals of properties, constants and functions whose declared type is LocalizedStringKey
        (`var k: LocalizedStringKey { cond ? "A" : "B" }`, `let k: LocalizedStringKey = "A"`,
        `func f() -> LocalizedStringKey { ... }`). Returns [(key, pos)]."""
        t = self.t
        out = []
        for m in self.TYPED.finditer(t):
            i = m.end("next")
            braces = m.group("next") == "{"
            depth = 0   # parens and brackets only: literals of nested calls are not keys
            bdepth = 1  # braces of a body
            while i < self.n:
                c = t[i]
                if c == '"':
                    key, j = self.parse_string(i)
                    if key is not None and depth == 0:
                        out.append((key, i))
                    i = j
                    continue
                if t.startswith("//", i):
                    j = t.find("\n", i)
                    i = j if j >= 0 else self.n
                    continue
                if c in "([":
                    depth += 1
                elif c in ")]":
                    if depth == 0:
                        break
                    depth -= 1
                elif braces and c == "{":
                    bdepth += 1
                elif braces and c == "}":
                    bdepth -= 1
                    if bdepth == 0:
                        break
                elif not braces and depth == 0 and c in "\n,":
                    break
                i += 1
        return out

    # --- the scan --------------------------------------------------------------------------
    def scan(self):
        t = self.t
        results = [(key, self.line_of(pos)) for key, pos in self.typed_literals()]
        i = 0
        while i < self.n:
            c = t[i]
            if t.startswith("//", i):
                j = t.find("\n", i)
                i = j if j >= 0 else self.n
                continue
            if t.startswith("/*", i):
                j = t.find("*/", i)
                i = (j + 2) if j >= 0 else self.n
                continue
            if t.startswith('#"', i):  # raw string: never a UI key
                j = t.find('"#', i + 2)
                i = (j + 2) if j >= 0 else self.n
                continue
            if c == '"':
                self.interps = []
                _, i = self.parse_string(i)
                for (a, b) in self.interps:
                    base = self.line_of(a) - 1
                    for key, line in Scanner(t[a:b]).scan():
                        results.append((key, base + line))
                continue
            m = IDENT.match(t, i)
            if m and (i == 0 or not (t[i - 1].isalnum() or t[i - 1] == "_")):
                name = m.group(0)
                j = m.end()
                if j < self.n and t[j] == "(":
                    prev = t[i - 1] if i > 0 else ""
                    after = t[j + 1:j + 24].lstrip()
                    if name == "String" and after.startswith("localized:"):
                        k = t.index("localized:", j) + len("localized:")
                        while t[k] in " \t":
                            k += 1
                        if t[k] == '"':
                            key, _ = self.parse_string(k)
                            if key is not None:
                                results.append((key, self.line_of(k)))
                    elif name == "NSLocalizedString":
                        k = j + 1
                        while t[k] in " \t\n":
                            k += 1
                        if t[k] == '"':
                            key, _ = self.parse_string(k)
                            if key is not None:
                                results.append((key, self.line_of(k)))
                    elif name in CALLS and prev != ".":
                        if not after.startswith("verbatim:"):
                            for key, pos in self.argument_literals(j + 1):
                                results.append((key, self.line_of(pos)))
                    elif prev == "." and name in MODIFIERS:
                        for key, pos in self.argument_literals(j + 1):
                            results.append((key, self.line_of(pos)))
                    elif name in LABELLED:
                        for key, pos in self.labelled_literals(j + 1, LABELLED[name]):
                            results.append((key, self.line_of(pos)))
                i = j
                continue
            i += 1
        return results


def extract():
    found = {}
    for d in SOURCE_DIRS:
        for dirpath, _, files in os.walk(os.path.join(ROOT, d)):
            for fn in sorted(files):
                if not fn.endswith(".swift"):
                    continue
                path = os.path.join(dirpath, fn)
                rel = os.path.relpath(path, ROOT)
                with open(path, encoding="utf-8") as f:
                    text = f.read()
                for key, line in Scanner(text).scan():
                    found.setdefault(key, []).append("%s:%d" % (rel, line))
    return found


def main():
    found = extract()
    if "--json" in sys.argv:
        print(json.dumps({k: v for k, v in sorted(found.items())}, ensure_ascii=False, indent=2))
        return
    for key in sorted(found):
        print("%s\t%s" % (json.dumps(key, ensure_ascii=False), found[key][0]))


if __name__ == "__main__":
    main()
