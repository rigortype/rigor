#!/usr/bin/env bash
# One-screen view of every takt run: step, provider/model, age, and the last
# thing each step said. Read-only; safe to leave in a herdr pane.
#   takt-status.sh          print once
#   takt-status.sh -l [N]   refresh every N seconds (default 5)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WT_ROOT="${WT_ROOT:-$(dirname "$REPO")/rigor-wt}"
# Queue-mode lanes (worktree_provisioner) live beside it, not under rigor-wt.
TAKT_WT_ROOT="${TAKT_WT_ROOT:-$(dirname "$REPO")/takt-worktrees}"

render() {
  python3 -I - "$REPO" "$WT_ROOT" "$TAKT_WT_ROOT" <<'PY'
import glob, json, os, subprocess, sys, time
from datetime import datetime, timezone

repo, wt_root = sys.argv[1], sys.argv[2]
now = time.time()

def ts(s):
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except Exception:
        return None

def ago(t):
    if t is None: return "-"
    d = int(now - t)
    return f"{d}s" if d < 60 else f"{d//60}m{d%60:02d}s" if d < 3600 else f"{d//3600}h{d%3600//60:02d}m"

def alive(pid):
    try:
        os.kill(pid, 0); return True
    except Exception:
        return False

# Which run dirs belong to a live takt process (cwd match via lsof is slow;
# use the lane lock files + pgrep of the worktree path in argv/cwd instead).
live = subprocess.run(["pgrep", "-fl", "bin/takt"], capture_output=True, text=True).stdout

rows = []
roots = [r for root in (wt_root, sys.argv[3]) for r in glob.glob(os.path.join(root, "*", ".takt", "runs", "*"))]
roots += glob.glob(os.path.join(repo, ".takt", "runs", "*"))
for run in roots:
    mp = os.path.join(run, "meta.json")
    if not os.path.exists(mp): continue
    try: m = json.load(open(mp))
    except Exception: continue
    lane = os.path.basename(os.path.dirname(os.path.dirname(os.path.dirname(run))))
    if lane == os.path.basename(repo): lane = "(main)"
    status = m.get("status", "?")
    step = m.get("currentStep") or "-"
    prov = model = "-"
    last = ""
    for lf in sorted(glob.glob(os.path.join(run, "logs", "*.jsonl"))):
        for line in open(lf, errors="ignore"):
            try: e = json.loads(line)
            except Exception: continue
            t = e.get("type")
            if t == "step_start":
                prov = e.get("provider", prov); model = e.get("model", model)
            if t in ("step_complete", "phase_complete") and e.get("content"):
                last = " ".join(str(e["content"]).split())[:70]
    upd = ts(m.get("updatedAt", ""))
    # takt only updates meta.json on step boundaries; an editing step looks idle.
    # Use the newest changed file in the lane worktree as the real activity signal.
    wt = os.path.dirname(os.path.dirname(os.path.dirname(run)))
    if os.path.isdir(os.path.join(wt, ".git")) or os.path.isfile(os.path.join(wt, ".git")):
        files = subprocess.run(["git", "-C", wt, "status", "--porcelain", "--untracked-files=normal"],
                               capture_output=True, text=True).stdout.splitlines()
        for f in files[:200]:
            fp = os.path.join(wt, f[3:].split(" -> ")[-1].strip('"'))
            try: upd = max(upd or 0, os.path.getmtime(fp))
            except OSError: pass
    # a "running" run whose last update is old and has no takt process is stale
    stale = status == "running" and (upd is None or now - upd > 900) and "takt" not in live
    if stale: status = "STALE?"
    rows.append((upd or 0, lane, status, f"{step}#{m.get('currentIteration','-')}", f"{prov}/{model}", ago(ts(m.get('startTime',''))), ago(upd), last))

rows.sort(reverse=True)
print(f"takt runs @ {datetime.now().strftime('%H:%M:%S')}   (worktrees: {wt_root})")
print(f"{'LANE':<22}{'STATUS':<11}{'STEP':<22}{'PROVIDER/MODEL':<30}{'AGE':<8}{'IDLE':<8}LAST OUTPUT")
for _, lane, st, step, pm, age, idle, last in rows[:15]:
    print(f"{lane[:21]:<22}{st:<11}{step[:21]:<22}{pm[:29]:<30}{age:<8}{idle:<8}{last}")
if not rows: print("(no runs yet)")
print()
print("processes:")
out = subprocess.run("pgrep -fl 'bin/takt|devin .*acp|claude-agent|run-takt-lanes' | cut -c1-150", shell=True, capture_output=True, text=True).stdout.strip()
print(out or "(none)")
PY
}

if [[ "${1:-}" == "-l" ]]; then
  every="${2:-5}"
  while :; do clear; render; sleep "$every"; done
else
  render
fi
