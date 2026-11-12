#!/usr/bin/env bash
# Push a coordinator fix-up from a finished takt lane's worktree.
#   takt-lane-push.sh WORKTREE
# takt-worktree-create.sh marks the worktree's .takt/ files skip-worktree to
# hide the copies takt lays over them. Once master changes one of those files
# a rebase stops on "local changes would be overwritten", so drop the marks
# and the copies first, then run bin/lane-push there.
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: takt-lane-push.sh WORKTREE" >&2; exit 2; }
cd "$1"
[[ -z "$(git status --porcelain)" ]] || { echo "takt-lane-push: commit or discard the worktree's changes first" >&2; exit 1; }
git ls-files -v -z -- .takt | while IFS= read -r -d '' entry; do
  [[ "$entry" == S\ * ]] && git update-index --no-skip-worktree -- "${entry#S }"
done
git checkout -- .takt
exec nix develop --command bin/lane-push </dev/null
