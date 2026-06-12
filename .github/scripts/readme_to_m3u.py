#!/usr/bin/env python3
"""
Parse recommended-radio-streams README.md and generate one .m3u playlist
per genre section/subsection.

Each section/subsection that contains entries with a [Stream](url) link
becomes its own <slug>.m3u file (standard #EXTM3U / #EXTINF format,
playable in VLC, foobar2000, etc).

Sections with no stream entries (Apps & Players, Multi-Station Networks,
Directories & Discovery Tools, etc.) are skipped entirely.

Usage:
    python3 readme_to_m3u.py README.md output_dir/
"""

import os
import re
import sys

ENTRY_RE = re.compile(
    r'^-\s*(?:⭐\s*)?\[(?P<name>[^\]]+)\]\((?P<homepage>[^)]+)\):\s*'
    r'(?P<desc>.*)$'
)
STREAM_RE = re.compile(r'\[(Stream|Channel\s*\d*)\]\((?P<url>[^)]+)\)', re.I)
HEADER_RE = re.compile(r'^(#{2,4})\s+(.*)')


def strip_md_links(text):
    text = re.sub(r'<a[^>]*>.*?</a>|<a[^>]*/?>', '', text)
    text = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)
    return text.strip()


def slugify(title):
    s = strip_md_links(title).lower()
    s = re.sub(r'[^a-z0-9]+', '-', s)
    return s.strip('-')


def parse_sections(path):
    """
    Returns a flat list of (title, entries) for every header that has at
    least one direct stream entry. Headers at any level (##/###/####)
    are treated the same - this matches how the README mixes 2/3/4-level
    headers for genre groupings.
    """
    sections = []
    current_title = None
    current_entries = []

    def flush():
        if current_title and current_entries:
            sections.append((current_title, current_entries[:]))

    with open(path, encoding='utf-8') as f:
        lines = f.read().split('\n')

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

        streams = STREAM_RE.findall(s)
        if not streams:
            continue

        name = re.sub(r'\*+', '', m.group('name')).strip()

        if len(streams) == 1:
            current_entries.append((name, streams[0][1]))
        else:
            for label, url in streams:
                label = label.strip() or "Stream"
                current_entries.append((f"{name} - {label}", url))

    flush()
    return sections


def write_m3u(path, entries):
    with open(path, 'w', encoding='utf-8') as f:
        f.write("#EXTM3U\n")
        for name, url in entries:
            f.write(f"#EXTINF:-1,{name}\n")
            f.write(f"{url}\n")


def main():
    if len(sys.argv) != 3:
        print("Usage: python3 readme_to_m3u.py README.md output_dir/", file=sys.stderr)
        sys.exit(1)

    in_path, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    sections = parse_sections(in_path)

    seen_slugs = {}
    for title, entries in sections:
        slug = slugify(title)
        if slug in seen_slugs:
            seen_slugs[slug] += 1
            slug = f"{slug}-{seen_slugs[slug]}"
        else:
            seen_slugs[slug] = 0

        out_path = os.path.join(out_dir, f"{slug}.m3u")
        write_m3u(out_path, entries)
        print(f"{slug}.m3u: {len(entries)} stations ({title})")

    print(f"\n{len(sections)} playlists written to {out_dir}")


if __name__ == "__main__":
    main()
