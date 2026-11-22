#!/usr/bin/env python3
"""The update feed's release notes for one version, in every language Margin has.

Reads that version's entry in Sources/MailUI/Model/Changelog.swift (the same notes as the
What's New sheet) and Apps/Shared/Changelogs/*.lproj/Changelog-<version>.strings, and prints one
Sparkle <description> per language. Sparkle shows the one matching the Mac's language in its
update window. A version without its own entry (a fix the same day, 2026.11.26.1) gets the
newest notes before it, as the What's New sheet does. Prints nothing when there are none.

    scripts/release-notes.py 2026.11.26
"""
import html, json, pathlib, re, subprocess, sys

root = pathlib.Path(__file__).resolve().parent.parent
version = sys.argv[1]
source = (root / "Sources/MailUI/Model/Changelog.swift").read_text()
# The newest block at or before this version: from its ChangelogRelease(version: "…") to the next.
def number(v):
    return [int(part) for part in v.split(".")]
blocks = re.split(r'ChangelogRelease\(version:\s*"', source)[1:]
block = next((b for b in blocks if number(b.split('"', 1)[0]) <= number(version)), None)
if block is None:
    sys.exit(0)
notes_version = block.split('"', 1)[0]
table = f"Changelog-{notes_version}"
translations = {
    path.parent.stem: json.loads(subprocess.check_output(
        ["plutil", "-convert", "json", "-o", "-", str(path)], text=True))
    for path in sorted((root / "Apps/Shared/Changelogs").glob(f"*.lproj/{table}.strings"))
}
string = r'String\(localized:\s*"((?:[^"\\]|\\.)*)",\s*table:\s*"' + re.escape(table) + r'"\)'
changes = re.findall(r'title:\s*' + string + r',\s*detail:\s*' + string, block)
if not changes:
    sys.exit(0)

def unescape(text):
    return text.encode().decode("unicode_escape").encode("latin-1").decode("utf-8")

source_language = "en"

def translated(key, language):
    if language == source_language:
        return key
    return translations[language].get(key) or key

languages = {source_language}
for title, detail in changes:
    for key in (unescape(title), unescape(detail)):
        languages |= {language for language, strings in translations.items() if key in strings}

for language in sorted(languages, key=lambda l: (l != source_language, l)):
    rows = "".join(
        f"<li><b>{html.escape(translated(unescape(t), language))}</b><br>{html.escape(translated(unescape(d), language))}</li>"
        for t, d in changes)
    lang = "" if language == source_language else f' xml:lang="{language}"'
    print(f'      <description{lang}><![CDATA[<ul>{rows}</ul>]]></description>')
