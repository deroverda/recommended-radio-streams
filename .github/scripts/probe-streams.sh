#!/usr/bin/env bash
# probe-streams.sh - v3.3
# Probes every stream URL in README.md sequentially.
# Produces a structured markdown report.

# NOTE: No set -e here intentionally. We handle errors manually per-probe.
set -uo pipefail

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
  local code="${2:-0}"
  case "$err" in
    *"Name or service not known"*|*"No address associated"*|*"Could not resolve host"*|*"Temporary failure"*)
      echo "DNS_FAILURE" ;;
    *"SSL"*|*"certificate"*|*"TLS"*|*"handshake"*)
      echo "SSL_FAILURE" ;;
    *"Connection timed out"*|*"timed out"*|*"Operation timed out"*)
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
    *"redirect"*|*"too many redirects"*)
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
      2>&1 >/dev/null) || true
    status=$?

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
        2>&1) || true
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
  case "$url_lc" in
    *.pls|*.pls\?*|*.m3u|*.m3u\?*|*.m3u8|*.m3u8\?*|*.asx|*.asx\?*|*.xspf|*.xspf\?*) return 0 ;;
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
      -A "$UA" "$url" 2>/dev/null | head -c 65536) || true
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
# Main
# ----------------------------------------------------------------------------
tmp_results="$(mktemp)"
trap 'rm -f "$tmp_results"' EXIT

mapfile -t urls < <(extract_stream_urls)
checked="${#urls[@]}"

echo "Probing $checked streams..."

for url in "${urls[@]}"; do
  probe_url "$url" 1
  printf "%s\t%s\t%s\t%s\n" "$RESULT_CLASS" "$url" "$RESULT_DETAIL" "$RESULT_SILENT" \
    >> "$tmp_results"
  echo "  [$RESULT_CLASS] $url"
done

total_ok=0
total_silent=0
manual=0
blocked=0
manual_rows=""
blocked_rows=""
declare -A category_counts

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
