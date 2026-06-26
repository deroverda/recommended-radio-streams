#!/usr/bin/env python3
"""
lint_readme.py - structural & editorial linter for recommended-radio-streams README.

Warn-only by design: always exits 0, never edits the file, never judges stream
liveness (that's ffprobe + your ears). It checks the TEXT and STRUCTURE of the
README that lychee and ffprobe cannot see.

Usage:
    python lint_readme.py README.md

Layers below this one:
    lychee   -> homepage links resolve
    ffprobe  -> audio actually decodes
    foobar2000/VLC from residential IP -> final arbiter
This script -> the markdown itself: schemes, dashes, banned words, format,
               duplicates, alpha order, anchors.
"""

import os
import re
import sys
import unicodedata
from collections import defaultdict

# ----------------------------------------------------------------------------
# Config
# ----------------------------------------------------------------------------

# Hard bans: flagged anywhere in a description. You judge every hit (per your call).
BANNED_WORDS = [
    "24/7", "ad-free", "eclectic", "hub", "platform", "curated",
    "diverse", "sonic art", "programming", "community",
    # redundant-in-context words: almost always removable from descriptions
    "internet radio", "radio station",
]
# "radio" / "station" as bare words are intentionally not flagged: too common
# in legitimate names/descriptions, and flagging them buries real findings.

DESC_WORD_CAP = 12          # ~10-12 word guideline
DESC_WORD_SOFT = 15         # INFO above this (13-14 is normal, not worth flagging)
DESC_WORD_HARD = 18         # WARN above this

# Em-dash U+2014, en-dash U+2013, plus the minus sign U+2212 occasionally pasted
DASH_CHARS = "\u2014\u2013\u2212"

# A station entry line: "- [Name](url): description ... [something](streamurl)"
# We treat any list item with at least one markdown link as a candidate, then
# refine. Contents links and nav links are filtered by section context.
ENTRY_RE = re.compile(r'^\s*-\s+(?:\u2b50\s+)?\[(?P<name>[^\]]+)\]\((?P<url>[^)]*)\)\s*:?\s*(?P<rest>.*)$')
STAR_RE = re.compile(r'^\s*-\s+(\u2b50)(\s*)\[')
HEADING_RE = re.compile(r'^(#{2,4})\s+(?P<title>.*?)(?:\s*<a id="(?P<anchor>[^"]+)"></a>)?\s*$')
TOC_LINK_RE = re.compile(r'\[(?P<text>[^\]]+)\]\(#(?P<slug>[^)]+)\)')
LINK_RE = re.compile(r'\[[^\]]*\]\((?P<url>[^)]+)\)')

# Sections that actually contain station entries (others are nav/apps/directories).
# Anything under "The Station Directory", plus the two standalone music sections.
STATION_SECTION_HINTS = None  # determined dynamically; see section walk below.


def gh_slug(title):
    """Approximate GitHub's heading-to-anchor slug algorithm."""
    s = title.strip().lower()
    s = s.replace("&", "")            # GitHub drops ampersands
    s = re.sub(r"[^\w\s-]", "", s)    # strip punctuation
    s = s.strip().replace(" ", "-")
    s = re.sub(r"-+", "-", s)
    return s


def sort_key(name):
    """Alpha-sort key: ignore a leading 'The', strip a leading star, NFD-normalize."""
    n = name.strip()
    n = re.sub(r"^\u2b50\s*", "", n)
    n = re.sub(r"^[Tt]he\s+", "", n)
    n = unicodedata.normalize("NFD", n)
    n = "".join(c for c in n if not unicodedata.combining(c))
    return n.lower()


def word_count(text):
    # crude but adequate: split on whitespace, ignore markdown link syntax noise
    stripped = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)  # links -> their text
    stripped = re.sub(r'[*_`]', '', stripped)
    return len(stripped.split())


def main(path):
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    findings = []  # (lineno, severity, message)

    def add(lineno, sev, msg):
        findings.append((lineno, sev, msg))

    # --- Pass 1: collect headings, anchors, and section membership ---------
    headings = []  # (lineno, level, title, explicit_anchor, effective_anchor)
    for i, raw in enumerate(lines, 1):
        m = HEADING_RE.match(raw.rstrip("\n"))
        if m and raw.startswith("#"):
            level = len(m.group(1))
            title = m.group("title").strip()
            anchor = m.group("anchor")
            effective = anchor or gh_slug(title)
            headings.append((i, level, title, anchor, effective))

    valid_anchors = {h[4] for h in headings}

    # --- Pass 2: Contents links resolve to a real anchor -------------------
    in_contents = False
    for i, raw in enumerate(lines, 1):
        if raw.startswith("## Contents"):
            in_contents = True
            continue
        if in_contents and raw.startswith("## ") and "Contents" not in raw:
            in_contents = False
        if in_contents:
            for tm in TOC_LINK_RE.finditer(raw):
                slug = tm.group("slug")
                if slug not in valid_anchors:
                    add(i, "WARN", f"Contents link #{slug} has no matching section anchor")

    # reverse: which section anchors are reachable from Contents
    toc_slugs = set()
    in_contents = False
    for raw in lines:
        if raw.startswith("## Contents"):
            in_contents = True
            continue
        if in_contents and raw.startswith("## ") and "Contents" not in raw:
            in_contents = False
        if in_contents:
            for tm in TOC_LINK_RE.finditer(raw):
                toc_slugs.add(tm.group("slug"))

    # --- Pass 3: walk station sections, gather entries ---------------------
    # A "station section" = any heading whose nearest ## ancestor is
    # "The Station Directory", OR the standalone Experimental / Multi-Station.
    # We approximate by tracking the current ## and lowest-level heading.
    station_section_titles = set()
    current_h2 = None
    for (i, level, title, anchor, eff) in headings:
        if level == 2:
            current_h2 = title
        directory_child = current_h2 == "The Station Directory" and level >= 3
        standalone = title in ("Experimental, Nerdy & Scanners", "Multi-Station Networks")
        if directory_child or standalone:
            station_section_titles.add((i, title))

    # build line ranges for each lowest-level grouping under station sections
    # grouping resets at every ### or #### heading.
    group_bounds = []  # (start_line, end_line, label, is_station_group)
    heading_lines = [h[0] for h in headings] + [len(lines) + 1]
    for idx, (i, level, title, anchor, eff) in enumerate(headings):
        start = i + 1
        end = heading_lines[idx + 1] - 1
        # is this a station-bearing lowest grouping?
        current_h2_local = None
        for (hi, hl, ht, ha, he) in headings:
            if hi <= i and hl == 2:
                current_h2_local = ht
        is_station = (
            (current_h2_local == "The Station Directory" and level >= 3 and level != 2)
            or title in ("Experimental, Nerdy & Scanners", "Multi-Station Networks")
        )
        # only treat as a station GROUP if it has no deeper sub-headings inside
        has_subheading = any(start <= hl2 <= end and lvl2 > level
                             for (hl2, lvl2, *_rest) in headings)
        group_bounds.append((start, end, title, is_station and not has_subheading))

    # --- Pass 4: per-line checks ------------------------------------------
    # Track which group each line belongs to for alpha + duplicate scope.
    def group_for(lineno):
        for (start, end, label, is_station) in group_bounds:
            if start <= lineno <= end:
                return (label, is_station)
        return (None, False)

    seen_station_global = {}     # sort_key -> (lineno, original_name) across all station groups
    group_entries = defaultdict(list)  # label -> [(lineno, name)]

    in_code_block = False
    for i, raw in enumerate(lines, 1):
        line = raw.rstrip("\n")
        if line.strip().startswith("```"):
            in_code_block = not in_code_block
            continue
        if in_code_block:
            continue

        label, is_station = group_for(i)

        # -- dash check: applies everywhere (your hyphen-only rule is global) --
        for ch in line:
            if ch in DASH_CHARS:
                add(i, "WARN", f"em/en-dash U+{ord(ch):04X} present; use a hyphen")
                break

        # -- star format check on any starred entry --
        if "\u2b50" in line and line.lstrip().startswith("-"):
            if not STAR_RE.match(line):
                add(i, "INFO", "star not in '⭐ [' format (need '⭐ ' before the '[')")

        m = ENTRY_RE.match(line)
        if not m:
            continue

        name = m.group("name").strip()
        url = m.group("url").strip()
        rest = m.group("rest").strip()

        # Skip if this list item is a Contents/nav link (target starts with #)
        if url.startswith("#"):
            continue

        # -- malformed scheme checks (any link in the line, station or not) --
        for lm in LINK_RE.finditer(line):
            u = lm.group("url")
            if u.startswith("#"):
                continue
            if re.match(r'^https?:/[^/]', u):
                add(i, "ERROR", f"malformed scheme '{u[:20]}...' (single slash after colon)")
            elif not re.match(r'^(https?://|mailto:)', u) and "." in u and " " not in u:
                add(i, "WARN", f"link missing scheme: '{u[:40]}'")

        # Everything below is station-entry specific.
        if not is_station:
            continue

        group_entries[label].append((i, name))

        # -- description banned words --
        desc = rest
        desc_lower = desc.lower()
        for bw in BANNED_WORDS:
            if bw.lower() in desc_lower:
                add(i, "WARN", f"banned phrase '{bw}' in description")
        # NOTE: bare 'radio'/'station' are intentionally NOT flagged - they
        # appear in legitimate station names and descriptions constantly, so
        # flagging them buries real findings. The banned-phrase list above
        # already catches the true redundancy cases ('internet radio',
        # 'radio station').

        # -- description length --
        wc = word_count(desc.split(" [")[0])  # count up to first trailing link block
        if wc > DESC_WORD_HARD:
            add(i, "WARN", f"description ~{wc} words (cap ~{DESC_WORD_CAP})")
        elif wc > DESC_WORD_SOFT:
            add(i, "INFO", f"description ~{wc} words (cap ~{DESC_WORD_CAP})")

        # -- entry has a stream link? (accept [Stream], [Channel N], [1], etc.) --
        # Skip Multi-Station Networks: those entries legitimately list channels
        # in prose and often carry only a homepage.
        if label != "Multi-Station Networks":
            links = LINK_RE.findall(line)
            has_stream_label = re.search(r'\[(Stream|Channel|Listen|\d+)\]', line, re.I)
            if len(links) < 2 and not has_stream_label:
                add(i, "INFO", "no stream link found (homepage only)")

        # -- duplicate station across station groups --
        k = sort_key(name)
        if k in seen_station_global:
            prev_line, prev_name = seen_station_global[k]
            add(i, "WARN", f"duplicate station '{name}' (also at line {prev_line})")
        else:
            seen_station_global[k] = (i, name)

    # --- Pass 5: alphabetical order within each station group -------------
    for label, entries in group_entries.items():
        prev_key = None
        prev_line = None
        prev_name = None
        for (lineno, name) in entries:
            k = sort_key(name)
            if prev_key is not None and k < prev_key:
                add(lineno, "WARN",
                    f"alpha-order: '{name}' should precede '{prev_name}' (line {prev_line})")
            prev_key, prev_line, prev_name = k, lineno, name

    # --- Pass 6: back-to-top presence on major sections (INFO) ------------
    # A '## ' or '### ' section that ends right before '---' but has no
    # '[↑ back to top]' in its body.
    backtotop_re = re.compile(r'back to top', re.I)
    for idx, (i, level, title, anchor, eff) in enumerate(headings):
        if level > 3:
            continue
        start = i + 1
        end = heading_lines[idx + 1] - 1
        body = "".join(lines[start - 1:end])
        if "---" in body and not backtotop_re.search(body):
            # only flag sections that have entries (skip pure nav)
            if any(ENTRY_RE.match(l.rstrip("\n")) for l in lines[start - 1:end]):
                add(i, "INFO", f"section '{title}' may be missing a back-to-top link")

    # --- Report -----------------------------------------------------------
    findings.sort(key=lambda x: (x[0], {"ERROR": 0, "WARN": 1, "INFO": 2}[x[1]]))
    counts = defaultdict(int)
    for (lineno, sev, msg) in findings:
        counts[sev] += 1
        print(f"{path}:{lineno:<5} {sev:<6} {msg}")

    print()
    summary_line = (f"{counts['ERROR']} errors, "
                    f"{counts['WARN']} warnings, {counts['INFO']} info")
    print(summary_line)

    # If running in GitHub Actions, also write a rendered markdown summary to
    # the job summary page (same behavior as the alpha-check job this replaces).
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        md = ["# README Structure & Style Lint\n"]
        if findings:
            md.append(f"**{summary_line}**\n")
            md.append("| Line | Severity | Issue |")
            md.append("| ---: | :--- | :--- |")
            for (lineno, sev, msg) in findings:
                safe = msg.replace("|", "\\|")
                md.append(f"| {lineno} | {sev} | {safe} |")
        else:
            md.append("No issues found.")
        with open(step_summary, "a", encoding="utf-8") as f:
            f.write("\n".join(md) + "\n")

    # Warn-only: always succeed.
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: python lint_readme.py README.md", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
