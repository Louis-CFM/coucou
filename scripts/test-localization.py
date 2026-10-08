#!/usr/bin/env python3
"""Check macOS Traditional Chinese coverage, plural paths, and format arguments."""
from collections import Counter
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "NotchBuddy/Resources/Localizable.xcstrings"
FORMAT = re.compile(r"%(?:\d+\$)?[-+# 0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp]")


def units(node, path=()):
    if isinstance(node, dict):
        if "stringUnit" in node:
            yield path, node["stringUnit"]
        else:
            for key, value in node.items():
                yield from units(value, path + (key,))


def arguments(value):
    # A literal %% is not an interpolation argument.
    return Counter(FORMAT.findall(value.replace("%%", "")))


def main():
    catalog = json.loads(CATALOG.read_text())
    errors = []
    if catalog["sourceLanguage"] != "en":
        errors.append("Expected English source language")
    for key, entry in catalog["strings"].items():
        localizations = entry.get("localizations", {})
        source = dict(units(localizations.get("en", {"stringUnit": {"value": key}})))
        translated = dict(units(localizations.get("zh-Hant", {})))
        if set(source) != set(translated):
            errors.append(f"{key!r}: missing translation or mismatched plural/substitution paths")
            continue
        for path, unit in source.items():
            target = translated[path]
            if target.get("state") != "translated" or not target.get("value", "").strip():
                errors.append(f"{key!r} {path}: incomplete translation")
            if arguments(unit["value"]) != arguments(target.get("value", "")):
                errors.append(f"{key!r} {path}: format arguments differ")
    project = (ROOT / "NotchBuddy/project.yml").read_text().split("\ntargets:\n", 1)[1]
    for name in ("NotchBuddy", "CoucouAppStore"):
        target = re.search(rf"^  {name}:\n(.*?)(?=^  \w+:|\Z)", project, re.M | re.S)
        if not target or not re.search(r"^          - zh-Hant$", target[1], re.M):
            errors.append(f"{name}: zh-Hant is missing from bundle localizations")
    for path in (ROOT / "NotchBuddy/Sources").rglob("*.swift"):
        if any(part in {"Phone", "Widgets", "NotificationContent"} for part in path.parts):
            continue
        for literal in re.findall(r'String\(localized:\s*"((?:\\.|[^"\\])*)"', path.read_text()):
            if "\\(" in literal:  # Xcode generates interpolation keys; format arguments are checked above.
                continue
            key = json.loads('"' + literal + '"')
            if key not in catalog["strings"]:
                errors.append(f"{path.name}: localized key {key!r} is missing from the catalog")
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"PASS: {len(catalog['strings'])} zh-Hant entries; plural paths and format arguments match; both macOS targets declare zh-Hant.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
