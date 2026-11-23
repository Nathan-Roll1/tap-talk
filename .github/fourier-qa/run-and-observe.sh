#!/bin/bash
set -euo pipefail
exe=/tmp/taptalk-build/Build/Products/Release/TapTalk.app/Contents/MacOS/TapTalk
"$exe" >/tmp/taptalk-bench-run.log 2>&1 &
pid=$!
echo "$pid" >/tmp/taptalk-bench-pid
# Preserve the last stage and a thread sample if AppKit or a download stops progressing.
previous=none
quiet=0
for tick in $(seq 1 200); do
  if ! kill -0 "$pid" 2>/dev/null; then wait "$pid"; exit $?; fi
  sleep 10
  tail -2 /tmp/taptalk-bench-run.log || true
  current="$(wc -c < /tmp/taptalk-bench-run.log)"
  if [ -e /tmp/taptalk-result.json ]; then current="$current:$(wc -c < /tmp/taptalk-result.json)"; fi
  if [ "$current" = "$previous" ]; then quiet=$((quiet + 1)); else quiet=0; fi
  previous="$current"
  if [ "$quiet" -gt 60 ]; then break; fi
  if [ -f /tmp/taptalk-result.json ]; then
    wc -c /tmp/taptalk-result.json
  fi
done
sample "$pid" 2 10 -file /tmp/taptalk-sample.txt || true
kill "$pid" || true
exit 1
