#!/usr/bin/env bash
# One row per queued takt task: issue, status, the step it failed in, minutes
# it ran, branch. Tab-separated on stdout, totals on stderr; read-only.
# The record for judging the outsourced lanes: which step fails, how often.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
python3 -I - "$REPO/.takt/tasks.yaml" <<'PY'
import collections, sys, yaml

tasks = (yaml.safe_load(open(sys.argv[1])) or {}).get("tasks") or []
print("issue\tstatus\tfailed_step\tminutes\tbranch")
tally = collections.Counter()
for t in tasks:
    step = (t.get("failure") or {}).get("step", "")
    start, end = t.get("started_at"), t.get("completed_at")
    minutes = f"{(end - start).total_seconds() / 60:.0f}" if start and end else ""
    print(f"{t.get('issue', '')}\t{t.get('status', '')}\t{step}\t{minutes}\t{t.get('branch', '')}")
    tally[t.get("status", "?") + (f" at {step}" if step else "")] += 1
print("  ".join(f"{k}: {v}" for k, v in sorted(tally.items())), file=sys.stderr)
PY
