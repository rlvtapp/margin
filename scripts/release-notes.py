#!/usr/bin/env python3
"""The update feed's release notes for one version, in every language Margin has.

Reads that version's entry in Sources/MailUI/Model/Changelog.swift (the same notes as the
What's New sheet) and the translations in Apps/Shared/Localizable.xcstrings, and prints one
Sparkle <description> per language. Sparkle shows the one matching the Mac's language in its
update window. A version without its own entry (a fix the same day, 2026.11.26.1) gets the
newest notes before it, as the What's New sheet does. Prints nothing when there are none.

    scripts/release-notes.py 2026.11.26
"""
import html, json, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
version = sys.argv[1]
source = (root / "Sources/MailUI/Model/Changelog.swift").read_text()
catalog = json.loads((root / "Apps/Shared/Localizable.xcstrings").read_text())

# The newest block at or before this version: from its ChangelogRelease(version: "…") to the next.
def number(v):
    return [int(part) for part in v.split(".")]
blocks = re.split(r'ChangelogRelease\(version:\s*"', source)[1:]
block = next((b for b in blocks if number(b.split('"', 1)[0]) <= number(version)), None)
if block is None:
    sys.exit(0)
string = r'String\(localized:\s*"((?:[^"\\]|\\.)*)"\)'
changes = re.findall(r'title:\s*' + string + r',\s*detail:\s*' + string, block)
if not changes:
    sys.exit(0)

def unescape(text):
    return text.encode().decode("unicode_escape").encode("latin-1").decode("utf-8")

source_language = catalog.get("sourceLanguage", "en")
strings = catalog.get("strings", {})

def translated(key, language):
    if language == source_language:
        return key
    unit = strings.get(key, {}).get("localizations", {}).get(language, {}).get("stringUnit", {})
    return unit.get("value") if unit.get("state") in ("translated", None) and unit.get("value") else key

languages = {source_language}
for title, detail in changes:
    for key in (unescape(title), unescape(detail)):
        languages |= set(strings.get(key, {}).get("localizations", {}))

for language in sorted(languages, key=lambda l: (l != source_language, l)):
    rows = "".join(
        f"<li><b>{html.escape(translated(unescape(t), language))}</b><br>{html.escape(translated(unescape(d), language))}</li>"
        for t, d in changes)
    lang = "" if language == source_language else f' xml:lang="{language}"'
    print(f'      <description{lang}><![CDATA[<ul>{rows}</ul>]]></description>')
