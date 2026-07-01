#!/usr/bin/env python3
"""
lint_readme.py - v3.0 structural & editorial linter for recommended-radio-streams README.

Implements all improvements from fixes.md:
- Banned vs discouraged words (ERROR vs WARN)
- Description length range (min 4, soft 15, hard 25)
- Detailed repository statistics (median, bars, etc.)
- Category distribution bar chart (Unicode)
- Duplicate detection with fuzzy similarity (difflib) for descriptions
- Repeated sentence starters & adjective frequency reports
- Alpha diagnostics: show expected order with context (disabled)
- Centralised configuration block
- Parse README once into an in-memory Repository model

Warn-only by design: always exits 0, never edits the file.

NOTE: The parser recognises station entries only under these specific H2 headings:
  'The Station Directory', 'Experimental, Nerdy & Scanners', 'Multi-Station Networks'
If those headings are renamed in the README, update the lists in parse_readme() to match.
"""

import os
import re
import sys
import difflib
import unicodedata
from collections import defaultdict, Counter
from statistics import median

# ----------------------------------------------------------------------------
# CONFIGURATION (centralised)
# ----------------------------------------------------------------------------
CONFIG = {
    # Description length
    "MIN_DESC_WORDS": 4,
    "SOFT_DESC_WORDS": 15,
    "HARD_DESC_WORDS": 25,

    # Banned words → ERROR (marketing fluff, claims)
    "BANNED_WORDS": {
        "24/7": "marketing fluff",
        "number one": "marketing claim",
        "best": "subjective marketing",
        "ultimate": "marketing",
        "#1": "marketing claim",
        "top rated": "marketing claim",
    },
    # Discouraged words → WARN (overused, vague)
    "DISCOURAGED_WORDS": {
        "curated": "overused adjective",
        "eclectic": "overused adjective",
        "platform": "vague wording",
        "hub": "vague wording",
        "diverse": "overused",
        "carefully": "overused adverb",
    },

    # Fuzzy duplicate threshold
    "SIMILARITY_THRESHOLD": 0.90,  # for descriptions

    # Repeated starters & adjectives
    "REPEATED_STARTER_THRESHOLD": 3,
    "ADJECTIVE_THRESHOLD": 2,

    # Alpha sort key: ignore leading "The " and stars
    "IGNORE_PREFIXES": ["The ", "the "],

    # H2 headings that contain station categories as sub-headings.
    # Update this list if the README headings change.
    "STATION_H2_HEADINGS": {
        'The Station Directory',
        'Experimental, Nerdy & Scanners',
        'Multi-Station Networks',
    },
}

# Common adjectives to watch (extended)
COMMON_ADJECTIVES = [
    "independent", "experimental", "unique", "carefully", "legendary",
    "community", "underground", "freeform", "alternative", "classic",
    "contemporary", "rare", "deep", "dark", "ambient", "electronic",
    "acoustic", "live", "original", "local", "global", "eclectic",
    "authentic", "organic", "soulful", "modern", "vintage"
]

DASH_CHARS = "\u2014\u2013\u2212"
HEADING_RE = re.compile(r'^(#{2,4})\s+(?P<title>.*?)(?:\s*<a id="(?P<anchor>[^"]+)"></a>)?\s*$')
ENTRY_RE = re.compile(r'^\s*-\s+(?:\u2b50\s+)?\[(?P<name>[^\]]+)\]\((?P<url>[^)]*)\)\s*:?\s*(?P<rest>.*)$')
STAR_RE = re.compile(r'^\s*-\s+(\u2b50)(\s*)\[')
LINK_RE = re.compile(r'\[[^\]]*\]\((?P<url>[^)]+)\)')
TOC_LINK_RE = re.compile(r'\[(?P<text>[^\]]+)\]\(#(?P<slug>[^)]+)\)')

# ----------------------------------------------------------------------------
# README PARSER -> in-memory Repository model
# ----------------------------------------------------------------------------
class Station:
    __slots__ = ('name', 'homepage', 'stream_urls', 'description', 'line_no', 'starred')
    def __init__(self, name, homepage, stream_urls, description, line_no, starred=False):
        self.name = name
        self.homepage = homepage
        self.stream_urls = stream_urls
        self.description = description
        self.line_no = line_no
        self.starred = starred

class Category:
    __slots__ = ('title', 'heading_line', 'stations')
    def __init__(self, title, heading_line):
        self.title = title
        self.heading_line = heading_line
        self.stations = []

class Repository:
    def __init__(self):
        self.categories = []          # list of Category
        self.all_stations = []        # flat list for global checks
        self.headings = []            # (line, level, title, anchor, effective)

def parse_readme(path):
    with open(path, encoding='utf-8') as f:
        lines = f.readlines()

    repo = Repository()
    current_cat = None
    in_code = False

    # First pass: collect headings and anchors
    headings = []
    for i, raw in enumerate(lines, 1):
        if raw.strip().startswith('```'):
            in_code = not in_code
            continue
        if in_code:
            continue
        m = HEADING_RE.match(raw.rstrip('\n'))
        if m and raw.startswith('#'):
            level = len(m.group(1))
            title = m.group('title').strip()
            anchor = m.group('anchor')
            effective = anchor or gh_slug(title)
            headings.append((i, level, title, anchor, effective))
    repo.headings = headings

    # Second pass: determine category hierarchy and parse entries
    current_h2 = None
    current_group = None  # Category
    in_code = False
    station_h2s = CONFIG['STATION_H2_HEADINGS']

    for i, raw in enumerate(lines, 1):
        stripped = raw.rstrip('\n')
        if stripped.strip().startswith('```'):
            in_code = not in_code
            continue
        if in_code:
            continue

        # Heading
        m = HEADING_RE.match(stripped)
        if m and raw.startswith('#'):
            level = len(m.group(1))
            title = m.group('title').strip()
            if level == 2:
                current_h2 = title
                current_group = None
            elif level >= 3 and current_h2 in station_h2s:
                # This is a station category (e.g., ### Ambient, #### Jazz)
                current_group = Category(title, i)
                repo.categories.append(current_group)
            else:
                current_group = None
            continue

        # Station entry
        if current_group is None:
            continue
        m = ENTRY_RE.match(stripped)
        if not m:
            continue
        # Extract data
        name = m.group('name').strip()
        homepage = m.group('url').strip()
        rest = m.group('rest').strip()
        # Skip nav links
        if homepage.startswith('#'):
            continue

        # Extract stream URLs
        stream_urls = [u for u in LINK_RE.findall(stripped) if u.startswith(('http://', 'https://'))]
        desc = re.sub(r'\[[^\]]*\]\([^)]*\)', '', rest).strip()
        starred = bool(re.search(r'^\u2b50', stripped))
        station = Station(name, homepage, stream_urls, desc, i, starred)
        current_group.stations.append(station)
        repo.all_stations.append(station)

    return repo, lines  # return lines so callers don't need to re-open the file

def gh_slug(title):
    s = title.strip().lower()
    s = s.replace('&', '')
    s = re.sub(r'[^\w\s-]', '', s)
    s = s.strip().replace(' ', '-')
    s = re.sub(r'-+', '-', s)
    return s

def sort_key(name):
    n = name.strip()
    n = re.sub(r'^\u2b50\s*', '', n)
    for p in CONFIG['IGNORE_PREFIXES']:
        if n.startswith(p):
            n = n[len(p):]
            break
    n = unicodedata.normalize('NFD', n)
    n = ''.join(c for c in n if not unicodedata.combining(c))
    return n.lower()

def word_count(text):
    stripped = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', text)
    stripped = re.sub(r'[*_`]', '', stripped)
    return len(stripped.split())

def sentences(text):
    return re.split(r'[.!?]\s+', text)

def similarity(a, b):
    return difflib.SequenceMatcher(None, a, b).ratio()

# ----------------------------------------------------------------------------
# Main checks
# ----------------------------------------------------------------------------
def main(path):
    repo, raw_lines = parse_readme(path)  # raw_lines cached here, not re-opened per station

    findings = []  # (line_no, severity, message)

    def add(line_no, sev, msg):
        findings.append((line_no, sev, msg))

    # 1. Headings / TOC anchors
    valid_anchors = {h[4] for h in repo.headings}
    in_toc = False
    for i, raw in enumerate(raw_lines, 1):
        if raw.startswith('## Contents'):
            in_toc = True
            continue
        if in_toc and raw.startswith('## ') and 'Contents' not in raw:
            in_toc = False
        if in_toc:
            for tm in TOC_LINK_RE.finditer(raw):
                if tm.group('slug') not in valid_anchors:
                    add(i, 'WARN', f'Contents link #{tm.group("slug")} has no matching anchor')

    # 2. Walk categories and stations
    category_counts = {}
    all_description_words = []
    all_names = set()
    name_to_line = {}
    homepage_to_line = {}
    stream_to_line = {}
    desc_to_lines = defaultdict(list)   # for fuzzy duplicates
    sentence_starters = Counter()
    adjective_counter = Counter()

    for cat in repo.categories:
        stations = cat.stations
        category_counts[cat.title] = len(stations)

        # Alpha order check - full pass within this section only
        sorted_stations = sorted(stations, key=lambda s: sort_key(s.name))
        sorted_names = [s.name for s in sorted_stations]
        for idx, st in enumerate(stations):
            expected_idx = sorted_names.index(st.name)
            if expected_idx != idx:
                if expected_idx + 1 < len(sorted_names):
                    should_precede = sorted_stations[expected_idx + 1]
                    add(st.line_no, 'WARN',
                        f"Move '{st.name}' (line {st.line_no}) up — should come before '{should_precede.name}' (line {should_precede.line_no})")

        # Check each station
        for st in stations:
            # Duplicate names
            k = sort_key(st.name)
            if k in name_to_line:
                prev_line, prev_name = name_to_line[k]
                add(st.line_no, 'WARN', f"Duplicate station name '{st.name}' (also at line {prev_line})")
            else:
                name_to_line[k] = (st.line_no, st.name)

            # Duplicate homepage
            if st.homepage:
                if st.homepage in homepage_to_line:
                    pl, pn = homepage_to_line[st.homepage]
                    add(st.line_no, 'WARN', f"Duplicate homepage URL '{st.homepage}' (also used by '{pn}' at line {pl})")
                else:
                    homepage_to_line[st.homepage] = (st.line_no, st.name)

            # Duplicate stream URLs
            for su in st.stream_urls:
                if su in stream_to_line:
                    pl, pn = stream_to_line[su]
                    add(st.line_no, 'WARN', f"Duplicate stream URL '{su}' (also used by '{pn}' at line {pl})")
                else:
                    stream_to_line[su] = (st.line_no, st.name)

            # Banned words (ERROR)
            desc_lower = st.description.lower()
            for bw, reason in CONFIG['BANNED_WORDS'].items():
                if bw.lower() in desc_lower:
                    add(st.line_no, 'ERROR', f"Banned phrase '{bw}' - {reason}")
            # Discouraged words (WARN) - now includes description preview
            for dw, reason in CONFIG['DISCOURAGED_WORDS'].items():
                if dw.lower() in desc_lower:
                    desc_preview = st.description[:50] + ("..." if len(st.description) > 50 else "")
                    add(st.line_no, 'WARN', f"Discouraged word '{dw}' - {reason} in: \"{desc_preview}\"")

            # Description length (min, soft, hard) - with preview
            wc = word_count(st.description)
            all_description_words.append(wc)
            if wc < CONFIG['MIN_DESC_WORDS']:
                desc_preview = st.description[:50] + ("..." if len(st.description) > 50 else "")
                add(st.line_no, 'WARN', f"Description too short ({wc} words, min {CONFIG['MIN_DESC_WORDS']}): \"{desc_preview}\"")
            elif wc > CONFIG['HARD_DESC_WORDS']:
                desc_preview = st.description[:50] + ("..." if len(st.description) > 50 else "")
                add(st.line_no, 'WARN', f"Description too long ({wc} words, cap {CONFIG['HARD_DESC_WORDS']}): \"{desc_preview}\"")
            elif wc > CONFIG['SOFT_DESC_WORDS']:
                add(st.line_no, 'INFO', f"Description long ({wc} words, soft cap {CONFIG['SOFT_DESC_WORDS']})")

            # Star format - use cached raw_lines instead of re-opening the file
            if st.starred and not STAR_RE.match(raw_lines[st.line_no - 1]):
                add(st.line_no, 'INFO', "Star not in '⭐ [' format")

            # No stream link (info)
            if not st.stream_urls:
                add(st.line_no, 'INFO', "No stream link found (homepage only)")

            # Sentence starters
            for sent in sentences(st.description):
                sent = sent.strip()
                if len(sent) > 10:
                    words = sent.split()[:5]
                    starter = ' '.join(words)
                    if len(starter) > 3:
                        sentence_starters[starter] += 1

            # Adjective frequency
            desc_words = st.description.lower().split()
            for adj in COMMON_ADJECTIVES:
                if adj in desc_words:
                    adjective_counter[adj] += 1

    # 3. Fuzzy duplicate descriptions
    desc_texts = {}
    for st in repo.all_stations:
        if not st.description:
            continue
        desc_texts[st.line_no] = st.description
    desc_lines = list(desc_texts.keys())
    for i in range(len(desc_lines)):
        for j in range(i+1, len(desc_lines)):
            li, lj = desc_lines[i], desc_lines[j]
            sim = similarity(desc_texts[li], desc_texts[lj])
            if sim >= CONFIG['SIMILARITY_THRESHOLD'] and li != lj:
                add(li, 'WARN', f"Fuzzy duplicate description (similarity {sim:.0%}) with line {lj}: '{desc_texts[li][:50]}...'")

    # 4. Statistics
    total_stations = len(repo.all_stations)
    if total_stations > 0:
        add(0, 'INFO', f"Repository Statistics:")
        add(0, 'INFO', f"  Stations...............{total_stations}")
        add(0, 'INFO', f"  Categories.............{len(repo.categories)}")
        if all_description_words:
            avg = sum(all_description_words) / len(all_description_words)
            med = median(all_description_words)
            add(0, 'INFO', f"  Avg description.......{avg:.1f} words")
            add(0, 'INFO', f"  Median description....{med:.1f} words")
            add(0, 'INFO', f"  Longest description...{max(all_description_words)} words")
            add(0, 'INFO', f"  Shortest description..{min(all_description_words)} words")
        dup_home = len(homepage_to_line) - len(set(homepage_to_line.values()))
        dup_stream = len(stream_to_line) - len(set(stream_to_line.values()))
        exact_desc_counts = Counter(desc_texts.values())
        dup_desc = sum(c - 1 for c in exact_desc_counts.values() if c > 1)
        add(0, 'INFO', f"  Duplicate homepages...{dup_home}")
        add(0, 'INFO', f"  Duplicate streams.....{dup_stream}")
        add(0, 'INFO', f"  Duplicate descriptions.{dup_desc}")

        # Adjective frequency
        adj_freq = {k: v for k, v in adjective_counter.items() if v >= CONFIG['ADJECTIVE_THRESHOLD']}
        if adj_freq:
            add(0, 'INFO', f"  Adjective frequency...{dict(sorted(adj_freq.items(), key=lambda x: -x[1]))}")

        # Repeated sentence starters
        repeated = {k: v for k, v in sentence_starters.items() if v >= CONFIG['REPEATED_STARTER_THRESHOLD']}
        if repeated:
            add(0, 'INFO', f"  Repeated starters.....{dict(sorted(repeated.items(), key=lambda x: -x[1]))}")

        # Category distribution bar chart (Unicode)
        add(0, 'INFO', "Category Distribution (bars = relative size):")
        max_count = max(category_counts.values()) if category_counts else 1
        for cat, count in sorted(category_counts.items(), key=lambda x: -x[1]):
            bar_len = int(30 * count / max_count)
            bar = '█' * bar_len
            add(0, 'INFO', f"  {cat:20} {count:3} {bar}")

    # 5. Back-to-top placeholder (currently skipped, reserved for future check)

    # 6. Report
    findings.sort(key=lambda x: (x[0], {'ERROR':0, 'WARN':1, 'INFO':2}[x[1]]))
    counts = Counter(sev for _, sev, _ in findings)

    for line_no, sev, msg in findings:
        prefix = f"{path}:{line_no:<5} {sev:<6}" if line_no != 0 else f"{path}: summary {sev:<6}"
        print(f"{prefix} {msg}")

    print()
    summary = f"{counts['ERROR']} errors, {counts['WARN']} warnings, {counts['INFO']} info"
    print(summary)

    # GitHub Step Summary
    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        errors   = [(ln, msg) for ln, sev, msg in findings if sev == 'ERROR']
        warnings = [(ln, msg) for ln, sev, msg in findings if sev == 'WARN']
        infos    = [(ln, msg) for ln, sev, msg in findings if sev == 'INFO']

        # Partition warnings into actionable groups
        alpha    = [(ln, msg) for ln, msg in warnings if msg.startswith('Move ')]
        short    = [(ln, msg) for ln, msg in warnings if msg.startswith('Description too short')]
        dupes    = [(ln, msg) for ln, msg in warnings if 'Duplicate' in msg]
        banned   = [(ln, msg) for ln, msg in warnings if msg.startswith('Banned')]
        disc     = [(ln, msg) for ln, msg in warnings if msg.startswith('Discouraged')]
        other_w  = [(ln, msg) for ln, msg in warnings
                    if not any(msg.startswith(p) for p in ('Alpha order', 'Description too short', 'Banned', 'Discouraged'))
                    and 'Duplicate' not in msg]

        # Stats and category distribution from infos
        stats    = [(ln, msg) for ln, msg in infos if 'Statistics' in msg or msg.startswith('  ') and 'Distribution' not in msg]
        cat_dist = [(ln, msg) for ln, msg in infos if 'Distribution' in msg or (msg.startswith('  ') and any(c in msg for c in [cat for cat, _ in category_counts.items()]))]

        with open(step_summary, 'a', encoding='utf-8') as f:
            # Header
            errors_icon   = '🔴' if errors else '✅'
            warnings_icon = '🟡' if warnings else '✅'
            f.write("# README Lint Report\n\n")
            f.write(f"{errors_icon} **{counts['ERROR']} errors** &nbsp; {warnings_icon} **{counts['WARN']} warnings** &nbsp; ℹ️ **{counts['INFO']} info**\n\n")

            # Errors (rare but important)
            if errors:
                f.write("## 🔴 Errors\n\n")
                f.write("| Line | Issue |\n|---|---|\n")
                for ln, msg in errors:
                    f.write(f"| {ln} | {msg.replace('|', chr(124))} |\n")
                f.write("\n")

            # Alpha order fixes
            if alpha:
                f.write("## 🔤 Alpha Order Fixes\n\n")
                f.write("| Line | Fix |\n|---|---|\n")
                for ln, msg in alpha:
                    # Extract just the station names for a cleaner display
                    f.write(f"| {ln} | {msg.replace('|', chr(124))} |\n")
                f.write("\n")

            # Short descriptions
            if short:
                f.write("## ✏️ Descriptions Too Short\n\n")
                f.write("| Line | Issue |\n|---|---|\n")
                for ln, msg in short:
                    f.write(f"| {ln} | {msg.replace('|', chr(124))} |\n")
                f.write("\n")

            # Duplicate URLs (sub-channels share homepages - usually expected)
            if dupes:
                f.write("<details><summary>🔁 Duplicate URLs (%d) — usually expected for sub-channels</summary>\n\n" % len(dupes))
                f.write("| Line | Issue |\n|---|---|\n")
                for ln, msg in dupes:
                    f.write(f"| {ln} | {msg.replace('|', chr(124))} |\n")
                f.write("\n</details>\n\n")

            # Banned words
            if banned:
                f.write("## 🚫 Banned Words\n\n")
                f.write("| Line | Issue |\n|---|---|\n")
                for ln, msg in banned:
                    f.write(f"| {ln} | {msg.replace('|', chr(124))} |\n")
                f.write("\n")

            # Discouraged words (collapsed - very noisy due to 'community')
            if disc:
                f.write("<details><summary>⚠️ Discouraged Words (%d) — review manually</summary>\n\n" % len(disc))
                f.write("| Line | Issue |\n|---|---|\n")
                for ln, msg in disc:
                    f.write(f"| {ln} | {msg.replace('|', chr(124))} |\n")
                f.write("\n</details>\n\n")

            # Other warnings
            if other_w:
                f.write("## ⚠️ Other Warnings\n\n")
                f.write("| Line | Issue |\n|---|---|\n")
                for ln, msg in other_w:
                    f.write(f"| {ln} | {msg.replace('|', chr(124))} |\n")
                f.write("\n")

            # Stats (collapsed)
            f.write("<details><summary>📊 Repository Statistics</summary>\n\n")
            f.write("| Metric | Value |\n|---|---|\n")
            f.write(f"| Stations | {total_stations} |\n")
            f.write(f"| Categories | {len(repo.categories)} |\n")
            if all_description_words:
                avg = sum(all_description_words) / len(all_description_words)
                med = median(all_description_words)
                f.write(f"| Avg description | {avg:.1f} words |\n")
                f.write(f"| Median description | {med:.1f} words |\n")
                f.write(f"| Longest description | {max(all_description_words)} words |\n")
                f.write(f"| Shortest description | {min(all_description_words)} words |\n")
            f.write("\n")

            # Category distribution as a table (no Unicode bars - renders badly)
            f.write("**Category sizes:**\n\n")
            f.write("| Category | Stations |\n|---|---|\n")
            for cat, count in sorted(category_counts.items(), key=lambda x: -x[1]):
                f.write(f"| {cat} | {count} |\n")
            f.write("\n</details>\n")

    return 0

if __name__ == '__main__':
    if len(sys.argv) != 2:
        print("usage: python lint_readme.py README.md", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
