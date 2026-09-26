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

## Special-variable semantics (2026-09-25/26)

The effort audited Rigor's special variables against dak2's talk 「特殊変数大全」
(<https://speakerdeck.com/dak2/tokushu-hensuu-taizen>). `$~` and `$_` live in the method frame's
svar, `$!` and `$@` come from the rescue frame, `$?` is thread-local, and `$/` and `$stdout` are
process-wide. The audit filed #1358–#1367 and landed them one lane at a time. Each lane had its own
worktree, an implementer agent, an independent Opus review, and CI.

Landed on master:

- #1370 (#1358): a match inside a block or closure rebinds the method's `$~`. The spec now calls the
  match globals frame-local.
- #1374 (#1364): a call into a Ruby method keeps the caller's `$~`.
- #1378 (#1365): builtins that rebind `$~` are recognised precisely, including in operand position.
- #1392 (#1361): Thread, Fiber and Ractor root blocks get a fresh `$~`. `define_method` bodies read
  bound globals as `Dynamic`.
- #1405 (#1359): `$_` is frame-local, and a `$stdin.gets`-style reader condition narrows it. An
  implicit-self `gets` does not narrow, which was the user's conservative call.
- #1418: ADR-117, "Standard streams: typed by idiom, checked by runtime contract".
- #1425 (#1360): `$!` and `$@` are bound in rescue clauses, and `$?` after a subprocess.
- #1433 (#1362, in part): a builtin global's seed joins its non-nil RBS type. The nil-bearing
  separators are split out to #1437.
- #1442 (#1363): effect labels for the special variables.
- #1444: fix for `type-of`, `annotate`, `sig-gen` and `trace` crashing with `NameError` after #1433.
- Check that master CI on `7e48c8705` finished green; it was still in progress at handoff.

## What the next session should do

1. Two user decisions are pending. Ask before implementing either one.
   - #1426: the config shape for scoped `pre_eval:` entries and global writes as patches. It amends
     ADR-17. #1427, where `rigor-project-init` writes the entry, is blocked on it.
   - #1367: rule ids and default severity. The scope is already fixed by ADR-117 WD2: only
     `_Writer` violations on `$stdout`, `$stderr` and `$>`, never `$stdin`.
2. #1366 (unbound global reads fall back to RBS) has a fixed order under ADR-117:
   - first #1429 (class guards and truthiness on global and constant receivers);
   - then #1426, then #1427, then #1366's stream part, which now also carries the `$>` → `$stdout`
     alias;
   - the `$_` part waits for #1415;
   - WD6 holds throughout: a declined or forgotten `$_` stays `Dynamic`.
3. `ready-for-agent` follow-ups, all in milestone `v0.4.x`, most fundamental first:
   - #1429: class guards on global and constant receivers.
   - #1415: implicit-self `gets` narrows, under ADR-117 WD5.
   - #1437: the separators, which need a nil-only provenance record.
   - #1423: a singleton `def gets` in any file declines `$_` narrowing.
   - #1375: loop back edge versus `$1`.
   - #1372: a failing `when` / `in`.
   - #1371: gsub, sub, scan and grep blocks, and lambda bodies.
   - #1379: `!~` guards.
   - #1416: `then` / `tap` blocks that run once.
   - #1373: Regexp constants from another file.
   - #1443: the `English` aliases.
4. Triage queue: #1376, #1377, #1380, and #1445 (LSP intermittently reports
   `unresolved-toplevel`). Ready for a human: #1400, #1417.

## How the lanes were run (and what bit)

- The invariant, relative to the base: add no diagnostic on correct code, and never newly keep a
  narrowing where Ruby rebinds. The review stops at three rounds. Each time round 3 was still
  severe, the user chose the conservative reading or a split (#1374, #1378, #1405, #1433). Escalate
  to the user; do not decide alone.
- The corpus A/B came out 0/0 on every lane, because these shapes barely occur in the survey
  targets. The fixtures carry the evidence, so do not treat a clean corpus as proof of FP safety.
- In-process specs cannot see a missing `require`; #1444's crash passed CI. A CLI path that skips
  `check_rules` needs a subprocess spec (`spec/rigor/cli/type_of_standalone_load_spec.rb`).
- Master moved under the lanes. Before merging, merge origin/master, rerun the overlapping specs,
  and wait for CI on the merged head.
- Subagents hit the weekly API limit once; it resets 2026-09-30 18:00 JST. Resuming the same agent
  with a status note recovered the lane.
