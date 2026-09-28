#!/bin/bash
# Run one CI stage script and, if it fails, surface the tail of its output as
# a GitHub error annotation. Annotations are readable through the checks API
# even where raw job logs are not.
#   usage: bash .github/ci/run.sh <stage-script>
set -uo pipefail
STAGE="$1"
LOG="$RUNNER_TEMP/$(basename "$STAGE" .sh).out"

bash "$GITHUB_ACTION_PATH/$STAGE" 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}

if [ "$status" -ne 0 ]; then
    # Encode per the workflow-command spec so the whole tail is one annotation.
    # Error lines first (annotations are cut near 4 KB), then a short tail.
    {
        echo "== error lines =="
        grep -n -i -E "error[: ]|FAILED|fatal|undefined symbol|not found|No such file" "$LOG" \
            | grep -v -E "^[0-9]+:\[[0-9]+/[0-9]+\] Building" | tail -n 25
        echo "== tail =="
        tail -n 12 "$LOG"
    } | cut -c1-240 > "$LOG.summary"
    msg=$(python3 -c '
import sys
s = open(sys.argv[1]).read()[-3800:]
s = s.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
sys.stdout.write(s)
' "$LOG.summary")
    echo "::error title=${STAGE} failed (exit ${status})::${msg}"
fi
exit "$status"
