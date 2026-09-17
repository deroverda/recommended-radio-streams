#!/usr/bin/env python3
"""
stream_parser.py - shared README stream-link parser.

Single source of truth for the regexes that find stream links in README.md
entry lines. Used by:
- readme_to_m3u.py (imports ENTRY_RE and extract_streams directly)
- probe-streams.sh's build_name_map() (calls this file with --name-map)
- link-check.yml's "Exclude stream URLs from Lychee" step (calls this file
  with --name-map too, then cuts to the url column)

Extracted 2026-09-17 after the same four regexes had drifted into three
separate hand-maintained copies, each carrying a comment asking the next
editor to keep all three identical by hand. They had already drifted:
STREAM_LINK_RE existed in a url-only form and a (label, url) form.
"""

import re
import sys

ENTRY_RE = re.compile(
    r'^-\s*(?:⭐\s*)?\[(?P<name>[^\]]+)\]\((?P<homepage>[^)]+)\):\s*'
    r'(?P<desc>.*)$'
)
# Narrow by design. Broadening it would re-match two things that look like
# stream tags but aren't: a station's own homepage link when the name is
# numeric (e.g. "[1234](url)"), and an inline link inside a description.
# Kept as a fallback for lines where the stream links aren't last: a trailing
# "*(down, ...)*" status note, or a parenthetical channel list like
# "([1](url), [2](url))".
STREAM_RE = re.compile(r'\[(Stream|Channel\s*[12]|[12])\]\((?P<url>[^)]+)\)', re.I)
# Preferred path: the "/"-joined chain of links at the very end of the line.
# Any label is safe here because the end-of-line anchor excludes inline
# description links (which sit before trailing text/punctuation). The
# optional trailing group tolerates one "*(down ...)*" note so a down-tagged
# multi-stream entry is still parsed.
STREAM_CHAIN_RE = re.compile(
    r'(?:\[[^\]]+\]\([^)]+\)\s*/\s*)*\[[^\]]+\]\([^)]+\)\s*'
    r'(?:\*\(\s*down\b[^)]*\)\*?\s*)?$'
)
STREAM_LINK_RE = re.compile(r'\[(?P<label>[^\]]+)\]\((?P<url>[^)]+)\)')
HEADING_RE = re.compile(r'^#{2,4}\s+(.*)')


def extract_streams(line):
    """Return [(label, url), ...] for a README entry line's stream link(s)."""
    m = STREAM_CHAIN_RE.search(line)
    if m:
        streams = STREAM_LINK_RE.findall(m.group(0))
        if streams:
            return streams
    return STREAM_RE.findall(line)


def entry_stream_urls(line):
    """URLs only, for callers that don't need the label."""
    return [url for _label, url in extract_streams(line)]


def _strip_heading_decoration(title):
    """Strip markdown links and HTML tags from a section heading."""
    title = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', title)
    title = re.sub(r'<[^>]+>', '', title).strip()
    return title


def build_name_map(path):
    """Yield (url, name, section, down) for every stream link in path."""
    with open(path, encoding='utf-8') as f:
        lines = f.readlines()

    current_section = '-'
    for raw in lines:
        s = raw.strip()
        hm = HEADING_RE.match(s)
        if hm:
            current_section = _strip_heading_decoration(hm.group(1)) or '-'
            continue
        m = ENTRY_RE.match(s)
        if not m:
            continue
        name = re.sub(r'\*+', '', m.group('name')).strip()
        # 4th field: 1 if the entry line carries a "*(down ...)*" status note.
        # Lets callers separate "already known down" from unexpected failures.
        down = '1' if re.search(r'\*\(\s*down\b', s, re.I) else '0'
        for url in entry_stream_urls(s):
            yield url, name, current_section, down


def main():
    if len(sys.argv) != 3 or sys.argv[1] != '--name-map':
        print("Usage: stream_parser.py --name-map README.md", file=sys.stderr)
        sys.exit(1)
    for url, name, section, down in build_name_map(sys.argv[2]):
        print(f"{url}\t{name}\t{section}\t{down}")


if __name__ == "__main__":
    main()
