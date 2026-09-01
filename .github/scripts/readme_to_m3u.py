#!/usr/bin/env python3
"""
readme_to_m3u.py - v3.0
Parse README.md and generate one .m3u playlist per category with stable,
human-readable filenames derived from the category title (no numeric suffixes).

Usage:
    python3 readme_to_m3u.py README.md output_dir/
"""

import os
import re
import sys
from collections import defaultdict

ENTRY_RE = re.compile(
    r'^-\s*(?:⭐\s*)?\[(?P<name>[^\]]+)\]\((?P<homepage>[^)]+)\):\s*'
    r'(?P<desc>.*)$'
)
# Narrow by design, and mirrors probe-streams.sh's pattern. Broadening it
# would re-match two things that look like stream tags but aren't: a
# station's own homepage link when the name is numeric (e.g. "[1234](url)"),
# and an inline link inside a description. Kept as a fallback for lines
# where the stream links aren't last: a trailing "*(down, ...)*" status
# note, or a parenthetical channel list like "([1](url), [2](url))".
STREAM_RE = re.compile(r'\[(Stream|Channel\s*[12]|[12])\]\((?P<url>[^)]+)\)', re.I)
# Preferred path: the "/"-joined chain of links at the very end of the
# line. Any label is safe here because the end-of-line anchor excludes
# inline description links (which sit before trailing text/punctuation).
STREAM_CHAIN_RE = re.compile(
    r'(?:\[[^\]]+\]\([^)]+\)\s*/\s*)*\[[^\]]+\]\([^)]+\)\s*$'
)
STREAM_LINK_RE = re.compile(r'\[(?P<label>[^\]]+)\]\((?P<url>[^)]+)\)')

def extract_streams(line):
    """Return [(label, url), ...] for a README entry line's stream link(s)."""
    m = STREAM_CHAIN_RE.search(line)
    if m:
        streams = STREAM_LINK_RE.findall(m.group(0))
        if streams:
            return streams
    return STREAM_RE.findall(line)
HEADER_RE = re.compile(r'^(#{2,4})\s+(.*)')

def strip_md_links(text):
    text = re.sub(r'<a[^>]*>.*?</a>|<a[^>]*/?>', '', text)
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)
    return text.strip()

def slugify(title):
    """Generate a stable, human-readable slug from the category title."""
    s = strip_md_links(title).lower()
    # Remove special chars except hyphen and alnum
    s = re.sub(r'[^a-z0-9\s-]', '', s)
    s = re.sub(r'[-\s]+', '-', s)
    s = s.strip('-')
    # If empty, fallback to "category"
    if not s:
        s = "category"
    return s

def parse_sections(path):
    """Parse README into a list of (title, entries) for each category."""
    sections = []
    current_title = None
    current_entries = []

    def flush():
        if current_title and current_entries:
            sections.append((current_title, current_entries[:]))

    # Fix: read all lines first, then close the file before iterating
    with open(path, encoding='utf-8') as f:
        lines = f.readlines()

    for raw in lines:
        s = raw.strip()
        h = HEADER_RE.match(s)
        if h:
            flush()
            current_title = strip_md_links(h.group(2))
            current_entries = []
            continue

        m = ENTRY_RE.match(s)
        if not m:
            continue
        streams = extract_streams(s)
        if not streams:
            continue

        name = re.sub(r'\*+', '', m.group('name')).strip()
        homepage = m.group('homepage').strip()

        for label, url in streams:
            label = label.strip() or "Stream"
            entry_name = f"{name} - {label}" if len(streams) > 1 else name
            current_entries.append((entry_name, url, homepage))

    flush()
    return sections

def write_m3u(path, entries, group_title):
    # utf-8-sig writes a BOM: without one, players like Foobar misread multi-byte
    # accented characters as a different codepage (e.g. Radio Krå -> Radio KrÃ¥).
    with open(path, 'w', encoding='utf-8-sig') as f:
        f.write("#EXTM3U\n")
        f.write(f"# Group: {group_title}\n")
        for name, url, homepage in entries:
            # Comment lines must NOT sit between #EXTINF and its URL - some
            # players treat that as a broken entry and skip it or misalign
            # the next one. So any per-entry comment goes BEFORE its EXTINF,
            # keeping every EXTINF immediately followed by its URL.
            if homepage:
                f.write(f"# Homepage: {homepage}\n")
            f.write(f"#EXTINF:-1,{name}\n")
            f.write(f"{url}\n")

def main():
    if len(sys.argv) != 3:
        print("Usage: python3 readme_to_m3u.py README.md output_dir/", file=sys.stderr)
        sys.exit(1)

    in_path, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    sections = parse_sections(in_path)

    # Fix: correct indentation throughout this block; slug_map belongs inside main()
    slug_map = {}

    for title, entries in sections:
        slug = slugify(title)

        if slug in slug_map:
            raise ValueError(
                f"Duplicate category slug '{slug}' generated from:\n"
                f" - {slug_map[slug]}\n"
                f" - {title}\n\n"
                "Rename one of the category headings so every playlist filename is unique."
            )

        slug_map[slug] = title
        out_path = os.path.join(out_dir, f"{slug}.m3u")
        write_m3u(out_path, entries, title)
        print(f"{slug}.m3u: {len(entries)} stations ({title})")

    print(f"\n{len(sections)} playlists written to {out_dir}")

if __name__ == "__main__":
    main()
