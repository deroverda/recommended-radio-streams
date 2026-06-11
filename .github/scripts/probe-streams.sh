#!/usr/bin/env bash
# Probes every stream URL in README.md for decodable audio,
# classifying each failure by TYPE so false positives are visible, not hidden.
set -u
UA="Mozilla/5.0"
report=stream-report.md
dead=0
blocked=0
checked=0

mapfile -t urls < <(grep -oE '\[(Stream|Channel [12]|[12])\]\(http[^)]+\)' README.md \
  | sed -E 's/.*\((http[^)]+)\)/\1/' | sort -u)

# Probe one URL. Echoes a category; return 0 on success.
probe_one() {
  local err
  err=$(timeout 40 ffprobe -v error -user_agent "$UA" \
        -select_streams a -show_entries stream=codec_name \
        -of csv=p=0 -i "$1" 2>&1 >/dev/null)
  if [ $? -eq 0 ] && [ -z "$err" ]; then
    echo "ok"; return 0
  fi
  # Classify by ffprobe's stderr / exit behaviour
  case "$err" in
    *"Connection refused"*|*"Connection reset"*|*"Connection timed out"*|\
    *"Network is unreachable"*|*"timed out"*|"")
      echo "blocked" ;;          # host refused/ignored the runner - likely false positive
    *403*|*401*|*"Forbidden"*)
      echo "blocked" ;;          # access denied to datacenter IP - likely false positive
    *)
      echo "dead" ;;             # connected but no decodable audio - likely genuinely down
  esac
  return 1
}

# Probe a URL or, for playlists, every inner URL (first success wins).
classify_url() {
  case "$1" in
    *.pls|*.m3u)
      local inner
      mapfile -t inner < <(curl -sL --max-time 15 -A "$UA" "$1" \
        | grep -oE 'https?://[^[:space:]]+')
      if [ "${#inner[@]}" -eq 0 ]; then echo "dead"; return 1; fi
      local worst="blocked" r
      for u in "${inner[@]}"; do
        r=$(probe_one "$u") && { echo "ok"; return 0; }
        [ "$r" = "dead" ] && worst="dead"
      done
      echo "$worst"; return 1 ;;
    *)
      probe_one "$1" ;;
  esac
}

dead_rows=""
blocked_rows=""
for url in "${urls[@]}"; do
  checked=$((checked+1))
  result=$(classify_url "$url")
  case "$result" in
    ok)      : ;;
    dead)    dead_rows+="| $url |"$'\n';    dead=$((dead+1)) ;;
    blocked) blocked_rows+="| $url |"$'\n'; blocked=$((blocked+1)) ;;
  esac
done

{
  echo "# Stream probe - $(date -u +%F)"
  echo ""
  echo "Checked $checked streams. **$dead** likely dead, **$blocked** likely false positives (host blocked the GitHub runner)."
  echo ""
  echo "## Likely DEAD - connected but no audio decoded (verify and fix)"
  if [ -n "$dead_rows" ]; then
    echo "| URL |"; echo "|---|"; printf '%s' "$dead_rows"
  else
    echo "_None._"
  fi
  echo ""
  echo "## Likely FALSE POSITIVES - host refused the runner's IP (probably fine)"
  if [ -n "$blocked_rows" ]; then
    echo "| URL |"; echo "|---|"; printf '%s' "$blocked_rows"
  else
    echo "_None._"
  fi
  echo ""
  echo "A stream that genuinely dies later moves from the false-positive list to the dead list, so nothing is permanently hidden. Confirm in foobar2000/VLC before editing the README."
} > "$report"

# Render on the Actions run summary page (no artifact download needed)
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  cat "$report" >> "$GITHUB_STEP_SUMMARY"
fi
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "dead=$dead" >> "$GITHUB_OUTPUT"
  echo "blocked=$blocked" >> "$GITHUB_OUTPUT"
fi
