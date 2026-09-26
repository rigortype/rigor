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

## Special-variable semantics, second pass (2026-09-26/27)

This continues the audit of the special variables against dak2's talk 「特殊変数大全」, governed by
[ADR-117](adr/117-standard-streams-typed-by-idiom.md). v0.4.0 release prep is under way, so file
every newly found defect to milestone `v0.4.x`, never `v0.4.0`.

Landed on master, each with CI green on the merge commit:

- #1449 (#1415): an implicit-self or `self.` `gets` narrows `$_`, and declines on counter-evidence
  about `self` in the file. An `ensure` clause reads `$_` untyped. Implicit `readline` does not
  narrow yet (#1458).
- #1448 (#1367): new rules `global.write-type-mismatch` (literal values only) and
  `global.readonly-write`. A program-wide census declines on any definition of `write`, `to_str`,
  `to_int` or a hatch.
- #1453 (#1429): truthiness, class, `respond_to?` and `case` guards narrow global and constant
  receivers, and the narrowing is restored at any call that may rebind. A class guard disjoint from a
  non-literal subject reads `Bot` without `flow.unreachable-clause`, but a `case` value still drops
  that arm (#1465). A value-position `case` narrows each arm; the corpus lost 12 false positives.

Maintainer decisions recorded on the issues:

- #1426: the scoped `pre_eval:` shape is a mixed array. A string entry is project-wide; a mapping
  `{path:, scope:}` applies to its scope roots only.
- #1367: rule ids, severities and tier `high`; the literal-only amendment.
- #1429: three amendments. The last one is the conservative reading above.

## What the next session should do

1. **Pending user decision:** a one-line ruby/rbs PR adding `alias to_str to_s` to
   `stdlib/uri/0/generic.rbs`. Ruby has had it since 2018 (ruby/ruby `0164ce893f`), and rbs master
   still lacks it. It is an outward publication, so wait for a yes. It causes no Rigor report today.
2. **ADR-117 order:** #1426, then #1427, then #1366's stream part, which also carries the `$>` →
   `$stdout` alias. #1429 and #1415 are done, so #1366's `$_` part is unblocked. WD6 still holds:
   a declined or forgotten `$_` stays `Dynamic`. #1366 is still `ready-for-human`, because the
   go/no-go rests on its corpus result.
3. **#1454, phase 2** is unblocked now. It adds `docs/type-specification/global-variables.md`, an
   internal-spec "Special variables" map and `CONTEXT.md` terms. Phase 3, the handbook chapter,
   waits for #1366, #1426 and #1427.
4. **`ready-for-agent` in `v0.4.x`, cheapest first:**
   - #1467: `verify-changed` misses `provenance_spec`. This bit two lanes this session.
   - #1447: the ErrorInfo `$!` decline.
   - #1446: ivar class guards.
   - #1437: the separators.
   - #1423: a singleton `def gets`.
   - #1379: `!~`.
   - #1375: a loop back edge versus `$1`.
   - #1372: a failing `when` or `in`.
   - #1371: gsub-family blocks.
   - #1416: `then` / `tap` blocks.
   - #1373: cross-file Regexp constants.
   - #1443: `English` aliases. Its write side should reuse `SpecialGlobalSetters`.
5. **Triage queue (`needs-triage`)** — lanes filed these this session:
   - `ensure` and loop bugs: #1457 (#1397 may cover it), #1458, #1464.
   - Reader bugs: #1450, #1451, #1452, #1459.
   - Guard design and precision: #1465, #1461, #1462, #1463.
   - Perf: #1466.
   - Other: #1455 (misses of the `global.*` rules) and #1456 (OpenStruct fields report
     `call.undefined-method`, a real false positive on master).
   - Still waiting from before: #1376, #1377, #1380, #1445. Ready for a human: #1400, #1417.
6. Sibling Draft #1397 (another session's) restructures `eval_ensure`. It must keep #1449's ensure
   rule for `$_`; a PR comment explains how.

## How the lanes were run (and what bit)

- Three parallel lanes. Each had its own `bin/rigor-worktree` worktree, an implementer subagent, an
  independent Opus reviewer in a separate worktree, and a cold corpus A/B run by one lane at a time
  on a private rsync copy. The invariant against the base: add no diagnostic on correct code, and
  never newly keep a narrowing where Ruby rebinds. Resuming the same reviewer for delta rounds was
  fast.
- **Round 3 was still severe twice.** Both times (#1448 and #1453) the user chose to apply the
  reviewer's decline-only fallbacks and merge without a fourth round. Once, after round 2, they chose
  to withdraw a design that kept leaking (#1453's gradual arm, which moved to #1465). Escalate at
  these points; do not decide alone.
- **Designs that leaked:** a type introduced only by a guard crossed joins into typed sinks
  (`Nominal[C]`, then `Dynamic[C]`). Most severe findings in later rounds sat in code the previous
  round's fixes had added, including a crash on invalid-UTF-8 literals in #1448's new census.
- `make verify-changed` does not run `provenance_spec` (#1467). Run it yourself after touching
  `sig/`, or after an engine change that alters `sig-gen` inference.
- Selecting a `type_construction_spec` group by its `describe` line can run the previous group. Use
  `-e` or the `it` line when mutation-testing.
- The corpus copy and base-engine arms lived in the session scratchpad (`g1429/`), which is gone.
  Rebuild them per `docs/agents/measurement.md`.
