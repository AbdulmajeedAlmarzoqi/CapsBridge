#!/usr/bin/env python3
"""Adds a release to CapsBridge's update feed and signs the feed.

The feed (docs/appcast.xml) is rebuilt from ReleaseNotes/releases.json, which lists every release,
and from each release's notes in ReleaseNotes/<version>/en.md and ar.md. The archive and the feed are
signed with the EdDSA key whose public half is SUPublicEDKey in Resources/Info.plist.

    scripts/appcast.py --version 1.0.1 --build 2 --archive build/CapsBridge-1.0.1.zip

build.sh runs this after a release build. Publish the archive as the GitHub release v<version>
before pushing the feed, so the feed never points at a file that isn't there yet.
"""
import argparse
import email.utils
import json
import os
import subprocess
import sys
from pathlib import Path
from xml.sax.saxutils import escape, quoteattr

ROOT = Path(__file__).resolve().parent.parent
RELEASES = ROOT / "ReleaseNotes/releases.json"
FEED = ROOT / "docs/appcast.xml"
DOWNLOAD = "https://github.com/AbdulmajeedAlmarzoqi/CapsBridge/releases/download/v{version}/CapsBridge-{version}.zip"
LANGUAGES = ["en", "ar"]
MINIMUM_SYSTEM = "26.0.0"


def sparkle_tool(name):
    candidates = [os.environ.get("SPARKLE_BIN", ""), str(ROOT / "build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin")]
    for folder in candidates:
        tool = Path(folder) / name
        if folder and tool.is_file():
            return str(tool)
    sys.exit(f"Can't find Sparkle's {name}. Build the app once, or set SPARKLE_BIN.")


def sign(tool, key, path, *extra):
    result = subprocess.run([tool, "--ed-key-file", key, *extra, str(path)], capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"sign_update failed: {result.stderr.strip()}")
    return result.stdout.strip()


def notes(version, root):
    found = {}
    for language in LANGUAGES:
        path = root / version / f"{language}.md"
        if path.is_file():
            found[language] = path.read_text(encoding="utf-8").strip()
    if "en" not in found:
        sys.exit(f"Missing release notes: {root / version / 'en.md'}")
    return found


def item(release, release_notes):
    descriptions = "\n".join(
        f'      <description xml:lang="{language}" sparkle:format="markdown"><![CDATA[{text}]]></description>'
        for language, text in release_notes.items())
    return f"""    <item>
      <title>CapsBridge {escape(release["version"])}</title>
      <pubDate>{release["date"]}</pubDate>
      <sparkle:version>{escape(release["build"])}</sparkle:version>
      <sparkle:shortVersionString>{escape(release["version"])}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{MINIMUM_SYSTEM}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
{descriptions}
      <enclosure url={quoteattr(release["url"])} length="{release["length"]}" type="application/octet-stream" sparkle:edSignature={quoteattr(release["signature"])}/>
    </item>"""


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--url", help="where the archive is downloaded from (the GitHub release by default)")
    parser.add_argument("--key", default=os.path.expanduser("~/.capsbridge-release/sparkle-ed25519-private.key"))
    parser.add_argument("--releases", type=Path, default=RELEASES, help="the list of releases to add to")
    parser.add_argument("--feed", type=Path, default=FEED, help="the feed to write")
    parser.add_argument("--notes", type=Path, default=ROOT / "ReleaseNotes", help="the folder with each release's notes")
    args = parser.parse_args()

    if not Path(args.key).is_file():
        sys.exit(f"No signing key at {args.key}. Export it with: generate_keys --account capsbridge -x {args.key}")
    release_notes = notes(args.version, args.notes)
    tool = sparkle_tool("sign_update")

    releases = json.loads(args.releases.read_text(encoding="utf-8")) if args.releases.is_file() else []
    releases = [r for r in releases if r["version"] != args.version]
    for other in releases:
        if int(other["build"]) >= int(args.build):
            sys.exit(f"Build {args.build} isn't newer than {other['version']}'s build {other['build']}. Raise CURRENT_PROJECT_VERSION in project.yml.")

    signature = sign(tool, args.key, args.archive, "-p")
    releases.append({
        "version": args.version,
        "build": str(args.build),
        "date": email.utils.formatdate(usegmt=True),
        "url": args.url or DOWNLOAD.format(version=args.version),
        "length": args.archive.stat().st_size,
        "signature": signature,
    })
    releases.sort(key=lambda r: int(r["build"]), reverse=True)
    args.releases.parent.mkdir(parents=True, exist_ok=True)
    args.releases.write_text(json.dumps(releases, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    items = "\n".join(item(r, notes(r["version"], args.notes)) for r in releases)
    feed = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>CapsBridge</title>
    <link>https://abdulmajeedalmarzoqi.github.io/CapsBridge/</link>
    <description>Updates for CapsBridge</description>
    <language>en</language>
{items}
  </channel>
</rss>
"""
    args.feed.parent.mkdir(parents=True, exist_ok=True)
    args.feed.write_text(feed, encoding="utf-8")
    sign(tool, args.key, args.feed)
    print(f"{args.feed}: CapsBridge {args.version} ({args.build}) added and the feed signed")


if __name__ == "__main__":
    main()
