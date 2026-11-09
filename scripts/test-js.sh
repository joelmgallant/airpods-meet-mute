#!/bin/bash
# Runs Tests/js/meet-toggle.test.js against MeetToggleJS.source in headless Chrome.
set -euo pipefail
cd "$(dirname "$0")/.."

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TOGGLE_JS="$(scripts/extract-toggle-js.sh 2>/dev/null || true)"
if [ -z "$TOGGLE_JS" ]; then
    echo "FAIL: could not extract MeetToggleJS.source"
    exit 1
fi

{
    echo '<!doctype html><html><head><meta charset="utf-8"></head><body><div id="results">RESULT: DID NOT RUN</div><script>'
    echo "var meetToggle = $TOGGLE_JS;"
    cat Tests/js/meet-toggle.test.js
    echo '</script></body></html>'
} > "$WORK/test.html"

if ! OUTPUT="$("$CHROME" --headless=new --disable-gpu --no-first-run --user-data-dir="$WORK/profile" --dump-dom "file://$WORK/test.html" 2>"$WORK/chrome.log")"; then
    echo "FAIL: headless Chrome exited non-zero"
    cat "$WORK/chrome.log"
    exit 1
fi

# Anchor to the results div: --dump-dom also echoes the test script, which contains RESULT: strings.
RESULT="$(echo "$OUTPUT" | grep -o '<div id="results">RESULT:[^<]*' | sed 's/<div id="results">//' || true)"
echo "${RESULT:-FAIL: no RESULT marker in DOM}"
[ "$RESULT" = "RESULT: ALL PASS" ]
