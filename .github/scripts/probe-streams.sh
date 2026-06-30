#!/usr/bin/env bash
# probe-streams.sh - v3.5
# Probes every stream URL in README.md, in parallel, for actual decodable audio.
# Produces a structured markdown report.
#
# Fixes vs v3.3 (carried forward, unchanged):
# - Critical: "cmd || true; status=$?" always captured exit 0 (true's status),
#   never ffmpeg's real exit code. Every stream was reported OK regardless of
#   whether it actually decoded. Fixed by removing the unneeded "|| true"
#   (this script never uses "set -e", so it was never needed for that purpose).
# - Restored parallel probing via background subshells capped by $JOBS, using
#   forked subshells of THIS process rather than `xargs -P ... bash -c 'source ...'`.
#   Forked subshells inherit all functions/variables automatically (copy-on-write),
#   so there is no sourcing or exporting required and no risk of the subshell/export
#   bug that caused parallelism to be removed in v3.2.
# - MAX_RETRIES default lowered 3 -> 2 and PROBE_TIMEOUT 45 -> 30 to bound the
#   worst-case cost of a single dead stream now that retries actually fire.
#
# New in v3.5:
# - Codec/bitrate detection for every OK stream. Reuses the decode-check
#   ffmpeg call's own stderr (raised from "-v error" to "-v info", which
#   makes ffmpeg print its "Stream #0:0: Audio: ..." analysis line at no
#   extra network cost) and only opens a dedicated ffprobe call if that
#   output didn't yield both codec and bitrate.
# - ICY header fallback: if ffmpeg/ffprobe still can't determine codec or
#   bitrate (common on bare ICY/Shoutcast streams with no container
#   metadata), a 1-byte ranged GET is used to read icy-br / Content-Type
#   response headers. A ranged GET is used instead of a true HEAD request
#   because some ICY servers reject HEAD outright but honor a ranged GET.
# - Station names: README.md is parsed once up front (via python3, which
#   this repo's CI already depends on for lint_readme.py/readme_to_m3u.py,
#   so this adds no new dependency) into a URL -> station name map, reusing
#   the same entry/stream regexes as readme_to_m3u.py for consistency.
# - Simple quality verdict (Excellent/Good/Okay/Poor/N/A) per stream, based
#   on codec + bitrate.
# - New "Stream Quality" report table, sorted by station name. All existing
#   report sections, parallel probing, retries, playlist resolution, silence
#   detection, and false-positive classification are unchanged. Quality
#   detection only runs for streams that already passed the OK decode check,
#   so it adds no cost to already-dead streams.
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
QUALITY_PROBE_TIMEOUT="${QUALITY_PROBE_TIMEOUT:-10}"
ICY_PROBE_TIMEOUT="${ICY_PROBE_TIMEOUT:-8}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is required." >&2; exit 2
fi
if ! command -v ffprobe >/dev/null 2>&1; then
  echo "Error: ffprobe is required (normally installed alongside ffmpeg)." >&2; exit 2
fi
if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2; exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required (already used by lint_readme.py / readme_to_m3u.py in this repo)." >&2; exit 2
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

# Builds a "url<TAB>station name" map from README.md, one line per stream
# link, mirroring readme_to_m3u.py's ENTRY_RE/STREAM_RE exactly so station
# names stay consistent across both scripts. Runs once up front (not per
# stream), so the python3 startup cost is paid only once for the whole run.
build_name_map() {
  python3 - "$README_FILE" <<'PYEOF'
import re
import sys

ENTRY_RE = re.compile(
    r'^-\s*(?:\u2b50\s*)?\[(?P<name>[^\]]+)\]\((?P<homepage>[^)]+)\):\s*'
    r'(?P<desc>.*)$'
)
STREAM_RE = re.compile(r'\[(Stream|Channel\s*[12]|[12])\]\((?P<url>[^)]+)\)', re.I)

path = sys.argv[1]
with open(path, encoding='utf-8') as f:
    lines = f.readlines()

for raw in lines:
    s = raw.strip()
    m = ENTRY_RE.match(s)
    if not m:
        continue
    name = re.sub(r'\*+', '', m.group('name')).strip()
    streams = STREAM_RE.findall(s)
    for _label, url in streams:
        print(f"{url}\t{name}")
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

# Scores a codec+bitrate(kbps) combination into a simple verdict. Thresholds
# reflect actual blind-test transparency points (AAC ~256k / MP3 ~320k for
# "Excellent"), not just "diminishing returns for casual listening" - see
# project notes for sourcing. Opus/Vorbis get their own (lower) scale since
# they're meaningfully more efficient per kbps than AAC/MP3.
score_quality() {
  local codec="$1" br="$2"
  case "$codec" in
    flac|alac|pcm*|wav)
      echo "Excellent"; return ;;
  esac
  if [ "$codec" = "-" ] || [ "$br" = "-" ]; then
    echo "N/A"; return
  fi
  case "$codec" in
    aac*|mp4a*)
      if   [ "$br" -ge 256 ]; then echo "Excellent"
      elif [ "$br" -ge 160 ]; then echo "Good"
      elif [ "$br" -ge 96 ];  then echo "Okay"
      else echo "Poor"; fi
      ;;
    mp3|mpeg|mp2)
      if   [ "$br" -ge 320 ]; then echo "Excellent"
      elif [ "$br" -ge 224 ]; then echo "Good"
      elif [ "$br" -ge 128 ]; then echo "Okay"
      else echo "Poor"; fi
      ;;
    opus|vorbis|ogg)
      if   [ "$br" -ge 160 ]; then echo "Excellent"
      elif [ "$br" -ge 112 ]; then echo "Good"
      elif [ "$br" -ge 64 ];  then echo "Okay"
      else echo "Poor"; fi
      ;;
    *)
      echo "N/A" ;;
  esac
}

# Determines codec + bitrate for a stream that already passed the OK decode
# check. Three tiers, cheapest first:
#   1. Parse the decode-check ffmpeg call's own stderr (DECODE_OUTPUT, set by
#      probe_one_url, captured at "-v info" instead of "-v error" for exactly
#      this purpose) - zero extra network cost, works for the large majority
#      of streams with container-level stream metadata.
#   2. A dedicated ffprobe call - only runs if (1) didn't yield both codec
#      and bitrate.
#   3. ICY header fallback via a 1-byte ranged GET - only runs if (1) and (2)
#      both left something missing. Catches bare ICY/Shoutcast streams that
#      carry bitrate only in the icy-br header, never in container metadata.
detect_quality() {
  local url="$1"
  CODEC="-"
  BITRATE="-"
  VERDICT="N/A"

  if [ -n "${DECODE_OUTPUT:-}" ]; then
    local c b
    c=$(printf '%s' "$DECODE_OUTPUT" | grep -m1 -oE 'Audio: [a-zA-Z0-9_.]+' | sed -E 's/Audio: //')
    b=$(printf '%s' "$DECODE_OUTPUT" | grep -m1 -oE '[0-9]+ kb/s' | grep -oE '[0-9]+')
    [ -n "$c" ] && CODEC="$c"
    [ -n "$b" ] && BITRATE="$b"
  fi

  if [ "$CODEC" = "-" ] || [ "$BITRATE" = "-" ]; then
    local probe_out cp bp
    probe_out=$(timeout "$QUALITY_PROBE_TIMEOUT" ffprobe -v quiet -user_agent "$UA" \
      -select_streams a:0 -show_entries stream=codec_name,bit_rate \
      -of default=noprint_wrappers=1:nokey=0 "$url" 2>/dev/null)
    cp=$(printf '%s' "$probe_out" | sed -n 's/^codec_name=//p' | head -n1)
    bp=$(printf '%s' "$probe_out" | sed -n 's/^bit_rate=//p' | head -n1)
    if [ "$CODEC" = "-" ] && [ -n "$cp" ] && [ "$cp" != "N/A" ]; then
      CODEC="$cp"
    fi
    if [ "$BITRATE" = "-" ] && [ -n "$bp" ] && [ "$bp" != "N/A" ]; then
      BITRATE=$((bp / 1000))
    fi
  fi

  if [ "$CODEC" = "-" ] || [ "$BITRATE" = "-" ]; then
    local icy_headers icy_br ctype
    icy_headers=$(timeout "$ICY_PROBE_TIMEOUT" curl -sS --max-time "$ICY_PROBE_TIMEOUT" \
      -A "$UA" -r 0-0 "$url" -D - -o /dev/null 2>/dev/null)
    if [ "$BITRATE" = "-" ]; then
      icy_br=$(printf '%s' "$icy_headers" | grep -i '^icy-br:' | grep -oE '[0-9]+' | head -n1)
      [ -n "$icy_br" ] && BITRATE="$icy_br"
    fi
    if [ "$CODEC" = "-" ]; then
      ctype=$(printf '%s' "$icy_headers" | grep -i '^content-type:' | sed -E 's/^[Cc]ontent-[Tt]ype: *//; s/\r//' | head -n1)
      case "$ctype" in
        *mpeg*) CODEC="mp3" ;;
        *aac*)  CODEC="aac" ;;
        *ogg*)  CODEC="vorbis" ;;
        *opus*) CODEC="opus" ;;
        *flac*) CODEC="flac" ;;
      esac
    fi
  fi

  VERDICT=$(score_quality "$CODEC" "$BITRATE")
}

probe_one_url() {
  local url="$1"
  local attempt=1
  local delay="$RETRY_BASE_DELAY"
  local err status

  RESULT_CLASS="UNKNOWN"
  RESULT_DETAIL=""
  RESULT_SILENT="false"
  DECODE_OUTPUT=""

  while [ "$attempt" -le "$MAX_RETRIES" ]; do
    # IMPORTANT: no "|| true" here. This script does not use "set -e", so
    # nothing aborts if ffmpeg fails, and $? below must reflect ffmpeg's
    # real exit code, not the exit code of some fallback command.
    #
    # "-v info" (was "-v error" in v3.4): ffmpeg prints its input-analysis
    # "Stream #0:0: Audio: ..." line at "info" level. Raising verbosity
    # here costs nothing extra over the network, it's the same single
    # connection, just with one more line of stderr we can reuse for
    # codec/bitrate detection on OK streams (see detect_quality()).
    err=$(timeout "$PROBE_TIMEOUT" ffmpeg \
      -hide_banner -v info -nostdin \
      -user_agent "$UA" \
      -headers $'Accept: */*\r\n' \
      -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
      -i "$url" \
      -map 0:a:0 -vn -sn -dn \
      -t "$DECODE_SECONDS" \
      -f null - \
      2>&1 >/dev/null)
    status=$?
    DECODE_OUTPUT="$err"

    if [ "$status" -eq 0 ]; then
      local silence_out
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
      local silent_frames
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
  # .m3u8 (HLS) is deliberately excluded here: ffmpeg has a native HLS
  # demuxer and follows master -> media playlist -> segments on its own
  # when given the .m3u8 URL directly as -i input. Treating it like a
  # classic .m3u/.pls (curl the raw text, grep for a bare URL) doesn't
  # work, HLS manifests use #EXT-X-STREAM-INF directives and often
  # relative paths, not a plain URL on its own line, so it would always
  # come back EMPTY_PLAYLIST. Let probe_one_url() handle it directly.
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
    local content inner
    content=$(curl -fsSL --max-time "$PLAYLIST_TIMEOUT" --retry 2 --retry-delay 2 \
      -A "$UA" "$url" 2>/dev/null | head -c 65536)
    if [ -z "$content" ]; then
      RESULT_CLASS="EMPTY_PLAYLIST"
      RESULT_DETAIL="no content fetched"
      return 1
    fi
    # Try to find inner stream URLs
    local inner_urls
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
# Build the URL -> station name map once, up front.
# ----------------------------------------------------------------------------
declare -A url_to_name
while IFS=$'\t' read -r u n; do
  [ -z "$u" ] && continue
  url_to_name["$u"]="$n"
done < <(build_name_map)

# ----------------------------------------------------------------------------
# Main - probes run in parallel (capped at $JOBS) via forked subshells.
# Each subshell is a fork of THIS process, so it already has every function
# and variable in scope (including url_to_name): no sourcing, no exporting,
# no risk of losing state.
# Each writes its one result line to its own file to avoid concurrent writes
# to a shared file, then we concatenate everything at the end.
# ----------------------------------------------------------------------------
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

mapfile -t urls < <(extract_stream_urls)
checked="${#urls[@]}"
echo "Probing $checked streams (up to $JOBS in parallel)..."

i=0
for url in "${urls[@]}"; do
  i=$((i + 1))
  result_file="$tmp_dir/$i.tsv"
  (
    probe_url "$url" 1
    codec="-"
    bitrate="-"
    verdict="-"
    if [ "$RESULT_CLASS" = "OK" ]; then
      detect_quality "$url"
      codec="$CODEC"
      bitrate="$BITRATE"
      verdict="$VERDICT"
    fi
    name="${url_to_name[$url]:-$url}"
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
      "$RESULT_CLASS" "$url" "${RESULT_DETAIL:--}" "$RESULT_SILENT" \
      "$name" "$codec" "$bitrate" "$verdict" > "$result_file"
    echo " [$RESULT_CLASS] $url"
  ) &
  # Cap concurrency at $JOBS using wait -n (bash 4.3+; GitHub-hosted
  # ubuntu-latest runners ship bash 5.x).
  while [ "$(jobs -r -p | wc -l)" -ge "$JOBS" ]; do
    wait -n
  done
done
wait

tmp_results="$tmp_dir/all.tsv"
cat "$tmp_dir"/*.tsv > "$tmp_results" 2>/dev/null || true

total_ok=0
total_silent=0
manual=0
blocked=0
manual_rows=""
blocked_rows=""
quality_tmp="$tmp_dir/quality.tsv"
: > "$quality_tmp"
declare -A category_counts

while IFS=$'\t' read -r result url detail silent name codec bitrate verdict; do
  category_counts["$result"]=$(( ${category_counts["$result"]:-0} + 1 ))
  case "$result" in
    OK)
      total_ok=$((total_ok + 1))
      [ "$silent" = "true" ] && total_silent=$((total_silent + 1))
      printf "%s\t%s\t%s\t%s\n" "$name" "$codec" "$bitrate" "$verdict" >> "$quality_tmp"
      ;;
    TIMEOUT|RATE_LIMITED|AUTH_REQUIRED|FORBIDDEN|CONNECTION_RESET)
      blocked_rows+="| <$url> | $result | ${detail:-} |"$'\n'
      blocked=$((blocked + 1))
      ;;
    *)
      manual_rows+="| <$url> | $result | ${detail:-} |"$'\n'
      manual=$((manual + 1))
      ;;
  esac
done < "$tmp_results"

quality_rows=""
if [ -s "$quality_tmp" ]; then
  while IFS=$'\t' read -r name codec bitrate verdict; do
    bdisp="$bitrate"
    [ "$bdisp" != "-" ] && bdisp="${bdisp}k"
    quality_rows+="| $name | $codec | $bdisp | $verdict |"$'\n'
  done < <(sort -f -t$'\t' -k1,1 "$quality_tmp")
fi

{
  echo "# Stream Probe Report - $(date -u +%F)"
  echo ""
  echo "Checked $checked streams. **$manual** need manual verification, **$blocked** likely GitHub-runner/network false positives."
  echo ""
  echo "## Statistics"
  echo "| Metric | Value |"
  echo "|---|---|"
  echo "| Total streams | $checked |"
  echo "| Playable (OK) | $total_ok |"
  echo "| Silent (warning) | $total_silent |"
  echo "| Needs manual check | $manual |"
  echo "| Blocked (false positive) | $blocked |"
  echo ""
  echo "## Stream Quality"
  if [ -n "$quality_rows" ]; then
    echo "| Station | Codec | Bitrate | Verdict |"
    echo "|---|---|---|---|"
    printf '%s' "$quality_rows"
  else
    echo "_None._"
  fi
  echo ""
  echo "## Error Breakdown"
  echo "| Category | Count |"
  echo "|---|---|"
  for cat in "${!category_counts[@]}"; do
    echo "| $cat | ${category_counts[$cat]} |"
  done
  echo ""
  echo "## NEEDS MANUAL CHECK"
  if [ -n "$manual_rows" ]; then
    echo "| URL | Category | Details |"
    echo "|---|---|---|"
    printf '%s' "$manual_rows"
  else
    echo "_None._"
  fi
  echo ""
  echo "## Likely FALSE POSITIVES (blocked, throttled, timed out, etc.)"
  if [ -n "$blocked_rows" ]; then
    echo "| URL | Category | Details |"
    echo "|---|---|---|"
    printf '%s' "$blocked_rows"
  else
    echo "_None._"
  fi
  echo ""
  echo "Confirm suspicious streams in foobar2000/VLC before editing README.md."
} > "$REPORT"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$REPORT" >> "$GITHUB_STEP_SUMMARY"
fi

echo "Probe complete. Report written to $REPORT"
