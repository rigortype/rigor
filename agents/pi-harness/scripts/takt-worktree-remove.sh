#!/usr/bin/env bash
# takt `worktree_provisioner.remove` for Rigor. TAKT_WORKTREE_PATH is the worktree.
set -euo pipefail
path="${TAKT_WORKTREE_PATH:?}"
[[ -e "$path" ]] || exit 0
common="$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)"
git -C "${common%/.git}" worktree remove --force "$path"
