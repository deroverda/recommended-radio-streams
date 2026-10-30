#!/usr/bin/env python3
"""Check the README: spelling everywhere, format and wording rules on station entries.

Usage: python3 readme_check.py README.md [misspellings.tsv]

Prints one GitHub warning annotation per problem and always exits 0,
because some rules (word count, banned words) can hit legitimate lines.
"""
import os
import re
import sys

BANNED = [
    "24/7", "ad-free", "sonic art", "internet radio", "web radio", "number one",
    "#1", "top rated", "ultimate", "premier", "leading", "diverse", "nestled",
    "thriving", "showcase", "boast", "community-driven", "best-in-class",
    "world-class", "curated", "eclectic", "platform", "hub", "programming",
    "delve", "tapestry", "game-changer", "seamless", "leverage", "unleash",
    "underscore", "testament", "embark", "elevate", "harness", "captivate",
    "ever-evolving", "cutting-edge", "robust", "comprehensive", "utilize",
    "pivotal", "synergy", "holistic", "myriad", "plethora", "paramount",
    "streamline", "empower", "facilitate", "enhance", "garner", "interplay",
]
MAX_WORDS = 16

# Words the misspelling list flags but that are correct in this README.
SPELLING_OK = set()

# Words a banned term's regex also catches but that are fine.
BANNED_OK = {"premiere", "premieres"}

CANDIDATE_RE = re.compile(r"^- (?:⭐ ?)?\[[^\]]+\]\(https?://")
HEAD_RE = re.compile(r"^- (?:⭐ )?\[[^\]]+\]\(https?://[^)\s]+\): (?P<rest>.*)$")
# The description ends where the *(down)* tag or the first link starts.
DESC_END_RE = re.compile(r" \*\(down\)\*| \[[^\]]+\]\(https?://| \(\[")
WORD_RE = re.compile(r"[A-Za-z]+(?:'[A-Za-z]+)?")


def banned_regex(term):
    # Any ending form: -s, -es, -d, -ed, -ing, -ers (e.g. showcases, curated).
    stem = term[:-1] if term.endswith("e") and term[-2:] not in ("ee",) else term
    ends = r"(?:e|es|s|d|ed|ing|er|ers)?" if stem != term else r"(?:s|es|ed|d|ing|er|ers)?"
    return re.compile(r"(?<![\w-])" + re.escape(stem) + ends + r"(?![\w-])", re.I)


BANNED_RES = [(t, banned_regex(t)) for t in BANNED]


def load_misspellings(path):
    table = {}
    if path and os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                if line.startswith("#") or "\t" not in line:
                    continue
                wrong, right = line.rstrip("\n").split("\t", 1)
                table[wrong] = right
    return table


def check(readme, misspell_path):
    misspellings = load_misspellings(misspell_path)
    problems = []
    with open(readme, encoding="utf-8") as f:
        lines = f.read().splitlines()
    for n, line in enumerate(lines, 1):
        if not CANDIDATE_RE.match(line):
            continue
        m = HEAD_RE.match(line)
        if not m:
            problems.append((n, "entry does not start with '- [Name](homepage): '"))
            continue
        desc = DESC_END_RE.split(m.group("rest"), 1)[0].strip()
        if not re.search(r"[.!?][\"']?$", desc):
            problems.append((n, "description does not end with a period"))
        if ";" in desc:
            problems.append((n, "semicolon in description, use a comma"))
        words = len(desc.split())
        if words > MAX_WORDS:
            problems.append((n, f"description has {words} words (cap {MAX_WORDS})"))
        for term, rx in BANNED_RES:
            hit = rx.search(desc)
            if hit and hit.group(0).lower() not in BANNED_OK:
                problems.append((n, f"banned word '{hit.group(0)}'"))
    problems += spelling(lines, misspellings)
    problems.sort(key=lambda p: p[0])
    return problems


# Parts of a line that are not prose: inline code, link targets, HTML tags, bare URLs.
NOT_PROSE_RE = re.compile(r"`[^`]*`|\]\([^)]*\)|<[^>]*>|https?://\S+")


def spelling(lines, misspellings):
    """Spell check every prose line of the README, skipping fenced code blocks."""
    problems = []
    in_code = False
    for n, line in enumerate(lines, 1):
        if line.lstrip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        for w in WORD_RE.findall(NOT_PROSE_RE.sub(" ", line)):
            low = w.lower()
            if low in misspellings and low not in SPELLING_OK:
                problems.append((n, f"possible misspelling '{w}' -> '{misspellings[low]}'"))
    return problems


def main():
    readme = sys.argv[1] if len(sys.argv) > 1 else "README.md"
    misspell_path = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "misspellings.tsv")
    problems = check(readme, misspell_path)
    for n, msg in problems:
        print(f"::warning file={readme},line={n}::{msg}")
        print(f"Line {n}: {msg}")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"README check: {len(problems)} warning(s).\n\n")
            for n, msg in problems:
                f.write(f"- Line {n}: {msg}\n")
    print(f"{len(problems)} warning(s).")


if __name__ == "__main__":
    main()
