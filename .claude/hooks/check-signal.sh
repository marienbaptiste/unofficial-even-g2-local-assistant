#!/bin/bash
# Stop hook: Ralph Wiggum loop for BLE capture
# Keeps Claude looping until signal.json says "done", then injects analysis instructions.
# Uses {"decision": "block", "reason": "..."} to prevent the turn from ending.

INPUT=$(cat /dev/stdin)

# Prevent infinite re-entry
STOP_HOOK_ACTIVE=$(python -c "import sys,json; print(json.load(sys.stdin).get('stop_hook_active', False))" <<< "$INPUT" 2>/dev/null)
if [ "$STOP_HOOK_ACTIVE" = "True" ]; then
  exit 0
fi

sleep 5

# Get repo root via git, then build the path
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"
SIGNAL_FILE="$REPO_ROOT/reverse-engineering/tools/signal.json"

if [ ! -f "$SIGNAL_FILE" ]; then
  echo '{"decision": "block", "reason": "Still waiting for capture signal. Say one short word and keep looping."}'
  exit 0
fi

# Let python do all the logic — no bash parsing issues
python -c "
import json, sys

with open(r'''$SIGNAL_FILE''') as f:
    d = json.load(f)

status = d.get('status', 'waiting')
capture_id = d.get('capture_id', '')
notes = d.get('notes', '')

if status == 'done':
    if capture_id:
        hint = f'capture_id={capture_id}'
    else:
        # No capture_id — find the most recent result file
        import glob, os
        results_dir = os.path.join(os.path.dirname(r'''$SIGNAL_FILE'''), 'results')
        results_dir = os.path.normpath(results_dir)
        jsons = sorted(glob.glob(os.path.join(results_dir, '*.json')), key=os.path.getmtime, reverse=True)
        # Skip progress.json
        jsons = [f for f in jsons if not f.endswith('progress.json')]
        if jsons:
            hint = f'latest_result={os.path.basename(jsons[0])}'
        else:
            hint = 'no results found'
    msg = f'CAPTURE READY: {hint}, notes={notes}. Read the capture result JSON from reverse-engineering/tools/results/ and begin BLE protocol analysis. After reading, reset signal.json status to waiting.'
    print(json.dumps({'decision': 'block', 'reason': msg}))
elif status == 'retry':
    print(json.dumps({'decision': 'block', 'reason': 'User is retrying the capture. Say acknowledged and keep looping.'}))
elif status == 'waiting':
    print(json.dumps({'decision': 'block', 'reason': 'Still waiting for capture signal. Say one short word and keep looping.'}))
else:
    # Unknown status — don't block
    pass
"
