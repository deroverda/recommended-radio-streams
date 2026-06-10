#!/usr/bin/env bash
# Probes every stream URL in README.md for actual decodable audio.
set -u
UA="Mozilla/5.0"
report=stream-report.md
fail=0

# Matches [Stream](url), [Channel 1/2](url), and NTS-style [1]/[2](url)
mapfile -t urls < <(grep -oE '\[(Stream|Channel [12]|[12])\]\(http[^)]+\)' README.md \
  | sed -E 's/.*\((http[^)]+)\)/\1/' | sort -u)

{
  echo "# Stream probe - $(date -u +%F)"
  echo ""
  echo "| URL | Problem |"
  echo "|---|---|"
} > "$report"

for url in "${urls[@]}"; do
  target="$url"
  case "$url" in
    *.pls|*.m3u)   # unwrap official playlists before probing
      target=$(curl -sL --max-time 15 -A "$UA" "$url" \
        | grep -oE 'https?://[^[:space:]]+' | head -n1)
      if [ -z "$target" ]; then
        echo "| $url | playlist unreadable |" >> "$report"
        fail=$((fail+1))
        continue
      fi
      ;;
  esac
  if ! timeout 40 ffprobe -v error -user_agent "$UA" \
        -select_streams a -show_entries stream=codec_name \
        -of csv=p=0 -i "$target" > /dev/null 2>&1; then
    echo "| $url | no audio detected |" >> "$report"
    fail=$((fail+1))
  fi
done

{
  echo ""
  echo "Checked ${#urls[@]} stream URLs - $fail failed."
  echo ""
  echo "Reminder: flagged streams still need a manual foobar2000/VLC test before editing the README - some hosts block GitHub runner IPs."
} >> "$report"

# Expose the failure count to the workflow
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "failures=$fail" >> "$GITHUB_OUTPUT"
fi
