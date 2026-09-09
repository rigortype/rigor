<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Hard cap: 120 lines, enforced by spec/docs/agent_index_spec.rb. Compress, do not append.
- Verify a claim before carrying it forward, by the thing that decides rather than a proxy —
  including claims in THIS file. Three sessions running, its own pointers have been wrong.
-->


# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones.
If this file disagrees with an ADR, the CHANGELOG, or an issue, this file is the one that is wrong.

## Where the cycle stands

**v0.3.8 is published** (`Rigor::VERSION` is `0.3.8`, `[Unreleased]` empty). Post-cut fragments ride
under `changelog.d/` — the cycle is now large. The next cut happens only when the user invokes
`/rigor-release-prep`.

## 2026-09-09 — sixteen PRs landed across two batches

Every lane ran in its own `bin/rigor-worktree`, opened Draft, and merged on the user's word with its
master run green. Nothing from this session is open.

**Batch 2 (the `ready-for-agent` sweep)** — six issues, run with NO local `make verify` at the
user's instruction: targeted specs plus rubocop locally, remote CI as the gate, and a rebase onto
`origin/master` immediately before each push. That removed the lock contention that made batch 1's
last lane wait ~55 minutes, and cost nothing: every lane's first CI run was green.

- [#897](https://github.com/rigortype/rigor/pull/897) closed #720 — `yield` now evaluates to the
  block the CALLER passed. The root was one line (`Prism::YieldNode => :type_of_dynamic_top`), not
  sig-gen's skip rule. The call site's `block_return_type_for` is threaded into
  `infer_user_method_return` as a frame; the FP bound is structural (the value reaches the caller
  only by ordinary evaluation of the callee's body), the frame is installed even when nil so a
  blockless callee cannot inherit an outer block, and the yield type is a fourth call-site-varying
  dimension of the ADR-84 memo, dropped for a def that cannot reach a `yield`. Measured FP-free:
  diagnostics byte-identical on `lib`, plugins/examples and four gems; `sig-gen` over `lib` emits 2
  MORE methods, none lost.
- [#896](https://github.com/rigortype/rigor/pull/896) closed #728 — each ancestor name resolves in
  the cref of the site that WROTE it. `discovered_header_nestings`' value is re-keyed per ancestor
  name (no new table, every carrier is shape-agnostic); a `nil`-keyed entry holds the old union for
  a name no site recorded, so `Recv.class_eval { include M }` and dynamic mixins keep the pre-fix
  candidate list. `IncrementalSnapshot::SCHEMA` 17 → 18: the value is an Array now, and a tolerant
  reader would serve the per-class union warm.
- [#895](https://github.com/rigortype/rigor/pull/895) closed #710 — a `Klass = Class.new { self::X
  = 7 }` no longer retracts a sibling file's `X = 5` (the class IS nameable through the enclosing
  write; `meta_new_block_owner` threads it one hop), and `local_constant_names` is no longer
  exempted by a write through a dynamic base. Two census tables, not one richer descriptor: the
  conflict rule and the exemption want opposite answers about the same write.
- [#894](https://github.com/rigortype/rigor/pull/894) closed #790 — the kill oracles refuse an
  analyzer-defect run, and `ClosureKillOracle` REBUILDS its Environment after one (the #784 seam
  memoises the degraded registry, so one poisoned mutant contaminated every later one). The defect
  is asked of two surfaces because each covers the other's blind spot: the row is severity-stamped
  (`severity_overrides: {rbs: off}` deletes it), while `Environment#hkt_scan_failure` is recorded
  pre-severity but only ever describes THIS process's Environment.
- [#893](https://github.com/rigortype/rigor/pull/893) — two of #722's four residues: sig-gen's
  renderer (four walks, not the one the issue named) and `definition_lines`' unmatched key, both
  now anchoring a rooted header through `Source::ConstantPath.declaration_prefix`.
- [#892](https://github.com/rigortype/rigor/pull/892) closed #732 — `known_user_class?` is asked of
  the `Scope`, not re-implemented in `CheckRules`. The issue's own "Consequence today" was wrong
  (its author retracted it): the visibility rule is inert here, and the consumer that actually
  moves is `nearest_ancestor_method_def`, so the fix lands in the ADR-35 Liskov rules.

**Batch 1** — #869 (#821), #888 (#882), #865 (#853), #866 (#862), #868 (#861), #890 (#806), #891
(#807), plus three structural gates closing one family (a second build entry of the RBS environment
silently dropping an input): #864 (#849, the cache producer), #880 (`Environment.for_project` vs
`ProjectEnvironment.dependency_discovery_options`), #886 (#876, the descriptor's digest). All three
read the keyword list off the method itself, so the next input lands red instead of shipping.

## Open threads these batches leave

- [#722](https://github.com/rigortype/rigor/issues/722) stays open for its LAST residue only (the
  title now says so): a compact header's leading segment. Reproduced, and left because it is a
  different shape — the segment resolves by ordinary constant lookup, so the answer depends on
  whether `Wrap::Outer` exists project-wide, while `declaration_prefix` is a pure per-node function
  with ~30 call sites. Guessing top level when the namespace is merely not discovered answers with
  a wrong class, worse than today's silence.
- #897 leaves a yielding helper's OWN signature declined (its honest type is generic), and `yield`'s
  arguments still untyped and arity-unchecked (pre-existing).
- #894 leaves the standalone `DiagnosticOracle` armed but without a rebuild path: after a defect it
  refuses every later mutant. That reads as "could not measure", where the pre-#790 behaviour said
  "survived".
- #896's movable-site probe (per-site vs per-class across rails/mastodon/gitlab) was NOT run; the
  corpus is inert for this family by the issue's own analysis, but that half of its gate is missing.
- #891's cross-process probe lives on branch `probe-807-marker-race` (`tmp/probe-807/`).

## How to enter

1. Nothing of this session's is open or uncommitted; its lane worktrees are removed. Other sessions
   merge to master throughout, so re-derive any file:line at current HEAD.
2. The backlog is `gh issue list --label ready-for-agent`. #703, #701, #697 and #693 are
   independent and unblocked.
3. Running lanes with remote CI as the gate (no local `make verify`) worked well and is the default
   worth repeating: it removes the machine-wide lock entirely. Keep the targeted specs and rubocop.
4. A merge whose master run is CANCELLED is usually a sibling session's push overtaking it, not a
   failure — confirm the commit is contained in master and watch the newer run.
