#!/usr/bin/env bash
# Regenerate the captured /api/* responses used by the round-trip + parity
# tests. Defaults to the local Express server on :3001; set PORT=3002 to
# capture from eavd instead.
set -euo pipefail
PORT="${PORT:-3001}"
HOST="${HOST:-localhost}"
BASE="http://${HOST}:${PORT}"
HERE="$(cd "$(dirname "$0")" && pwd)"

echo "==> capturing from ${BASE}"
for endpoint in tasks "tasks?all=true" files keywords priorities list-config config "capture/templates" "refile/targets" clock; do
  filename=$(echo "$endpoint" | tr '/?=&' '_' | tr -s '_')
  curl -sf "${BASE}/api/${endpoint}" -o "${HERE}/${filename}.json"
  echo "  ${filename}.json ($(wc -c < "${HERE}/${filename}.json") bytes)"
done

echo "==> 30 days of agenda (today ±14)"
for i in $(seq -14 15); do
  if [[ $i -lt 0 ]]; then d=$(date -j -v"${i}d" +%Y-%m-%d 2>/dev/null || date -d "$i days" +%Y-%m-%d); fi
  if [[ $i -ge 0 ]]; then d=$(date -j -v"+${i}d" +%Y-%m-%d 2>/dev/null || date -d "+$i days" +%Y-%m-%d); fi
  [[ -z "$d" ]] && continue
  curl -sf "${BASE}/api/agenda/day/${d}" -o "${HERE}/agenda_day_${d}.json"
done
ls "${HERE}"/agenda_day_*.json | wc -l | xargs echo "  agenda days:"
