<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Last session's own "next unaudited sections" pointer was wrong.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## Where the cycle stands

**Thirty-three PRs landed 2026-09-01/02** through the serial landing pipeline (worktree fleet →
corpus arms → independent critical review → draft-PR remote CI → chained merge). Batches 1-3
(#571-#608) are recorded in the git log; the later batches are what a next session needs:

- **Batch 4** — #612 (#577 absence-edge cache dependencies), #616 (#586 a declared/untyped Array
  carrier survives the block join), #619 (#590 constant-assigned `Struct.new … do` bodies entered
  as class bodies), #620 (#587 block returns threaded through captured content mutation).
- **Batch 5** — #624 (#583 de-rooted model keys + reopen merge), #628 (#588 Rails-surface
  follow-ups incl. the railties reader gate's ADR-46 negative edge), #636 (#618 a class's own
  method beats a same-named top-level `def`), #641 (#613 boundary existence probes record
  absence rows), #642 (#614 rooted `::Foo` resolves from the top level).
- **Batch 6** — #646 (#621 rooted keys + reopen merge across six sibling Rails plugins), #647
  (#627 the dead arm of a decidable version guard is unreachable), #648 (#622 an unresolved
  constant read records its absence edge), #649 (#631 a Union seed's non-collection arms survive
  the content seam), #650 (#615 `Array.new(n)` seeds a real element arm).

**Corpus effect of batches 4-6: precision flat, correctness dominant.** The probe on post-#624
master moved <0.3pp anywhere; what these PRs bought is wrong-type answers on correct code. Every
engine PR's review round found at least one verified false positive the corpus arms could NOT see,
and in batch 6 the corpus caught one the reviewers had not (#650's `::Array.new(count, nil)`) —
**the two instruments stay mandatory together, in both directions**.

**Survey config repaired:** redmine's and mastodon's `.rigor.dist.yml` both omitted
`rigor-railties`; adding it left diagnostics byte-identical and moved the probe (mastodon
55.47→55.65, redmine 53.49→53.58). The saved base arms in the session scratchpad were re-collected
with it. `rigor-survey` is not a git repo — that edit is unversioned.

## Backlog, ranked

1. **[#574](https://github.com/rigortype/rigor/issues/574)** (ready-for-HUMAN) — the witness-gate
   vacuity, still the sole blocker on the corpus's biggest pair (`Parameters#[]`, 581 redmine +
   496 mastodon). Measurement DONE and on the issue: tightening refuted (7 FP : 27 TP), nilable
   `Parameters#[]` alone costs +2. Not agent-adjudicable.
2. **Precision levers sized by the 2026-09-02 probe**, both agent-doable:
   [#635](https://github.com/rigortype/rigor/issues/635) (declared RBS `attr_reader`s on Rigor's
   own `Type` objects answer `Dynamic` in `lib/` — ~300 sites, and the mechanism covers every
   `Type::*` reader), [#632](https://github.com/rigortype/rigor/issues/632)
   (`ActiveSupport::Duration#ago` / `#to_i` and the other readers are undeclared — 93 mastodon
   sites).
3. **External user reports, untriaged:** [#610](https://github.com/rigortype/rigor/issues/610)
   (the plugin's generic `Relation[Elem]` collides with gem_rbs_collection's non-generic
   `Relation`, degrading every AR relation to `Dynamic` — needs a reconciliation design),
   [#609](https://github.com/rigortype/rigor/issues/609) (`sig-gen --write` emits a `sig/` the
   next run cannot load, yet exits 0), [#611](https://github.com/rigortype/rigor/issues/611).
4. **Filed from batch 5-6 reviews, with repros, agent-doable:** #626 (drop rigor-railties'
   `::Rails` hard-code — now unblocked, both halves landed), #637 (`class X < ::Base` inherits the
   shadow), #638 (`class ::Foo` inside a module is keyed `MyApp::Foo`), #644 (cross-file value
   constants never resolve), #645 / #643 (mutation evidence on Union receivers and nested literal
   containers), #633 (the own-method veto's inherited-source residues), #617, #623, #629, #630,
   #634, #639, #640, #625.
5. Struct frontier, settled by measurement (do not re-derive): #597, #599, #601.

## The landing pipeline (it caught 10+ FPs the corpus missed this cycle)

- Implementation parallel in worktrees (`.bundle/config` copy + `vendor` symlink; NEVER
  `git stash` — shared stack; COMMIT before any `git checkout <sha> -- <file>` baseline swap).
  The worker brief is a contract file (Flake, no full gates, spec pairing, fragment grammar,
  **never override the commit author**).
- ONE heavy job on the machine at a time (a 4×`make verify` fleet OOM-killed the host at 200GB+).
  Workers: single spec files + `--workers=0` fixtures only; corpus arms are local and serial.
- Draft-PR remote CI is the post-rebase verification; PRs stay **Draft until every gate is green**.
  The chain that holds: rebase → `push --force-with-lease` → ONE `set -e` script that watches the
  head's checks by exit code (8 = pending), `gh pr ready` + merge only on 0, then watches the
  MASTER merge-commit run to its conclusion. Validate a PR number before writing it anywhere.
- Same-day PRs that each APPEND a section to one ADR (or a `describe` to one spec file) conflict
  on rebase — keep both, renumber (ADR-56 reached WD2.12 that way), re-rebase after each lands.
  Strip the diff3 markers cleanly: a leftover blank line failed one Lint job.
- Every engine PR gets an adversarial review with VERIFIED findings; REQUEST-CHANGES round-trips
  to the implementing worker; a delta re-check goes to the SAME reviewer via SendMessage so its
  context is intact. Reviewer measurements are sometimes wrong — relay both ways.
- **When subagents are unavailable** (batch 6 hit an API spend limit mid-flight), the coordinator
  can self-review and land, but the PR must say so on the record. Every branch's work survived
  because workers commit as they go.

## Pitfalls that still bind

- `rigor type-of` can't see discovery-seeded joins; `rigor type-scan` can't see Dynamic→precise
  changes — pick the instrument per question. The precision ratio under-credits
  `dynamic_specific`; pair it with the FP tally. `model-call` / `worker-call` rows are `info`
  recognition traces, not diagnostics.
- Compound-shell A/B arms inherit `cd` from earlier lines in the same Bash call; one invocation
  per arm, explicit cwd. A CPU A/B needs the target's `--config` or it measures boot.
- The fixture auto-formatter strips "useless" if-guards and reassignments, and rewrites
  `Array.new` to `[]` — write such fixtures via script or heredoc, never an editor tool.
- GitHub mergeability lags pushes; retry with backoff. Read gate exit codes in their own call.
