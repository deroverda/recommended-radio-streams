#!/usr/bin/env bash
# probe-streams.sh - v4.0
# Probes every stream URL in README.md, in parallel, for actual decodable audio.
# Produces a structured markdown report.
#
# Design principle: this script is a health check, not a quality analyser.
# Its job is to find dead or broken streams and flag them for manual review.
# Codec/bitrate scoring has been removed (v4.0) - HLS streams report misleading
# bitrate values from manifest headers rather than actual encoded bitrate, making
# any quality table unreliable. Use the local PowerShell script for quality
# assessment.
#
# What it does:
# - Probes every stream URL with ffmpeg (parallel, capped at $JOBS).
# - Resolves .pls/.m3u/.asx playlist files to their inner URLs first.
# - Separates genuine probe failures from runner-blocked streams (datacenter
#   IP blocks produce AUTH_REQUIRED/TIMEOUT/CONNECTION_RESET but the stream
#   works fine from a residential IP).
# - Includes Section and Station name in failure tables so you can find the
#   README entry without grepping.
#
# Carried forward from v3.x:
# - Parallel probing via forked subshells (inherit all functions/vars via
#   copy-on-write, no sourcing or exporting needed).
# - Playlist resolution up to $MAX_PLAYLIST_DEPTH levels deep.
# - HLS (.m3u8) passed directly to ffmpeg, not treated as a playlist to
#   grep - ffmpeg has a native HLS demuxer.
# - Retry logic with exponential backoff.
# - Station names and sections parsed from README once up front (python3).
#
# No "set -e": errors are handled manually per-probe so one bad stream never
# aborts the whole run.

set -uo pipefail

# ----------------------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------------------
UA="${UA:-Mozilla/5.0}"
README_FILE="${README_FILE:-README.md}"
REPORT="${REPORT:-stream-report.md}"
JOBS="${JOBS:-8}"
DECODE_SECONDS="${DECODE_SECONDS:-8}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-30}"
PLAYLIST_TIMEOUT="${PLAYLIST_TIMEOUT:-15}"
MAX_RETRIES="${MAX_RETRIES:-2}"
RETRY_BASE_DELAY="${RETRY_BASE_DELAY:-2}"
MAX_PLAYLIST_DEPTH="${MAX_PLAYLIST_DEPTH:-3}"
STATE_FILE="${STATE_FILE:-.github/probe-state.json}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is required." >&2; exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2; exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required." >&2; exit 2
fi
if [ ! -f "$README_FILE" ]; then
  echo "Error: $README_FILE not found." >&2; exit 2
fi

# ----------------------------------------------------------------------------
# Helper functions
# ----------------------------------------------------------------------------
extract_stream_urls() {
  # Derived from build_name_map (defined below) so both use the same parser -
  # including the trailing "/"-joined chain that catches custom sub-stream
  # labels like "[Bluemars](url) / [Cryosleep](url)".
  build_name_map | cut -f1 | sort -u
}

# Parses README.md once and emits url<TAB>name<TAB>section for every stream
# link. Uses the same ENTRY_RE/STREAM_RE as readme_to_m3u.py for consistency.
# HTML tags (e.g. <a id="...">) are stripped from section headings.
build_name_map() {
  python3 - "$README_FILE" <<'PYEOF'
import re
import sys

ENTRY_RE = re.compile(
    r'^-\s*(?:\u2b50\s*)?\[(?P<name>[^\]]+)\]\((?P<homepage>[^)]+)\):\s*'
    r'(?P<desc>.*)$'
)
STREAM_RE = re.compile(r'\[(Stream|Channel\s*[12]|[12])\]\((?P<url>[^)]+)\)', re.I)
# Custom sub-stream labels ("[Bluemars](url) / [Cryosleep](url)") aren't in
# STREAM_RE's whitelist. Accept any label when it's part of the "/"-joined
# chain of links at the very end of the line - the end-of-line anchor keeps
# this from matching an inline description link that sits before trailing text.
# The optional trailing group tolerates one "*(down ...)*" note (same shape as
# the down= detector below) so a down-tagged multi-stream entry is still parsed.
# This regex is duplicated in readme_to_m3u.py and in link-check.yml's
# "Exclude stream URLs" step - keep all three identical.
STREAM_CHAIN_RE = re.compile(
    r'(?:\[[^\]]+\]\([^)]+\)\s*/\s*)*\[[^\]]+\]\([^)]+\)\s*'
    r'(?:\*\(\s*down\b[^)]*\)\*?\s*)?$'
)
STREAM_LINK_RE = re.compile(r'\[[^\]]+\]\((?P<url>[^)]+)\)')
HEADING_RE = re.compile(r'^#{2,4}\s+(.*)')


def entry_stream_urls(line):
    """URLs for a README entry line's stream link(s), any label."""
    m = STREAM_CHAIN_RE.search(line)
    if m:
        urls = STREAM_LINK_RE.findall(m.group(0))
        if urls:
            return urls
    return [u for _label, u in STREAM_RE.findall(line)]


path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    lines = f.readlines()

current_section = '-'
for raw in lines:
    s = raw.strip()
    hm = HEADING_RE.match(s)
    if hm:
        title = hm.group(1)
        # Strip markdown links: [text](url) -> text
        title = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', title)
        # Strip HTML tags: <a id="...">, </a>, etc.
        title = re.sub(r'<[^>]+>', '', title).strip()
        current_section = title or '-'
        continue
    m = ENTRY_RE.match(s)
    if not m:
        continue
    name = re.sub(r'\*+', '', m.group('name')).strip()
    # 4th field: 1 if the entry line carries a "*(down ...)*" status note.
    # Lets the report separate "already known down" from unexpected failures.
    # Matches the established form only: "*(" then "down". A bare "*down*"
    # would risk colliding with ordinary italic text elsewhere in the README.
    down = '1' if re.search(r'\*\(\s*down\b', s, re.I) else '0'
    for url in entry_stream_urls(s):
        print(f"{url}\t{name}\t{current_section}\t{down}")
PYEOF
}

# Collapse whitespace, cut to 200 chars at a word boundary, then escape table
# pipes. Escaping goes last so the cut cannot split a "\|" pair.
sanitize_text() {
  local out
  out=$(printf '%s' "$1" \
    | tr '\n\t' ' ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  if [ "${#out}" -gt 200 ]; then
    out="${out:0:200}"
    out="${out% *}..."
  fi
  # "${out//|/\\|}" collapses to a bare "|" in bash replacement - use a var.
  local bs='\'
  out=${out//|/${bs}|}
  printf '%s' "$out"
}

# Emits a failure table sorted by the consecutive-run count (first tab field of
# each row, stripped before printing). Ascending: a "1" (first-time failure this
# run) floats to the top as the new decision to make; long-running rows sink.
emit_failure_table() {
  local rows="$1"
  if [ -n "$rows" ]; then
    echo "| Section | Station | URL | Result | Runs | Details |"
    echo "|---|---|---|---|---|---|"
    printf '%s' "$rows" | sort -t"$(printf '\t')" -k1,1n | cut -f2-
  else
    echo "_None._"
  fi
}

classify_error() {
  # Strip the probed URL out of the error text before matching - ffmpeg
  # echoes the URL into its own failure output (e.g. "Error opening input
  # file https://.../stream/534044."), and a URL containing digits like
  # "404" would otherwise decide the classification instead of the actual
  # error. $3 is quoted so a URL with glob characters (many carry a "?"
  # query string) is matched literally, not as a pattern.
  local err="${1//"$3"/}"
  local code="${2:-0}"
  case "$err" in
    *"Name or service not known"*|*"No address associated"*|*"Could not resolve host"*|*"Temporary failure"*)
      echo "DNS_FAILURE" ;;
    *"SSL"*|*"certificate"*|*"TLS"*|*"handshake"*)
      echo "SSL_FAILURE" ;;
    *"timed out"*)
      echo "TIMEOUT" ;;
    *"Connection refused"*|*"Connection reset"*)
      echo "CONNECTION_RESET" ;;
    *"403"*|*"401"*|*"Forbidden"*|*"Unauthorized"*)
      echo "AUTH_REQUIRED" ;;
    *"429"*|*"Too Many Requests"*|*"522"*)
      echo "RATE_LIMITED" ;;
    *"404"*|*"Not Found"*)
      echo "NOT_FOUND" ;;
    *"5XX"*)
      # ffmpeg's libavutil groups every 500-599 response into this exact
      # literal string - it never prints the real status (500 vs 503 vs
      # 504 are indistinguishable to us). Without this case, every 5xx
      # response fell through to UNKNOWN and got reported as an
      # unexplained "unexpected failure" instead of a labeled server error.
      echo "SERVER_ERROR" ;;
    *"4XX"*)
      # Same grouping ffmpeg does for any 4xx code other than 400/401/403/404,
      # which do get their own specific number and are matched above.
      echo "CLIENT_ERROR" ;;
    *"Unsupported codec"*|*"codec not found"*)
      echo "UNSUPPORTED_CODEC" ;;
    *"Invalid data found"*)
      echo "PLAYLIST_PARSE_ERROR" ;;
    *"low score"*|*"misdetection"*)
      echo "UNSUPPORTED_FORMAT" ;;
    *"playlist"*|*"M3U"*|*"PLS"*)
      echo "PLAYLIST_PARSE_ERROR" ;;
    *"redirect"*)
      echo "REDIRECT_LOOP" ;;
    *)
      if [ "$code" -eq 124 ] 2>/dev/null; then
        echo "TIMEOUT"
      else
        echo "UNKNOWN"
      fi
      ;;
  esac
}

probe_one_url() {
  local url="$1"
  local attempt=1
  local delay="$RETRY_BASE_DELAY"
  # Initialised so the classify_error call below has defined values even if the
  # loop body never runs (MAX_RETRIES <= 0). Note: the loop treats MAX_RETRIES
  # as a total attempt count, not "retries on top of one try".
  local err="" status=1

  RESULT_CLASS="UNKNOWN"
  RESULT_DETAIL=""

  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    # One ffmpeg connection is the whole health check: connect, decode
    # $DECODE_SECONDS of audio, check the exit status. An earlier version
    # made a second connection whose exit status was never checked, so a
    # stream whose second connection failed (403, timeout, whatever) still
    # got reported OK.
    #
    # -v warning keeps $err from filling up with the Input/Stream mapping/
    # Output banner that -v info adds (sanitize_text only keeps the first
    # 200 chars, so that banner would crowd out the real error on a failure).
    err=$(timeout "$PROBE_TIMEOUT" ffmpeg \
      -hide_banner -v warning -nostdin \
      -user_agent "$UA" \
      -headers $'Accept: */*\r\n' \
      -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
      -i "$url" \
      -map 0:a:0 -vn -sn -dn \
      -t "$DECODE_SECONDS" \
      -f null - \
      2>&1)
    status=$?

    if [ "$status" -eq 0 ]; then
      RESULT_CLASS="OK"
      RESULT_DETAIL=""
      return 0
    fi

    attempt=$((attempt + 1))
    if [ "$attempt" -le "$MAX_RETRIES" ]; then
      sleep "$delay"
      delay=$((delay * 2))
    fi
  done

  RESULT_CLASS=$(classify_error "$err" "$status" "$url")
  RESULT_DETAIL=$(sanitize_text "$err")
  [ -z "$RESULT_DETAIL" ] && RESULT_DETAIL="exit $status"
  return 1
}

is_playlist_url() {
  local url_lc
  url_lc=$(echo "$1" | tr '[:upper:]' '[:lower:]')
  # .m3u8 (HLS) is deliberately excluded: ffmpeg handles it natively via its
  # HLS demuxer. Treating it as a plain playlist to grep for URLs fails because
  # HLS manifests use directives and often relative paths.
  case "$url_lc" in
    *.pls|*.pls\?*|*.m3u|*.m3u\?*|*.asx|*.asx\?*|*.xspf|*.xspf\?*) return 0 ;;
    *) return 1 ;;
  esac
}

probe_url() {
  local url="$1"
  local depth="${2:-1}"
  RESULT_CLASS="UNKNOWN"
  RESULT_DETAIL=""

  if is_playlist_url "$url" && [ "$depth" -le "$MAX_PLAYLIST_DEPTH" ]; then
    local content inner_urls
    # tr -d '\r': .pls/.m3u files are frequently CRLF, and the "File1=" sed
    # path below does not strip the trailing \r - it would reach ffmpeg as
    # part of the URL and fail an otherwise-working stream.
    content=$(curl -fsSL --max-time "$PLAYLIST_TIMEOUT" --retry 2 --retry-delay 2 \
      -A "$UA" "$url" 2>/dev/null | head -c 65536 | tr -d '\r')
    if [ -z "$content" ]; then
      RESULT_CLASS="EMPTY_PLAYLIST"
      RESULT_DETAIL="no content fetched"
      return 1
    fi
    inner_urls=$(echo "$content" | grep -oE '^https?://[^[:space:]]+' || true)
    [ -z "$inner_urls" ] && inner_urls=$(echo "$content" | grep -i '^File[0-9]*=' | sed -E 's/^File[0-9]*=//' || true)
    [ -z "$inner_urls" ] && inner_urls=$(echo "$content" | grep -oE 'https?://[^[:space:]<"'"'"']+' | sort -u || true)
    if [ -z "$inner_urls" ]; then
      RESULT_CLASS="EMPTY_PLAYLIST"
      RESULT_DETAIL="no inner URLs found"
      return 1
    fi
    while IFS= read -r inner; do
      [ -z "$inner" ] && continue
      probe_url "$inner" $((depth + 1))
      [ "$RESULT_CLASS" = "OK" ] && return 0
    done <<< "$inner_urls"
    return 1
  fi

  probe_one_url "$url"
  return $?
}

# ----------------------------------------------------------------------------
# Set up temporary directory and build station map
# ----------------------------------------------------------------------------
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

declare -A url_to_name
declare -A url_to_section
declare -A url_to_down
build_name_map > "$tmp_dir/station_map.tsv"
while IFS=$'\t' read -r u n sec down; do
  [ -z "$u" ] && continue
  url_to_name["$u"]="$n"
  url_to_section["$u"]="${sec:--}"
  url_to_down["$u"]="${down:-0}"
done < "$tmp_dir/station_map.tsv"

# Load last run's consecutive-failure counts, if any - lets the report say
# "3rd consecutive failure" instead of treating every failure as a fresh
# surprise. Missing/corrupt state file just means everyone starts at 0.
declare -A prev_fail_count
if [ -f "$STATE_FILE" ]; then
  while IFS=$'\t' read -r u c; do
    [ -z "$u" ] && continue
    prev_fail_count["$u"]="${c%$'\r'}"   # defensive: strip a stray \r if one ever shows up
  done < <(python3 - "$STATE_FILE" <<'PYEOF'
import json
import sys

path = sys.argv[1]
try:
    with open(path, encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    data = {}

for url, entry in data.items():
    print(f"{url}\t{entry.get('consecutive_failures', 0)}")
PYEOF
  )
fi

# ----------------------------------------------------------------------------
# Main - parallel probing capped at $JOBS
# Each subshell writes one 6-field TSV line to its own file; concatenated after.
# Fields: result<TAB>url<TAB>detail<TAB>name<TAB>section<TAB>down
# ----------------------------------------------------------------------------
mapfile -t urls < <(extract_stream_urls)
checked="${#urls[@]}"
# A parser regression (or a malformed README) yields zero URLs. Without this
# guard the run would still rewrite probe-state.json to "{}" further down,
# wiping every consecutive-failure streak, and commit an empty report.
if [ "$checked" -eq 0 ]; then
  echo "Error: no stream URLs parsed from $README_FILE - leaving $STATE_FILE untouched." >&2
  # Still write a report so the "Upload stream report" step has a file (it uses
  # if-no-files-found: error) and the run summary shows the reason, rather than
  # the job failing with a confusing "no files found".
  {
    echo "# Stream Probe Report - $(date -u +%F)"
    echo ""
    echo "**No stream URLs were parsed from \`$README_FILE\`.** Nothing was probed"
    echo "and \`$STATE_FILE\` was left untouched. This almost always means the"
    echo "README structure changed in a way the parser did not expect."
  } > "$REPORT"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"
  exit 3
fi
echo "Probing $checked streams (up to $JOBS in parallel)..."

i=0
for url in "${urls[@]}"; do
  i=$((i + 1))
  result_file="$tmp_dir/$i.tsv"
  (
    probe_url "$url" 1
    name="${url_to_name[$url]:-$url}"
    section="${url_to_section[$url]:--}"
    down="${url_to_down[$url]:-0}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$RESULT_CLASS" "$url" "${RESULT_DETAIL:--}" \
      "$name" "$section" "$down" > "$result_file"
    echo " [$RESULT_CLASS] $url"
  ) &
  while [ "$(jobs -r -p | wc -l)" -ge "$JOBS" ]; do
    wait -n
  done
done
wait

# Only glob numbered result files - station_map.tsv lives in the same dir
# and must not be included (different field count would corrupt the read loop).
tmp_results="$tmp_dir/all.tsv"
cat "$tmp_dir"/[0-9]*.tsv > "$tmp_results" 2>/dev/null || true

# ----------------------------------------------------------------------------
# Aggregate results
# ----------------------------------------------------------------------------
total_ok=0
manual=0
ci_blocked=0
known_down=0
known_down_recheck=0
recovered=0
# Failure-table rows are stored as "<runs><TAB>| ... |" so emit_failure_table
# can sort by the run count and then strip the key.
manual_rows=""
ci_blocked_rows=""
known_down_rows=""
known_down_recheck_rows=""
recovered_rows=""
declare -A category_counts
declare -A new_fail_count
TAB=$(printf '\t')

while IFS=$'\t' read -r result url detail name section down; do
  category_counts["$result"]=$(( ${category_counts["$result"]:-0} + 1 ))
  safe_name=$(sanitize_text "$name")
  safe_section=$(sanitize_text "$section")

  # Track the running streak for next run's comparison - reset on OK,
  # otherwise carry forward and increment. Applies to every URL regardless
  # of category so a stream's history survives it moving between buckets.
  if [ "$result" = "OK" ]; then
    new_fail_count["$url"]=0
  else
    new_fail_count["$url"]=$(( ${prev_fail_count[$url]:-0} + 1 ))
  fi
  runs="${new_fail_count[$url]}"   # 1 = first failing run; higher = ongoing

  # Entry is tagged "*(down)*" in README and probing OK again - surface it
  # as a recovery hint, still count it as OK.
  if [ "$down" = "1" ] && [ "$result" = "OK" ]; then
    recovered_rows+="| $safe_section | $safe_name | <$url> | probing OK - consider removing the *(down)* note |"$'\n'
    recovered=$((recovered + 1))
    total_ok=$((total_ok + 1))
    continue
  fi
  # Entry is tagged "*(down)*" in README and still failing. Split by whether
  # CI can actually tell it's dead. NOT_FOUND / DNS_FAILURE / SERVER_ERROR
  # and the like look the same from any IP, so "still down" is trustworthy.
  # AUTH_REQUIRED / TIMEOUT / CONNECTION_RESET / RATE_LIMITED are exactly what a
  # datacenter-IP block produces, so CI can't say whether the stream came back -
  # those go to a "recheck from home" list instead of being reported as
  # confirmed-down.
  if [ "$down" = "1" ] && [ "$result" != "OK" ]; then
    case "$result" in
      AUTH_REQUIRED|TIMEOUT|CONNECTION_RESET|RATE_LIMITED)
        known_down_recheck_rows+="${runs}${TAB}| $safe_section | $safe_name | <$url> | $result | $runs | ${detail:-} |"$'\n'
        known_down_recheck=$((known_down_recheck + 1))
        ;;
      *)
        known_down_rows+="${runs}${TAB}| $safe_section | $safe_name | <$url> | $result | $runs | ${detail:-} |"$'\n'
        known_down=$((known_down + 1))
        ;;
    esac
    continue
  fi

  case "$result" in
    OK)
      total_ok=$((total_ok + 1))
      ;;
    AUTH_REQUIRED|RATE_LIMITED|TIMEOUT|CONNECTION_RESET)
      ci_blocked_rows+="${runs}${TAB}| $safe_section | $safe_name | <$url> | $result | $runs | ${detail:-} |"$'\n'
      ci_blocked=$((ci_blocked + 1))
      ;;
    *)
      manual_rows+="${runs}${TAB}| $safe_section | $safe_name | <$url> | $result | $runs | ${detail:-} |"$'\n'
      manual=$((manual + 1))
      ;;
  esac
done < "$tmp_results"

# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------
{
  echo "# Stream Probe Report - $(date -u +%F)"
  echo ""
  echo "Checked **$checked** streams: **$total_ok** OK, **$manual** unexpected failures, **$recovered** recovered, **$known_down_recheck** tagged-down needing recheck, **$ci_blocked** CI-blocked, **$known_down** confirmed still-down."
  echo ""
  echo "Sections are ordered most-actionable first. Failure tables sort by consecutive-run count, so a **Runs** of 1 is new this week; stop reading once you hit a section with nothing to act on."
  echo ""
  echo "## Probe Failures (unexpected)"
  echo "_Streams that failed AND are not tagged \`*(down)*\` in README. These are the ones to look at. Could be genuinely dead, or the same datacenter-IP blocking seen elsewhere - verify from a residential IP before removing the README entry._"
  echo ""
  emit_failure_table "$manual_rows"
  echo ""
  echo "## Recovered"
  echo "_Tagged \`*(down)*\` in README but probing OK now. If it holds across a couple of runs, remove the status note on GitHub and drop it from standing-context.md._"
  echo ""
  if [ -n "$recovered_rows" ]; then
    echo "| Section | Station | URL | Note |"
    echo "|---|---|---|---|"
    printf '%s' "$recovered_rows"
  else
    echo "_None._"
  fi
  echo ""
  echo "## Known-Down - recheck from home"
  echo "_Tagged \`*(down)*\` in README and still failing from CI, but only with an error a datacenter-IP block also produces (401/403/429/timeout/reset). CI can't tell whether the stream recovered. Check these in VLC or foobar2000 from a home connection - if one plays, remove its \`*(down)*\` note on GitHub._"
  echo ""
  emit_failure_table "$known_down_recheck_rows"
  echo ""
  echo "## CI-Blocked (likely fine from home)"
  echo "_NOT tagged down. Failed with 401/403 (blocked), 429 (rate-limited), or a timeout/reset - all classic datacenter-IP symptoms. Almost certainly fine from a residential IP. Split by how long the block has persisted._"
  echo ""
  echo "### New or recent (Runs 1-2)"
  echo "_First blocked this run or last. Check from home; if it keeps failing it moves to Chronic._"
  echo ""
  emit_failure_table "$(printf '%s' "$ci_blocked_rows" | awk -F'\t' 'NF && $1+0 <= 2')"
  echo ""
  echo "### Chronic (Runs 3+)"
  echo "_Blocked from CI for weeks. Skip unless investigating one._"
  echo ""
  emit_failure_table "$(printf '%s' "$ci_blocked_rows" | awk -F'\t' 'NF && $1+0 >= 3')"
  echo ""
  echo "## Known-Down - confirmed"
  echo "_Tagged \`*(down)*\` and failing with an error CI can trust from any IP (404, DNS, server error). Genuinely down. Nothing to do week to week - but a high Runs count is the cue to stop keeping the entry and cut it._"
  echo ""
  emit_failure_table "$known_down_rows"
  echo ""
  echo "## Result Breakdown (appendix)"
  echo "_Every raw classification and its count, largest first. Not a triage list - a week-to-week health trend, watch UNKNOWN in particular._"
  echo ""
  echo "| Result | Count |"
  echo "|---|---|"
  for cat in "${!category_counts[@]}"; do
    printf '%s\t%s\n' "${category_counts[$cat]}" "$cat"
  done | sort -rn | while IFS=$'\t' read -r cnt cat; do
    echo "| $cat | $cnt |"
  done
} > "$REPORT"

# Persist this run's streak counts for next run's comparison. Rewritten
# from scratch each run (not merged with the old file) so a station removed
# from README.md simply stops appearing here instead of accumulating stale
# entries forever.
# Written to a temp file rather than piped - a heredoc script (the "python3 -"
# below) already occupies stdin to receive its own source, so piped data
# would silently vanish instead of reaching the script's own stdin read.
fail_count_tsv="$tmp_dir/fail_counts.tsv"
: > "$fail_count_tsv"
for url in "${!new_fail_count[@]}"; do
  printf '%s\t%s\n' "$url" "${new_fail_count[$url]}"
done > "$fail_count_tsv"

python3 - "$fail_count_tsv" "$STATE_FILE" <<'PYEOF'
import json
import sys

tsv_path, state_path = sys.argv[1], sys.argv[2]
data = {}
with open(tsv_path, encoding='utf-8') as f:
    for line in f:
        line = line.rstrip('\n')
        if not line:
            continue
        url, count = line.split('\t')
        count = int(count)
        if count == 0:
            continue  # only failures are worth persisting - absence means healthy,
                      # and it keeps the file (and its weekly commit) small
        data[url] = {"consecutive_failures": count}

with open(state_path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, sort_keys=True)
    f.write('\n')
PYEOF

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"
fi

echo "Probe complete. Report written to $REPORT"
