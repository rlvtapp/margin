#!/usr/bin/env python3
"""Validate native translation tables, optionally against compiler extraction.

    python3 scripts/check-localizations.py
    python3 scripts/check-localizations.py --extracted-strings /tmp/margin-loc
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extracted-strings", type=Path)
    args = parser.parse_args()
    shared = Path(__file__).resolve().parent.parent / "Apps/Shared"
    tables = {}
    errors = []
    for path in sorted(shared.rglob("*.lproj/*.strings")):
        try:
            values = json.loads(subprocess.check_output(
                ["plutil", "-convert", "json", "-o", "-", str(path)], text=True))
        except subprocess.CalledProcessError:
            errors.append(f"{path}: invalid strings file")
            continue
        localized = tables.setdefault(path.parent.stem, {})
        if path.stem in localized:
            errors.append(f"{path}: duplicate table for {path.parent.stem}")
        localized[path.stem] = values

    source = tables.get("en", {})
    if not source:
        errors.append("Missing English translation tables")

    # A later build may reuse an older release's notes, so table names must use
    # the notes' version rather than whichever build is currently being shipped.
    changelog = (shared.parent.parent / "Sources/MailUI/Model/Changelog.swift").read_text()
    blocks = re.split(r'ChangelogRelease\(version:\s*"', changelog)[1:]
    release_tables = set()
    for block in blocks:
        version = block.split('"', 1)[0]
        table = f"Changelog-{version}"
        release_tables.add(table)
        entries = re.findall(
            r'String\(localized:\s*("(?:[^"\\]|\\.)*"),\s*table:\s*"([^"]+)"\)', block)
        keys = {json.loads(key) for key, _ in entries}
        if not entries or any(actual != table for _, actual in entries):
            errors.append(f"Changelog {version}: titles and descriptions must use {table}")
        if source.get(table, {}).keys() != keys:
            errors.append(f"{table}: English keys differ from the release's titles and descriptions")
    if {table for table in source if table.startswith("Changelog")} != release_tables:
        errors.append("Changelog translation tables differ from the releases in Changelog.swift")
    for locale, localized in tables.items():
        if localized.keys() != source.keys():
            errors.append(f"{locale}: table names differ from English")
        for table, values in localized.items():
            for key in values.keys() - source.get(table, {}).keys():
                errors.append(f"{locale}/{table}: unknown source key {key!r}")

    # Localizable contains legacy and shared controls; feature tables have explicit
    # lookups, so an extracted key missing from English is an incorrect table move.
    if args.extracted_strings:
        files = list(args.extracted_strings.rglob("*.stringsdata"))
        if not files:
            errors.append(f"{args.extracted_strings}: no compiler extraction files")
        for path in files:
            data = json.loads(path.read_text())
            for table, entries in data.get("tables", {}).items():
                if table == "Localizable":
                    continue
                for entry in entries:
                    if entry["key"] not in source.get(table, {}):
                        errors.append(f"{data['source']}: missing {table} key {entry['key']!r}")

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Validated {len(source)} translation tables across {len(tables)} locales.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
