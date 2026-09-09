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

**v0.3.8 is published** (`Rigor::VERSION` is `0.3.8`, `[Unreleased]` empty). The cycle under
`changelog.d/` is now large. The next cut happens only when the user invokes `/rigor-release-prep`.

## 2026-09-09 — twenty-two PRs across three batches

Every lane ran in its own `bin/rigor-worktree`, opened Draft, and merged on the user's word with its
master run green. Nothing from this session is open except #697, deliberately (below).

**Batch 3 — the false-positive sweep.** Six lanes, chosen because a check that fires on correct code
is the cost this project weighs heaviest.

- [#905](https://github.com/rigortype/rigor/pull/905) closed #656 and #655 — a constant PATH now
  resolves the way Ruby resolves it, one segment at a time: the first through the lexical nesting
  then the enclosing class's ancestors, each later segment inside the constant the previous one
  produced. `Reflection.resolve_constant_path_name` (new `lib/rigor/reflection/constant_path.rb`)
  takes the caller's acceptance test, so the constant typer and `Narrowing`'s class-guard resolver
  cannot answer different names for one spelling. #655 then needed only routing
  `case_when_pattern_certainty` through it. MRI 4.0.5 is the ground truth in the comments: a later
  segment does NOT reach the top level, for a Module owner as much as a Class.
- [#904](https://github.com/rigortype/rigor/pull/904) closed #667 — `flow.always-truthy-condition`
  is withheld from a value COPIED out of a published constant (a local, an ivar, a same-file alias).
  The mark is a SECOND `Set` on `Scope`, not a third kind on ADR-58's: it joins by union where that
  one intersects, and answers what a value's constancy rests on rather than what a binding's
  optionality rests on. The alias is not flow, so it took the census route instead.
- [#903](https://github.com/rigortype/rigor/pull/903) closed #703 — a meta-new factory written
  through a constant path (`Holder::Thing = Struct.new(:a) do … end`) is recognised as the class it
  names. Wider than filed: the two member-layout walks, `walk_singleton_def_nodes` and
  `walk_method_visibilities` keyed on `ConstantWriteNode` too.
- [#902](https://github.com/rigortype/rigor/pull/902) — the INTERIM half of #697 only (see below).
- [#901](https://github.com/rigortype/rigor/pull/901) closed #701 — a `dynamic_return receivers:`
  entry names the receiver KIND in RBS's own spelling: `"Widget"` is an instance, `"singleton(Widget)"`
  the class object, both listed means both. An instance rule no longer answers on the class and (since
  #653) no longer silences that call's `call.undefined-method`. `rigor-ffi` migrated to the
  both-kinds spelling; the four actionpack rules deliberately stay instance-only.
- [#899](https://github.com/rigortype/rigor/pull/899) closed #657 — the positive edge declines `Bot`
  on an `:unknown` ordering for the shape and singleton carriers too. #751 had already fixed the
  `Constant` carrier the issue's repro used; three carriers were still collapsing. The helper can
  only ADD a decline — every caller keeps its `subclass_of?` test and the answer is always `Dynamic`.

**Batch 2 — the `ready-for-agent` sweep**: #892 (#732), #893 (two of #722's residues), #894 (#790),
#895 (#710), #896 (#728), #897 (#720).

**Batch 1**: #869 (#821), #888 (#882), #865 (#853), #866 (#862), #868 (#861), #890 (#806), #891
(#807), plus three structural gates closing the "a second build entry drops an input" family —
#864 (#849), #880, #886 (#876).

## Open threads

- [#697](https://github.com/rigortype/rigor/issues/697) stays OPEN on purpose. #902 shipped only the
  loud-not-silent half: a config warning when `signature_paths:` loads a bundled plugin's `sig/`
  while `plugins:` does not name it. The false positive itself is unchanged, and a spec PINS that it
  still fires so nobody mistakes the warning for the cure. The real fix waits on
  [#660](https://github.com/rigortype/rigor/issues/660) — a manifest-independent home for
  open-receiver membership. Do NOT add a fourth protection route beside the manifest lookup,
  `synthesized_stub_receiver?`, `GEM_OVERLAY_OPEN_RECEIVERS` and #672's twin-`sig/` route.
- [#722](https://github.com/rigortype/rigor/issues/722) stays open for its last residue only (a
  compact header's leading segment); its title says so.
- Filed by batch 3: [#898](https://github.com/rigortype/rigor/issues/898) (`ready-for-agent` — the
  singleton model ignores `extend`, so `extend Comparable` keeps its FP) and
  [#900](https://github.com/rigortype/rigor/issues/900) (`ready-for-human` — #657's precision half;
  its body carries the hazard that joining an in-source `include` DERIVES a positive edge and would
  license a fresh FP on an `else` arm).
- #905 leaves `Narrowing`'s SINGLE-segment guard resolution without an ancestor rung, so
  `x.is_a?(B)` can still name a top-level `B` while the constant read beside it answers `Base::B`.
  That is the #652 consistency family.

## How to enter

1. Nothing is uncommitted and no PR of this session's is open. Other sessions merge to master
   throughout, so re-derive any file:line at current HEAD.
2. The backlog is `gh issue list --label ready-for-agent`. #693, #673, #668, #663, #661 and #898 are
   independent and unblocked. #693 asks to SIZE the shapes with a movable-site probe first — it is
   precision-only and the issue says so.
3. Remote CI as the gate, with NO local `make verify`, is the default worth repeating: targeted
   specs plus rubocop locally, rebase onto master immediately before pushing. Two batches ran that
   way with every first CI run green, and it removes the machine-wide lock entirely.
4. `FixtureHarness` under-detects versus the CLI: on a flat fixture with no `sig/`, both
   `call.undefined-method` and the class-pattern certainty decline on classes RBS does not know, so a
   wrong answer shows as fewer mismatches than a user would see. Use a project fixture with `sig/`
   when the point is the diagnostic. A `case` assigned to a local routes through the flow side's
   union and never consults per-pattern certainty — write the `case` inline to test that path.
