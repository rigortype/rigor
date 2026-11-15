# Delegating release prep to subagents

Measured on v0.4.8: 146 fragments sealed into 88 top-level bullets. Four mid-tier rewriters
(Sonnet 5.5) ran in parallel for 40–60 s each, beside `make verify`, so the seal finished before the
gate did. This file says what to hand off, to which model tier, and what stays with the coordinator.

## What stays with the coordinator

- The approval queue: reporting it, asking, and the `Ratify approval queue entries` commit. It is the
  user's decision surface, and a summary of a summary loses the trade-offs.
- Assembling the section: cross-group merges, the release summary, step 5's section-wide checks (a
  duplicated `###` heading, entries glued across groups), and the final top-to-bottom read. Only
  the coordinator sees every group. Each rewriter flags the overlaps it suspects in its Notes.
- Every gate, commit, push, PR, `bin/land-pr` and `rake release`. A rewriter needs only `git log`
  and `gh`, so its brief tells it to run no `make`, `bundle` or rspec. Any command it does run still
  goes through `nix develop --command`, as `CLAUDE.md` requires of every subagent.

## Mechanical steps: a script, not an agent

Do these in the coordinator's shell. They are exact, and an agent adds only latency. `PREV` is the
previous release's version and `NEW` is the one being cut.

```sh
S=<scratch dir>
git log --oneline --merges vPREV..HEAD | grep -oE '#[0-9]+' | sort -u > $S/prs.txt
# fragments with no PR link: find the PR from the commit that added the fragment
grep -rL 'pull/' changelog.d --include='*.md' | grep -v README | while read -r f; do
  sha=$(git log --format=%H --diff-filter=A -- "$f" | tail -1)
  echo "$f $(gh pr list --state merged --search "$sha" --json number --jq '.[].number')"
done
# after assembly: PRs in the window that no bullet links
awk '/^## \[NEW\]/{f=1;next}/^## \[/{f=0}f' CHANGELOG.md | grep -oE 'pull/[0-9]+' \
  | sed 's#pull/#\##' | sort -u > $S/linked.txt
comm -23 $S/prs.txt $S/linked.txt
```

To split the fragments into groups, read each fragment's first `**[label]**` with a short Python
script rather than a shell loop, whose traps are in
[`measurement.md`](../../../../docs/agents/measurement.md) § "Shell commands that answer wrong
silently".

**Move the links in front of the period at assembly.** `changelog.d/README.md` has a fragment end
`One user-facing sentence. ([#N](…))`, and `CHANGELOG.md` puts the link inside the sentence:
`… ([#N](…)).`. Rewriters copy the fragment form, so normalise every bullet and child item in one
pass, multi-link endings included:

```python
re.sub(r'\. (\((?:\[[^\]]+\]\([^)]+\)(?:, )?)+\))$', r' \1.', section, flags=re.M)
```

A bullet that ends `thank you @handle! ([#N](…))` keeps that form, as earlier releases do.

## The seal: mid-tier rewriters, one per group

Split by section and label so that related fragments share a group: `Fixed` `[inference]`;
`Fixed` `[check]`/`[rigor check]`/`[engine]`/`[diagnostics]`; the rest of `Fixed`; `Added` and
`Changed` together. On v0.4.8 that gave 27–44 fragments per group. With fewer fragments, merge
groups rather than run near-empty ones; one rewriter handles about 45. Each rewriter gets a shared
brief file and its group list, and writes one output file with `## Bullets`, `## Dropped` (with
reasons) and `## Notes`.

What the brief must say, each line learned on v0.4.8:

- **Point at the rules; do not restate them.** Name § "Seal the `[Unreleased]` entries" of this
  skill. The label list is the one exception: give it inline, taken from the previous release's
  section, because fragments drift (`[check]`, `[plugin:activerecord]`, `[sig-gen]`).
- **Say that read-only `git log` and `gh` queries are allowed and expected.** A brief that said
  "read-only" without that sentence made two of four rewriters skip the fragment-to-PR lookup.
- **Name the internal families to drop**, such as engine-slice plumbing, memo audits and
  measurement-only env vars. That took the drop calls off the coordinator.
- **A fragment in two sections** (the same slug under `changed/` and `fixed/`) goes to one owner, and
  the brief says which one.

The small tier (Haiku 5.5) is not enough for the seal: consolidating, and deciding what a user sees,
is the step.

## The completeness check: the small tier, after assembly

Classify the `comm -23` output, the merged PRs that no bullet links, as user-facing or internal,
from each PR's touched files (`gh pr view N --json title,files`). Run it **after** the coordinator
has assembled the section and added the fragment lookups. On v0.4.8 it ran on the pre-lookup list,
and five of its 24 "user-facing" PRs were already linked. Tell it two things, or it flags them:

- `editors/vscode/` keeps its own `CHANGELOG.md`, so those PRs are out of scope.
- A PR whose `lib/` change its own body calls behaviour-neutral is internal.

The coordinator decides each remaining user-facing PR: add it to a bullet (usually as a child item
or an extra link) or record it as internal.

## The post-mortem

Of the two read-only agents in § "File the next dev-loop post-mortem", the GitHub-side one collects
counts with `gh` and fits the small tier. The transcript-side one clusters findings and fits the
mid tier.
