#!/usr/bin/env bash
# takt `worktree_provisioner.create` for Rigor: a git worktree off a fresh
# origin/<base> (so `origin` stays, `vendor/bundle` is wired) instead of
# takt's isolated clone. Inputs come from takt's environment:
#   TAKT_PROJECT_DIR TAKT_WORKTREE_PATH TAKT_WORKTREE_BRANCH
#   TAKT_WORKTREE_MODE (new|existing) TAKT_WORKTREE_BASE_BRANCH
set -euo pipefail

repo="${TAKT_PROJECT_DIR:?}"
path="${TAKT_WORKTREE_PATH:?}"
branch="${TAKT_WORKTREE_BRANCH:?}"

git -C "$repo" fetch -q origin
if [[ "${TAKT_WORKTREE_MODE:-new}" == existing ]]; then
  if git -C "$repo" show-ref -q --verify "refs/remotes/origin/$branch"; then
    git -C "$repo" worktree add -q -B "$branch" "$path" "origin/$branch"
  else
    git -C "$repo" worktree add -q "$path" "$branch"
  fi
else
  base="${TAKT_WORKTREE_BASE_BRANCH:-master}"
  git -C "$repo" worktree add -q -b "$branch" "$path" "origin/$base"
fi

(cd "$path" && MAIN_REPO="$repo" bash agents/pi-harness/scripts/worktree-bundle-config.sh)

# takt copies the root's uncommitted .takt/ into the worktree after this
# returns. Hide those edits from the lane's commits: skip-worktree for the
# tracked files, an exclude for the untracked runtime profile.
git -C "$path" ls-files -z -- .takt | xargs -0 -I{} git -C "$path" update-index --skip-worktree {}
exclude="$(git -C "$path" rev-parse --git-path info/exclude)"
grep -qxF '.takt/runtime.yaml' "$exclude" 2>/dev/null || echo '.takt/runtime.yaml' >>"$exclude"
