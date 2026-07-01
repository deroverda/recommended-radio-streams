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
# - Detects silence on otherwise-OK streams.
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
SILENCE_THRESHOLD="${SILENCE_THRESHOLD:-0.05}"
SILENCE_DURATION="${SILENCE_DURATION:-0.5}"
MAX_PLAYLIST_DEPTH="${MAX_PLAYLIST_DEPTH:-3}"

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
  grep -oE '\[(Stream|Channel [12]|[12])\]\(https?://[^)]+\)' "$README_FILE" \
    | sed -E 's/.*\((https?:\/\/[^)]+)\)/\1/' \
    | sort -u
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
HEADING_RE = re.compile(r'^#{2,4}\s+(.*)')

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
    for _label, url in STREAM_RE.findall(s):
        print(f"{url}\t{name}\t{current_section}")
PYEOF
}

sanitize_text() {
  printf '%s' "$1" \
    | tr '\n\t' ' ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s/\|/\\|/g' \
    | cut -c1-200
}

classify_error() {
  local err="$1"
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
  local err status

  RESULT_CLASS="UNKNOWN"
  RESULT_DETAIL=""
  RESULT_SILENT="false"

  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    err=$(timeout "$PROBE_TIMEOUT" ffmpeg \
      -hide_banner -v error -nostdin \
      -user_agent "$UA" \
      -headers $'Accept: */*\r\n' \
      -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
      -i "$url" \
      -map 0:a:0 -vn -sn -dn \
      -t "$DECODE_SECONDS" \
      -f null - \
      2>&1 >/dev/null)
    status=$?

    if [ "$status" -eq 0 ]; then
      local silence_out silent_frames
      silence_out=$(timeout "$PROBE_TIMEOUT" ffmpeg \
        -hide_banner -v warning -nostdin \
        -user_agent "$UA" \
        -headers $'Accept: */*\r\n' \
        -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
        -i "$url" \
        -map 0:a:0 -vn -sn -dn \
        -t "$DECODE_SECONDS" \
        -af "silencedetect=noise=$SILENCE_THRESHOLD:d=$SILENCE_DURATION" \
        -f null - \
        2>&1)
      silent_frames=$(echo "$silence_out" | grep -c "silence_start" || true)
      [ "${silent_frames:-0}" -gt 0 ] && RESULT_SILENT="true"
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

  RESULT_CLASS=$(classify_error "$err" "$status")
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
  RESULT_SILENT="false"

  if is_playlist_url "$url" && [ "$depth" -le "$MAX_PLAYLIST_DEPTH" ]; then
    local content inner_urls
    content=$(curl -fsSL --max-time "$PLAYLIST_TIMEOUT" --retry 2 --retry-delay 2 \
      -A "$UA" "$url" 2>/dev/null | head -c 65536)
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
build_name_map > "$tmp_dir/station_map.tsv"
while IFS=$'\t' read -r u n sec; do
  [ -z "$u" ] && continue
  url_to_name["$u"]="$n"
  url_to_section["$u"]="${sec:--}"
done < "$tmp_dir/station_map.tsv"

# ----------------------------------------------------------------------------
# Main - parallel probing capped at $JOBS
# Each subshell writes one 6-field TSV line to its own file; concatenated after.
# Fields: result<TAB>url<TAB>detail<TAB>silent<TAB>name<TAB>section
# ----------------------------------------------------------------------------
mapfile -t urls < <(extract_stream_urls)
checked="${#urls[@]}"
echo "Probing $checked streams (up to $JOBS in parallel)..."

i=0
for url in "${urls[@]}"; do
  i=$((i + 1))
  result_file="$tmp_dir/$i.tsv"
  (
    probe_url "$url" 1
    name="${url_to_name[$url]:-$url}"
    section="${url_to_section[$url]:--}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$RESULT_CLASS" "$url" "${RESULT_DETAIL:--}" "$RESULT_SILENT" \
      "$name" "$section" > "$result_file"
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
total_silent=0
manual=0
access_blocked=0
timeout_blocked=0
manual_rows=""
access_rows=""
timeout_rows=""
declare -A category_counts

while IFS=$'\t' read -r result url detail silent name section; do
  category_counts["$result"]=$(( ${category_counts["$result"]:-0} + 1 ))
  safe_name=$(sanitize_text "$name")
  safe_section=$(sanitize_text "$section")
  case "$result" in
    OK)
      total_ok=$((total_ok + 1))
      [ "$silent" = "true" ] && total_silent=$((total_silent + 1))
      ;;
    AUTH_REQUIRED|FORBIDDEN|RATE_LIMITED)
      access_rows+="| $safe_section | $safe_name | <$url> | $result | ${detail:-} |"$'\n'
      access_blocked=$((access_blocked + 1))
      ;;
    TIMEOUT|CONNECTION_RESET)
      timeout_rows+="| $safe_section | $safe_name | <$url> | $result | ${detail:-} |"$'\n'
      timeout_blocked=$((timeout_blocked + 1))
      ;;
    *)
      manual_rows+="| $safe_section | $safe_name | <$url> | $result | ${detail:-} |"$'\n'
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
  echo "Checked **$checked** streams: **$total_ok** OK, **$manual** probe failures, **$access_blocked** access-blocked, **$timeout_blocked** timed out."
  echo ""
  echo "## Statistics"
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| Total streams checked | $checked |"
  echo "| Playable (OK) | $total_ok |"
  echo "| Silent streams (warning) | $total_silent |"
  echo "| Probe failures | $manual |"
  echo "| Access-blocked (CI) | $access_blocked |"
  echo "| Timed out | $timeout_blocked |"
  echo ""
  echo "## Result Breakdown"
  echo "| Result | Count |"
  echo "|---|---|"
  for cat in "${!category_counts[@]}"; do
    echo "| $cat | ${category_counts[$cat]} |"
  done
  echo ""
  echo "## Probe Failures"
  echo "_Streams the runner could not decode. Likely a bad or dead URL — check the README entry._"
  echo ""
  if [ -n "$manual_rows" ]; then
    echo "| Section | Station | URL | Result | Details |"
    echo "|---|---|---|---|---|"
    printf '%s' "$manual_rows"
  else
    echo "_None._"
  fi
  echo ""
  echo "## Access-Blocked"
  echo "_401/403 from the datacenter IP. Almost certainly fine from a residential IP — safe to ignore unless persistent across many runs._"
  echo ""
  if [ -n "$access_rows" ]; then
    echo "| Section | Station | URL | Result | Details |"
    echo "|---|---|---|---|---|"
    printf '%s' "$access_rows"
  else
    echo "_None._"
  fi
  echo ""
  echo "## Timed Out"
  echo "_TIMEOUT / CONNECTION_RESET from the datacenter IP. Usually fine from residential IP, but verify in foobar2000 or VLC if a stream times out consistently across multiple runs._"
  echo ""
  if [ -n "$timeout_rows" ]; then
    echo "| Section | Station | URL | Result | Details |"
    echo "|---|---|---|---|---|"
    printf '%s' "$timeout_rows"
  else
    echo "_None._"
  fi
} > "$REPORT"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"
fi

echo "Probe complete. Report written to $REPORT"
