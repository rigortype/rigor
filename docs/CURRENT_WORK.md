<!--
The session handoff (ADR-98). It answers ONE question: what should the next session do?

- REPLACE this file's content when you take work across the finish line; never append under it.
  Anything that would outlive two sessions does not belong here: backlog → a GitHub issue
  (docs/agents/issue-tracker.md), operational pitfalls → the workflow's skill, decisions → an ADR,
  measurements → docs/notes/, shipped → CHANGELOG.md.
- Verify a claim before carrying it forward. This cut's own lesson: a green `make verify` proves the
  pinned bundle works, not the supported range. Two of this session's three regressions were only
  visible from outside the pin — the rbs 3.x CI job and `rbs -I sig validate`.
-->

# Current Work — Session Handoff

Transient; replaced wholesale. Backlog lives in GitHub Issues, release planning in Milestones
(`v0.3.0` / `v0.4.x` / `v1.0.0`). If this file disagrees with an ADR, the CHANGELOG, or an issue,
this file is the one that is wrong.

## Where things stand

- **v0.3.1 is released** (2026-07-29): tag, RubyGems push, and GitHub Release all exist. No version
  bump is due — releases wait for an explicit ask.
- **[#230](https://github.com/rigortype/rigor/pull/230) landed the rbs-4.1 backports for the rest of
  the supported range**: a `Resolv#initialize` core overlay (the Mastodon FP, ruby/rbs#2960) and an
  invalid-UTF-8 quarantine ahead of the RBS parser. Writing the latter's spec surfaced that invalid
  UTF-8 crashes the **pinned 4.1** too (bare `ArgumentError` out of `RBS::Parser.magic_comment`, no
  `ParsingError` rescue catches it) — the guard is a live crash fix, not only a 3.x hang guard. The
  same pattern is still missing from sig-gen's re-parse sites (`layout_index.rb:77` /
  `writer.rb:522`); a task chip for it is pending with the user.
- **The 2026-07-29 session followed `rbs` 4.1.0** ([#225](https://github.com/rigortype/rigor/pull/225))
  and cut the release ([#226](https://github.com/rigortype/rigor/pull/226)). It also landed
  `sig/rigor/inference/void_origin.rbs` directly on `master` (e3b132a3) and merged
  [#223](https://github.com/rigortype/rigor/pull/223), an external README link fix from @f440.
- **The `0.2.x` cycle is archived** to `docs/CHANGELOG-0.2.x.md` — the archival rule fired at
  `0.3.1`. `CHANGELOG.md` is back to 216 lines from 497.
- Issue [#144](https://github.com/rigortype/rigor/issues/144) closed (it had outlived its work by a
  release). Three new issues opened — **#227** / **#228** / **#229** — all from what the rbs bump
  surfaced; #229 / #228 / #207 each carry a grounding comment (facts checked against the v4.1.0
  tree and this codebase) so their evaluations start from evidence, not recall.
- `make verify` (8,286 examples) and `make docs-check` clean at the release commit; the only change
  on top of it is markdown.

## Next session

Nothing is release-blocking. The two v0.4.x decision items are unchanged and still
`ready-for-human` — they need a call, not an implementation:

- **[#204](https://github.com/rigortype/rigor/issues/204)** (area:engine) — wire ADR-46 cross-file
  caller→callee-param edges so `parameter_inference:` composes with `--incremental` (lifts the WD6c
  mutual exclusion). Needs the edge-recording design call.
- **[#205](https://github.com/rigortype/rigor/issues/205)** (area:engine) — decide whether to flip
  `parameter_inference:` on by default (ADR-50 gate; needs accumulated protection evidence plus a
  mutation-oracle honesty check on the WD6b guard). Not before the evidence exists.

Agent-ready work, effort-ordered:

- **[#227](https://github.com/rigortype/rigor/issues/227)** (area:sig-gen) — `sig-gen` cannot read
  `Const = Data.define(...)`: it emits the enclosing *module* as a `class`, drops the class name and
  every member, and keeps only the block body's methods. Wrong output, not merely thin, and it is
  what forced this session into hand-written RBS against the AGENTS.md policy. Bounded, with a
  reproduction in the issue.
- **[#207](https://github.com/rigortype/rigor/issues/207)** (area:perf) — unchanged from the last
  handoff: the traversal-sharing lever is exhausted (−0.49% was all of it), so what remains is
  **per-collector allocation attribution** to find where the v0.3.0 +45.7% drift lives. An
  investigation, not a refactor.
- **[#229](https://github.com/rigortype/rigor/issues/229)** (area:plugins) — decide which inline-RBS
  implementation Rigor speaks. `rigor-rbs-inline` is built on the `rbs-inline` gem, but rbs 4.1's
  three new inline features (`def self.`, `module-self`, module-level ivar annotations) landed in
  RBS's *built-in* `InlineParser`. ADR-93 default-wires the plugin, so this is the whole user base's
  dialect, not an opt-in group's. The outcome belongs in an ADR-32 amendment.
- **[#228](https://github.com/rigortype/rigor/issues/228)** (area:sig-gen) — evaluate `RBS::Rewriter`
  (new in rbs 4.1) for the `sig-gen` writer's in-place update path. Explicitly an evaluation; "no,
  because" is an acceptable answer, and the rbs-floor question is the crux.
- **#121** — ongoing FP-safe builtin/stdlib folds (demand-gated).
- The editor cluster is now **#142** / **#146** / **#147** (#144 shipped in v0.3.1) — still the
  largest untouched `ready-for-agent` block in the v0.4.x milestone.

## What this session learned that is not in a commit

- **A green `make verify` only proves the pinned bundle.** The gemspec supports `rbs >= 3.0, < 5.0`,
  and the `Elem` → `E` spec updates that made 4.1 pass broke the 3.x half of the `rbs-compat` CI job
  — a failure `make verify` cannot see by construction. Reproduce that job locally (a
  `Gemfile.rbs-compat` pinned to the other end of the range) *before* pushing a change to a
  version-ranged dependency. The fix pattern is a support helper that reads the installed version
  (`spec/support/rbs_core_type_params.rb`), never a name hard-coded from one side of the range.
- **`rbs -I sig validate` is a gate nothing else runs.** `sig/rigor/scope.rbs` had referenced an
  undeclared `Inference::VoidOrigin` since the `static.value-use.void` diagnostic landed, and
  `make check` stayed green throughout because Rigor stubs a missing referenced type — our own
  fail-soft was hiding a hole in our own `sig/`. Worth running after any `sig/` edit.
- **A dependency that starts memoising an identity-ish value is a cache hazard.** rbs 4.1 cached
  `TypeName#hash` in an ivar; the value derives from per-process-seeded `Array#hash`, and `Marshal`
  carries ivars verbatim, so every cached type name came back `eql?` but unequal-hashing and every
  `class_decls` lookup missed. Nothing raised. A same-process round-trip spec cannot reproduce it —
  the guard has to poison the ivar to stand in for the writing process
  (`spec/rigor/cache/rbs_environment_marshal_patch_spec.rb`).
- **Spot-check a core-signature bump against a real project before cutting.** rbs 4.1 rewrote
  `Array` / `Hash` / `Integer` / `String`. An A/B on Mastodon (same engine, `--no-baseline`) gave
  **0 new diagnostics, 1 removed** — the removed one a genuine FP that ruby/rbs#2960 fixed upstream.
  Ten minutes, and it is what turned "the suite is green" into "this is safe to ship".
