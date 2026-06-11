#!/usr/bin/env bash
# Probes every stream URL in README.md for playable audio by decoding a few
# seconds with ffmpeg. Classifies failures as:
#   dead    = connected but no usable audio decoded, or DNS genuinely broken
#   blocked = likely runner/network/CDN blocking or timeout false positive
#
# Designed for GitHub Actions, but also works locally:
#   bash .github/scripts/probe-streams.sh

set -Eeuo pipefail

UA="${UA:-Mozilla/5.0}"
README_FILE="${README_FILE:-README.md}"
REPORT="${REPORT:-stream-report.md}"
JOBS="${JOBS:-8}"
DECODE_SECONDS="${DECODE_SECONDS:-8}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-45}"
PLAYLIST_TIMEOUT="${PLAYLIST_TIMEOUT:-15}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Error: ffmpeg is required." >&2
  exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 2
fi

if [ ! -f "$README_FILE" ]; then
  echo "Error: $README_FILE not found." >&2
  exit 2
fi

extract_stream_urls() {
  grep -oE '\[(Stream|Channel [12]|[12])\]\(https?://[^)]+\)' "$README_FILE" \
    | sed -E 's/.*\((https?:\/\/[^)]+)\)/\1/' \
    | sort -u
}

classify_error() {
  local err="$1"

  case "$err" in
    *"Name or service not known"*|*"No address associated"*|\
    *"Could not resolve host"*|*"Temporary failure in name resolution"*)
      echo "dead"
      ;;
    *"Connection refused"*|*"Connection reset"*|*"Connection timed out"*|\
    *"Network is unreachable"*|*"Operation timed out"*|*"timed out"*|\
    *"Resource temporarily unavailable"*|"")
      echo "blocked"
      ;;
    *"403"*|*"401"*|*"Forbidden"*|*"Unauthorized"*|\
    *"429"*|*"Too Many Requests"*|*"522"*)
      echo "blocked"
      ;;
    *)
      echo "dead"
      ;;
  esac
}

# Decodes a few seconds of audio. Stronger than only checking metadata.
# NOTE: '2>&1 >/dev/null' (in that order) captures stderr into $err while
# discarding stdout. The reverse order would discard both and break
# classification entirely.
probe_one() {
  local url="$1"
  local err status

  set +e
  err=$(
    timeout "$PROBE_TIMEOUT" ffmpeg \
      -hide_banner \
      -v error \
      -nostdin \
      -user_agent "$UA" \
      -headers $'Accept: */*\r\n' \
      -reconnect 1 \
      -reconnect_streamed 1 \
      -reconnect_delay_max 5 \
      -i "$url" \
      -map 0:a:0 \
      -vn -sn -dn \
      -t "$DECODE_SECONDS" \
      -f null - \
      2>&1 >/dev/null
  )
  status=$?
  set -e

  if [ "$status" -eq 0 ]; then
    echo "ok"
    return 0
  fi

  # timeout(1) kills ffmpeg with exit 124; treat as runner-side, not dead.
  if [ "$status" -eq 124 ]; then
    echo "blocked"
    return 1
  fi

  classify_error "$err"
  return 1
}

is_simple_playlist_url() {
  local url_lc="${1,,}"
  case "$url_lc" in
    *.pls|*.pls\?*|*.m3u|*.m3u\?*) return 0 ;;
    *) return 1 ;;
  esac
}

# Fetch at most 4 KB - a real playlist fits, and this avoids downloading
# 15 seconds of raw audio when the fallback hits a live stream endpoint.
fetch_inner_urls() {
  local url="$1"

  curl -fsSL \
    --max-time "$PLAYLIST_TIMEOUT" \
    --retry 2 \
    --retry-delay 2 \
    -A "$UA" \
    "$url" 2>/dev/null \
    | head -c 4096 \
    | grep -aoE 'https?://[^[:space:]<>"'\''()]+' \
    | sed 's/[[:space:]]*$//' \
    | sort -u || true
}

# Probe a URL. For .pls/.m3u playlists, probe inner URLs.
# For other URLs, probe directly first, then try playlist expansion as a
# fallback (catches playlist endpoints without an extension, e.g.
# radiosega.net/play/).
classify_url() {
  local url="$1"
  local r inner u worst

  if is_simple_playlist_url "$url"; then
    mapfile -t inner < <(fetch_inner_urls "$url")

    if [ "${#inner[@]}" -eq 0 ]; then
      echo "dead"
      return 1
    fi

    worst="blocked"
    for u in "${inner[@]}"; do
      r=$(probe_one "$u") && {
        echo "ok"
        return 0
      }
      [ "$r" = "dead" ] && worst="dead"
    done

    echo "$worst"
    return 1
  fi

  r=$(probe_one "$url") && {
    echo "ok"
    return 0
  }

  mapfile -t inner < <(fetch_inner_urls "$url")

  if [ "${#inner[@]}" -gt 0 ]; then
    worst="$r"
    for u in "${inner[@]}"; do
      r=$(probe_one "$u") && {
        echo "ok"
        return 0
      }
      [ "$r" = "dead" ] && worst="dead"
    done
    echo "$worst"
    return 1
  fi

  echo "$r"
  return 1
}

worker() {
  local url="$1"
  local result
  result=$(classify_url "$url" || true)
  printf '%s\t%s\n' "$result" "$url"
}

export UA DECODE_SECONDS PROBE_TIMEOUT PLAYLIST_TIMEOUT
export -f classify_error probe_one is_simple_playlist_url fetch_inner_urls classify_url worker

mapfile -t urls < <(extract_stream_urls || true)

checked="${#urls[@]}"
dead=0
blocked=0
dead_rows=""
blocked_rows=""

tmp_results="$(mktemp)"
trap 'rm -f "$tmp_results"' EXIT

if [ "$checked" -gt 0 ]; then
  printf '%s\0' "${urls[@]}" \
    | xargs -0 -n1 -P "$JOBS" bash -c 'worker "$1"' _ \
    > "$tmp_results"
fi

while IFS=$'\t' read -r result url; do
  case "$result" in
    ok)
      :
      ;;
    dead)
      dead_rows+="| $url |"$'\n'
      dead=$((dead + 1))
      ;;
    blocked)
      blocked_rows+="| $url |"$'\n'
      blocked=$((blocked + 1))
      ;;
    *)
      dead_rows+="| $url |"$'\n'
      dead=$((dead + 1))
      ;;
  esac
done < "$tmp_results"

{
  echo "# Stream probe - $(date -u +%F)"
  echo ""
  echo "Checked $checked streams. **$dead** likely dead, **$blocked** likely false positives or runner/network-blocked."
  echo ""
  echo "Decode test: attempted to decode the first audio stream for ${DECODE_SECONDS}s with ffmpeg."
  echo ""

  echo "## Likely DEAD - no usable audio decoded"
  if [ -n "$dead_rows" ]; then
    echo "| URL |"
    echo "|---|"
    printf '%s' "$dead_rows"
  else
    echo "_None._"
  fi

  echo ""
  echo "## Likely FALSE POSITIVES - blocked, throttled, timed out, or refused the GitHub runner"
  if [ -n "$blocked_rows" ]; then
    echo "| URL |"
    echo "|---|"
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

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "dead=$dead" >> "$GITHUB_OUTPUT"
  echo "blocked=$blocked" >> "$GITHUB_OUTPUT"
  echo "checked=$checked" >> "$GITHUB_OUTPUT"
fi
