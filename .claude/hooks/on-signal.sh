#!/bin/bash
# Hook: reads signal.json when it changes and injects content into Claude's context
FILE_PATH=$(jq -r '.file_path' < /dev/stdin)
SIGNAL=$(cat "$FILE_PATH" 2>/dev/null || echo '{}')
STATUS=$(echo "$SIGNAL" | jq -r '.status // "unknown"')
CAPTURE_ID=$(echo "$SIGNAL" | jq -r '.capture_id // ""')
NOTES=$(echo "$SIGNAL" | jq -r '.notes // ""')

if [ "$STATUS" = "done" ]; then
  MSG="Capture signal received: status=$STATUS, capture_id=$CAPTURE_ID, notes=$NOTES. Please read the latest capture result and begin analysis."
elif [ "$STATUS" = "retry" ]; then
  MSG="User is retrying the capture. Wait for the next done signal."
else
  exit 0
fi

jq -n --arg msg "$MSG" '{
  "hookSpecificOutput": {
    "hookEventName": "FileChanged",
    "additionalContext": $msg
  }
}'
exit 0
