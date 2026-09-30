#!/usr/bin/env python3
"""Builds the Sparkle appcast for this fork's releases.

Every Amethyst-<version>.zip in the releases folder becomes one item. The version,
build number and minimum system version come from the Info.plist inside the zip,
the EdDSA signature and length from Sparkle's sign_update, the date from the zip's
modification time, and the release notes from <notes folder>/<version>.md when
that file exists. Items are listed newest build first.
"""

import argparse
import datetime
import html
import pathlib
import plistlib
import re
import subprocess
import sys
import zipfile

REPOSITORY = "https://github.com/djp3/Amethyst"
DEFAULT_SIGN_UPDATE = pathlib.Path.home() / "local/scripts/sparkle-2.9.5/sign_update"


def info_plist(zip_path):
    with zipfile.ZipFile(zip_path) as archive:
        name = next(n for n in archive.namelist() if n.endswith("Amethyst.app/Contents/Info.plist"))
        return plistlib.loads(archive.read(name))


def signature(zip_path, sign_update):
    output = subprocess.run([str(sign_update), str(zip_path)], check=True, capture_output=True, text=True).stdout
    return (
        re.search(r'sparkle:edSignature="([^"]+)"', output).group(1),
        re.search(r'length="(\d+)"', output).group(1),
    )


def inline_html(text):
    text = html.escape(text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"`(.+?)`", r"<code>\1</code>", text)
    text = re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', text)
    return text


def notes_html(markdown):
    """Paragraphs, bullet lists, bold, code and links; enough for release notes."""
    output, paragraph, in_list = [], [], False

    def flush():
        if paragraph:
            output.append("<p>" + inline_html(" ".join(paragraph)) + "</p>")
            paragraph.clear()

    for line in markdown.splitlines():
        if line.startswith("- "):
            flush()
            if not in_list:
                output.append("<ul>")
                in_list = True
            output.append("<li>" + inline_html(line[2:]) + "</li>")
            continue
        if in_list:
            output.append("</ul>")
            in_list = False
        if line.strip():
            paragraph.append(line.strip())
        else:
            flush()
    flush()
    if in_list:
        output.append("</ul>")
    return "\n".join(output)


def build_key(build):
    return tuple(int(part) for part in build.split("."))


def item(zip_path, sign_update, notes_dir):
    plist = info_plist(zip_path)
    version = plist["CFBundleShortVersionString"]
    build = plist["CFBundleVersion"]
    minimum = plist.get("LSMinimumSystemVersion", "12.0")
    ed_signature, length = signature(zip_path, sign_update)
    published = datetime.datetime.fromtimestamp(zip_path.stat().st_mtime).astimezone()
    notes = notes_dir / f"{version}.md" if notes_dir else None
    description = notes_html(notes.read_text()) if notes and notes.exists() else ""
    url = f"{REPOSITORY}/releases/download/v{version}/{zip_path.name}"
    xml = f"""    <item>
      <title>{version}</title>
      <pubDate>{published.strftime("%a, %d %b %Y %H:%M:%S %z")}</pubDate>
      <link>{REPOSITORY}/releases/tag/v{version}</link>
      <sparkle:version>{build}</sparkle:version>
      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{minimum}</sparkle:minimumSystemVersion>
      <description><![CDATA[
{description}
      ]]></description>
      <enclosure url="{url}" length="{length}" type="application/octet-stream" sparkle:edSignature="{ed_signature}"/>
    </item>"""
    return build_key(build), xml


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("releases_dir", type=pathlib.Path, help="folder holding the Amethyst-<version>.zip files")
    parser.add_argument("--notes-dir", type=pathlib.Path, help="folder holding <version>.md release notes")
    parser.add_argument("--sign-update", type=pathlib.Path, default=DEFAULT_SIGN_UPDATE, help="Sparkle's sign_update tool")
    parser.add_argument("--output", type=pathlib.Path, help="where to write the appcast (default: standard output)")
    args = parser.parse_args()

    zips = sorted(args.releases_dir.glob("Amethyst-*.zip"))
    if not zips:
        sys.exit(f"no Amethyst-*.zip files in {args.releases_dir}")
    items = sorted((item(z, args.sign_update, args.notes_dir) for z in zips), key=lambda pair: pair[0], reverse=True)

    appcast = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <channel>
    <title>Amethyst (djp3 builds)</title>
    <link>{REPOSITORY}/releases</link>
    <description>Releases of the djp3 fork of Amethyst.</description>
    <language>en</language>
{chr(10).join(xml for _, xml in items)}
  </channel>
</rss>
"""
    if args.output:
        args.output.write_text(appcast)
    else:
        sys.stdout.write(appcast)


if __name__ == "__main__":
    main()
