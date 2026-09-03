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

**Ten PRs landed 2026-09-03** through the worktree → adversarial-review → draft-PR pipeline:
#654 (#626), #664 (#635), #666 (#632), #669 (#644), #675 (#658), #676 (#665), #677 (#623),
#685 (#652), #688 (#674), #691 (#680), #692 (#681 census half), #694 (#683). The review rounds
produced **27 new issues**, all with reproduced repros.

Two multi-PR arcs closed, and both are worth knowing before picking up their leftovers.

**Constant resolution.** #685 stopped the engine reconstructing lexical nesting by string-peeling a
qualified name (which cannot tell a compact `class A::B` from the nested spelling) and made it
RECORDED at declaration time, closing constant reads, `is_a?`, `case`/`when` and `===` in one repair.
#692 did the same for `ScopeIndexer`'s four census scopes. **What remains is
[#681](https://github.com/rigortype/rigor/issues/681)** — the callee re-walk
(`ExpressionTyper#build_user_method_body_scope`), now the ONLY `Scope.new(… self_type:)` in `lib/`,
so it is the last of that family. Unlike the census half it needs the def-node index to carry the
chain; there is no prefix in hand. Siblings: [#690](https://github.com/rigortype/rigor/issues/690)
(FP-capable, see below), [#682](https://github.com/rigortype/rigor/issues/682) (superclass names
still peel), [#655](https://github.com/rigortype/rigor/issues/655),
[#656](https://github.com/rigortype/rigor/issues/656),
[#662](https://github.com/rigortype/rigor/issues/662).

**Absence assertions passing on crashed analysis.** A raising check rule leaves ONE
`internal analyzer error` diagnostic and discards the rest, so `not_to include` / `to be_empty` /
`all(eq(...))` all pass. #676 guarded the shared helpers, #688 the ~200 local wrappers (1,177 of
1,925 examples had been passing with every rule crashing), #694 `IncrementalSession`. **Two entry
points remain and neither is reachable from the spec side** — they run `Runner#run` inside `lib/`:
[#686](https://github.com/rigortype/rigor/issues/686) (`ClosureKillOracle` scores a crashed run as a
*survivor*, inflating the mutation harness's headline signal in the direction that manufactures work)
and the `SystemExit`-escapes-the-runner's-`StandardError`-rescue hole named in
[#680](https://github.com/rigortype/rigor/issues/680)'s PR. A `Result#crashed?` predicate would serve
both plus the spec guard from one definition instead of three string matches.

## Backlog, ranked

1. **[#690](https://github.com/rigortype/rigor/issues/690)** — `Foo::BAR = Post` inside a `module`
   fires `undefined-method` on correct code. Two compounding causes (the entry is mis-keyed on the
   as-written name AND its rvalue is typed at top level); fixing only one leaves the firing.
2. **[#653](https://github.com/rigortype/rigor/issues/653)** — a plugin-typed call still reports
   `call.undefined-method` when a partial RBS declares the receiver, so *writing more RBS makes a
   project's diagnostics worse*. Cheap; removes a perverse incentive.
3. **[#672](https://github.com/rigortype/rigor/issues/672)** — a gem overlay does not stand down for
   `signature_paths:`, so both halves load, the class collapses to `Dynamic`, and the run exits 0
   with **zero** diagnostics. Same "reports less, still green" family as the guard work.
4. **[#681](https://github.com/rigortype/rigor/issues/681)** (above) and
   **[#689](https://github.com/rigortype/rigor/issues/689)** — after #691, `Acceptance.resolve_class`
   no longer kills the run but still EXECUTES an autoload silently. The bug stopped announcing
   itself; urgency down, care needed up.
5. **[#574](https://github.com/rigortype/rigor/issues/574)** (ready-for-HUMAN) — still the sole
   blocker on the corpus's biggest pair (`Parameters#[]`, 581 redmine + 496 mastodon). Measurement
   DONE on the issue; not agent-adjudicable.
6. Rails/AR follow-ups with repros: [#658](https://github.com/rigortype/rigor/issues/658)'s
   descendants [#659](https://github.com/rigortype/rigor/issues/659) (unblocked),
   [#670](https://github.com/rigortype/rigor/issues/670) (note the `-> self` sizing comment),
   [#673](https://github.com/rigortype/rigor/issues/673), plus
   [#678](https://github.com/rigortype/rigor/issues/678),
   [#679](https://github.com/rigortype/rigor/issues/679),
   [#671](https://github.com/rigortype/rigor/issues/671).

## Measurement — read this before writing a gate or trusting a number

- **A gate an issue prescribes can be green while the change ships FPs.** #632's was "no new firing
  on redmine/mastodon"; those configs scope `paths: [app, lib]` while the affected sites were under
  `spec/` and in ERB fixtures. Only an adversarial fixture found the nine.
- **A collapsed class, and a crashed run, both produce zero diagnostics** — so "nothing fires"
  passes on the failure. Gate on a declared return RESOLVING, or on the autoload NOT having fired.
- **"Byte-identical diagnostics" is often inert, not probative.** `lib/rigor` and `plugins/*` contain
  ZERO compact declarations; mastodon's stream over the relevant files is almost all plugin rows.
  #692's answer is the pattern to copy: a Prism probe counting sites that CAN move, then adjudicating
  each — it found a real mastodon instance that moves no diagnostic at all.
- `rigor check` on an explicit FILE LIST can fire a false `undefined-method` the same check over the
  DIRECTORY does not ([#684](https://github.com/rigortype/rigor/issues/684)), so per-directory sums
  over-report. Pass directories.
- CRuby's `lib/` was probed for opacity this cycle: stdlib-proper precision **72.7%**, whole tree
  64.5% (vendored bundler/rubygems is 65% of the named-receiver residue). The top stdlib clusters are
  all honest `void`/`untyped` — non-levers. Note the lens counts `-> void` as opaque.

## Pipeline notes (each earned by an incident this cycle)

- **A "found it" report is reproducible; its CHARACTERISATION is not.** Three issues were filed with
  the implementer's framing and had to be corrected after review measured it — #684's mechanism,
  #689's scope, and #690, filed as "FP-safe" when it fires on correct code. File the repro; verify
  the framing separately.
- **Check a normative `MUST` against the code it ships with.** Four branches this cycle wrote spec
  text broader than their implementation; every one was caught by review, none by a gate.
- **A gate is not safe because it exists.** #688's satisfaction rule was textual (a comment naming
  the constant laundered a run); #694's extension then introduced an FP that rejected the exact
  manual shape the gate's own message recommends.
- Workers: find affected specs by GREPPING changed identifiers (two files are named
  `pre_eval_constants_spec.rb`); lint your own diff with
  `git diff --name-only origin/master...HEAD | grep '\.rb$' | xargs rubocop --force-exclusion`.
- Landing traps that LOOK like a red gate: `gh pr view --json headRefOid` lags a push; editing a
  script while a background invocation runs it corrupts that process. File the follow-up issue
  BEFORE opening the PR that cites it — a PR twice took the number it referenced.
