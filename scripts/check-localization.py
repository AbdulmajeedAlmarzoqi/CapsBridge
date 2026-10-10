#!/usr/bin/env python3
"""Checks that every string the app shows has an Arabic translation.

Run it after a build: the Swift compiler writes the strings it found in the sources next to the
object files, and this compares them with Resources/Localizable.xcstrings.

    ./scripts/build.sh dev && ./scripts/check-localization.py
"""
import glob
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parent.parent
extracted = set()
pattern = root / "build/DerivedData/Build/Intermediates.noindex/CapsBridge.build/*/CapsBridge.build/Objects-normal/*/*.stringsdata"
for path in glob.glob(str(pattern)):
    with open(path, encoding="utf-8") as file:
        for entries in json.load(file).get("tables", {}).values():
            extracted.update(entry["key"] for entry in entries)

if not extracted:
    sys.exit("No extracted strings found. Build the app first: ./scripts/build.sh dev")

with open(root / "Resources/Localizable.xcstrings", encoding="utf-8") as file:
    catalog = json.load(file)["strings"]

translated = {
    key for key, entry in catalog.items()
    if entry.get("localizations", {}).get("ar", {}).get("stringUnit", {}).get("value")
}
missing = sorted(extracted - translated)
unused = sorted(set(catalog) - extracted)

for key in missing:
    print(f"missing in Arabic: {key!r}")
for key in unused:
    print(f"no longer used: {key!r}")
print(f"{len(extracted)} strings in the app, {len(missing)} missing, {len(unused)} unused")
sys.exit(1 if missing or unused else 0)
