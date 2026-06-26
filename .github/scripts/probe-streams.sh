#!/usr/bin/env bash
# probe-streams.sh - v3.2
# Probes every stream URL in README.md with detailed categories, silence warnings,
# exponential retries, and playlist expansion. Produces a structured report.
# Runs sequentially to avoid subshell/export issues in CI environments.
#
# All configurable parameters are centralised below.

set -Eeuo pipefail

# ----------------------------------------------------------------------------
# CONFIGURATION
# ----------------------------------------------------------------------------
UA="${UA:-Mozilla/5.0}"
README_FILE="${README_FILE:-README.md}"
REPORT="${REPORT:-stream-report.md}"
DECODE_SECONDS="${DECODE_SECONDS:-8}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-45}"
PLAYLIST_TIMEOUT="${PLAYLIST_TIMEOUT:-15}"
MAX_RETRIES="${MAX_RETRIES:-3}"
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

sanitize_text() {
  printf '%s' "$1" \
    | tr '\n\t' '  ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//; s/\|/\\|/g' \
    | cut -c1-200
}

classify_error() {
  local err="$1"
  local code="${2:-}"
  case "$err" in
    *"Name or service not known"*|*"No address associated"*|*"Could not resolve host"*|*"Temporary failure"*)
      echo "DNS_FAILURE"; return ;;
    *"SSL"*|*"certificate"*|*"TLS"*|*"handshake"*) echo "SSL_FAILURE"; return ;;
    *"Connection timed out"*|*"timed out"*|*"Operation timed out"*) echo "TIMEOUT"; return ;;
    *"Connection refused"*|*"Connection reset"*) echo "CONNECTION_RESET"; return ;;
    *"403"*|*"401"*|*"Forbidden"*|*"Unauthorized"*) echo "AUTH_REQUIRED"; return ;;
    *"429"*|*"Too Many Requests"*|*"522"*) echo "RATE_LIMITED"; return ;;
    *"404"*|*"Not Found"*) echo "NOT_FOUND"; return ;;
    *"Unsupported codec"*|*"codec not found"*) echo "UNSUPPORTED_CODEC"; return ;;
    *"playlist"*|*"M3U"*|*"PLS"*) echo "PLAYLIST_PARSE_ERROR"; return ;;
    *"redirect"*|*"too many redirects"*) echo "REDIRECT_LOOP"; return ;;
    "") [ -n "$code" ] && [ "$code" -eq 124 ] && echo "TIMEOUT" || echo "UNKNOWN"; return ;;
    *) echo "UNKNOWN"; return ;;
  esac
}

probe_with_retry() {
  local url="$1"
  local attempt=1
  local delay="$RETRY_BASE_DELAY"
  local err=""
  local status=0

  while [ $attempt -le "$MAX_RETRIES" ]; do
    set +e
    err=$(
      timeout "$PROBE_TIMEOUT" ffmpeg \
        -hide_banner -v error -nostdin \
        -user_agent "$UA" \
        -headers $'Accept: */*\r\n' \
        -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
        -i "$url" \
        -map 0:a:0 -vn -sn -dn \
        -t "$DECODE_SECONDS" \
        -f null - \
        2>&1 >/dev/null
    )
    status=$?
    set -e

    if [ "$status" -eq 0 ]; then
      # Success - check silence
      local silence_err=""
      local silent_frames=0
      set +e
      silence_err=$(
        timeout "$PROBE_TIMEOUT" ffmpeg \
          -hide_banner -v warning -nostdin \
          -user_agent "$UA" \
          -headers $'Accept: */*\r\n' \
          -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
          -i "$url" \
          -map 0:a:0 -vn -sn -dn \
          -t "$DECODE_SECONDS" \
          -af "silencedetect=noise=$SILENCE_THRESHOLD:d=$SILENCE_DURATION" \
          -f null - \
          2>&1
      )
      set -e
      silent_frames=$(echo "$silence_err" | grep -c "silence_start" || echo 0)
      RESULT_SILENT="false"
      [ "$silent_frames" -gt 0 ] && RESULT_SILENT="true"
      RESULT_CLASS="OK"
      RESULT_DETAIL=""
      return 0
    fi

    local klass detail
    klass=$(classify_error "$err" "$status")
    detail=$(sanitize_text "$err")
    [ -z "$detail" ] && detail="exit status $status"

    attempt=$((attempt + 1))
    [ $attempt -le "$MAX_RETRIES" ] && sleep "$delay" && delay=$((delay * 2))
  done

  RESULT_CLASS=$(classify_error "$err" "$status")
  RESULT_DETAIL=$(sanitize_text "$err")
  [ -z "$RESULT_DETAIL" ] && RESULT_DETAIL="exit status $status"
  return 1
}

is_playlist_url() {
  local url_lc="${1,,}"
  case "$url_lc" in
    *.pls|*.pls\?*|*.m3u|*.m3u\?*|*.m3u8|*.m3u8\?*|*.asx|*.asx\?*|*.xspf|*.xspf\?*) return 0 ;;
    *) return 1 ;;
  esac
}

fetch_inner_urls() {
  local url="$1"
  local depth="$2"
  local max_depth="$3"
  [ "$depth" -gt "$max_depth" ] && return 0
  local content
  content=$(curl -fsSL --max-time "$PLAYLIST_TIMEOUT" --retry 2 --retry-delay 2 \
    -A "$UA" "$url" 2>/dev/null | head -c 65536 || true)
  [ -z "$content" ] && return 0
  local inner_urls
  # M3U
  inner_urls=$(echo "$content" | grep -oE '^(https?://[^[:space:]]+)' || true)
  [ -n "$inner_urls" ] && echo "$inner_urls" && return 0
  # PLS
  inner_urls=$(echo "$content" | grep -i '^File[0-9]*=' | sed -E 's/^File[0-9]*=//' | head -10 || true)
  [ -n "$inner_urls" ] && echo "$inner_urls" && return 0
  # ASX
  inner_urls=$(echo "$content" | grep -oE 'href="[^"]+"' | sed -E 's/href="([^"]+)"/\1/' || true)
  [ -n "$inner_urls" ] && echo "$inner_urls" && return 0
  # XSPF
  inner_urls=$(echo "$content" | grep -oE '<location>[^<]*</location>' | sed -E 's/<\/?location>//g' || true)
  [ -n "$inner_urls" ] && echo "$inner_urls" && return 0
  # fallback
  inner_urls=$(echo "$content" | grep -oE 'https?://[^[:space:]<"'"'"']+' | sort -u || true)
  echo "$inner_urls"
}

probe_url() {
  local url="$1"
  local depth="${2:-1}"
  local max_depth="${3:-$MAX_PLAYLIST_DEPTH}"

  RESULT_SILENT="false"
  RESULT_CLASS="UNKNOWN"
  RESULT_DETAIL=""

  if is_playlist_url "$url" && [ "$depth" -le "$max_depth" ]; then
    local inner_urls=()
    mapfile -t inner_urls < <(fetch_inner_urls "$url" "$depth" "$max_depth")
    if [ ${#inner_urls[@]} -eq 0 ]; then
      RESULT_CLASS="EMPTY_PLAYLIST"
      RESULT_DETAIL="playlist contained no inner URLs"
      return 1
    fi
    for inner in "${inner_urls[@]}"; do
      set +e
      probe_url "$inner" $((depth+1)) "$max_depth"
      set -e
      [ "$RESULT_CLASS" = "OK" ] && return 0
    done
    return 1
  fi

  set +e
  probe_with_retry "$url"
  local ret=$?
  set -e
  return $ret
}

# ----------------------------------------------------------------------------
# Main
# ----------------------------------------------------------------------------
mapfile -t urls < <(extract_stream_urls)
checked="${#urls[@]}"
manual=0
blocked=0
manual_rows=""
blocked_rows=""

tmp_results="$(mktemp)"
trap 'rm -f "$tmp_results"' EXIT

echo "Probing $checked streams sequentially..."

for url in "${urls[@]}"; do
  set +e
  probe_url "$url" 1 3
  set -e
  printf "%s\t%s\t%s\t%s\n" "$RESULT_CLASS" "$url" "$RESULT_DETAIL" "$RESULT_SILENT" \
    >> "$tmp_results"
  echo "  [$RESULT_CLASS] $url"
done

declare -A category_counts
total_ok=0
total_silent=0

while IFS=$'\t' read -r result url detail silent; do
  category_counts["$result"]=$(( ${category_counts["$result"]:-0} + 1 ))
  case "$result" in
    OK)
      total_ok=$((total_ok + 1))
      [ "$silent" = "true" ] && total_silent=$((total_silent + 1))
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
  echo "## Error breakdown"
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
