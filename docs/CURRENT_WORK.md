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

## State at 2026-10-09 (master after #1659)

**`v0.4.1` is released** (2026-10-08, tag `v0.4.1` = `8a5d6e2c6`, RubyGems and GitHub Release). It shipped
from master, ADR-119 C1d0 onward and C2-b1 included; the `0.3.x` notes moved to
`docs/CHANGELOG-0.3.x.md`. The Mastodon sweep precision floor went from 0.523 to 0.520 for C2-b1's accepted
loss, and the perf-gate corpus now is `v0.4.1` (#1659).

**ADR-119 C2-b1 landed (#1629)** with the `bot` exception (errata on the C2 rows). The maintainer
accepted its typing loss on master (Q9, 2026-10-08): GitLab controllers typed calls −74%, Mastodon
−21% (plugin dist configs). **#1651 gates v0.5.0**: recover or explicitly accept before that cut.
A1 (#1635) was closed: measured gain 0 under every sound relaxation; its follow-ups are #1647–#1650.

Also landed: #1638 (fixes #1637), #1655 (the `rigor lsp` spec read the process's stdin and hung any
local run under an agent harness — run long spec commands with `< /dev/null` anyway).

## Next

1. **Typing recovery for #1651**, by measured ceiling: #1649 (split the dynamic mark by side; +746
   Mastodon / +1,674 GitLab pairs, only together with #1650's plugin-vouched externals), #1650 (needs an
   ADR-2 design), #1608 (include-kind sentinel). Then C2-b2 (singleton typing memo) and C2-d (#1604).
   The design report behind these numbers is summarised on #1635 and #1649.
2. **Stale `--incremental` answers (severe class), all pre-existing on master:** #1647 (receiver-form
   writes from non-declaring files), #1641 (new file gives an external chain entry a hook), #1652
   (run-result slot ignores plugin state), #1654 (run-wide return memo replays an incomplete capture).
   Check whether each is in `v0.4.0` before scoping it into a patch.
3. **False positives / gaps filed this session:** #1656 (budget-cut chain FP, pinned), #1657
   (`define_method` beside a `def`, pinned FN), #1636, #1645, #1646, #1648, #1653.
4. Still open from before: #1622, #1608, #1611, #1612, #1592, #1594 (fixed at the typing site by C2-b1;
   check the issue), #1591, #1583, #1586, #1588, #1589, #1573, #1537, #1533, #1575; #120 goes to the
   maintainer as an ADR.

## Serializer / `rigor unused` line (2026-10-10, separate from the ADR-119 line above)

Landed: #1662 #1668 #1688(rigor-alba) #1690 #1707(rigor-typelizer) #1709 #1723 #1724 #1725 #1726
#1748 #1756 #1757 #1758 #1762 #1766 #1769. External: okuramasafumi/alba#575 merged 2026-10-10 (ships
`sig/` minus `external.rbs`/`railtie.rbs`; unreleased as of v4.0.0) — #1788 drops rigor-alba's stub
`sig/alba.rbs` + `open_receivers` once a release ships it.

In flight at handoff: **#1767** (fixes #1761, Draft, branch `unused-literal-const-get`). Round 2 found
five shapes that list a live top-level class as a candidate (see the PR comment): `extend` taken as a
const_get ancestor, `self.class` in a singleton method, `class << Other`, compact-class ancestor
resolution, DSL blocks. Next: round-3 fix (read at the top level when the receiver scope is uncertain),
then a round-3 review — the last round; if it is still severe, ask the user. Lesson from #1769: `Set#reject` returns an Array on
Ruby 4.0 — filter scope carriers with `dup.delete_if` so each keeps its class.

Next: #1760 (one realpath'd project root for `rigor unused`; start after #1767 lands), then #1768
(ADR-58 census misses `define_method` writes), #1772 (#1695 leftovers), #1406. Survey runs of `rigor unused` must set a
scratch `cache.path`: earlier runs rewrote pre-existing `.rigor/cache` in redmine/mastodon/gitlab.

## AtCoder / ac-library-rb line (2026-10-10, separate from the lines above)

Landed: #1677 #1680 (bundled `rigor-ac-library-rb`, RBS for the gem's `AcLibraryRb` namespace) #1681
#1701 (vendored `prime` RBS, loaded only on a literal `require "prime"`) #1705 (`pre_eval:` reads
`alias`/`alias_method`) #1706 (top-level `include M` silences `call.unresolved-toplevel` /
`call.undefined-method`; no typing) #1719 (`0 | Integer` judged as Integer) #1755 (constant through an
RBS-only include, instance methods only) #1765 (sig-gen lists top-level defs as `sig.skipped.top-level-def`)
#1770 (vendored `prime` stands down per member, with an `:info` notice).

On hold: **#1715** (type `crt(...)` after a top-level `include AcLibraryRb`). Draft **#1771** stays for
reference only: five review passes each found a false positive, all from reading "no project file
defines the name" as proof; the last one is an empty `paths:` expansion (the typical contest directory).
#1715 records every shape and two non-absence designs. Do not resume #1771 as is.

Open, found on this line: #1676 (default emission of top-level defs, still a decision), #1678
(rigor-minitest `assert_equal` narrows to the literal), #1708 (`pre_eval:` patch on an ancestor),
#1710 (ADR-17 first vs last pre_eval file wins), #1722 (core-receiver `undefined-method` FPs:
`method_missing`, `C.include(M)`, `extend` on a local), #1773 (Object mixin does not shadow Kernel).
Maintainer decision kept: `call.possible-nil-receiver` stays as specified; the plugin README shows
`severity_overrides` for contest code.

What bit: #1706, #1755 and #1771 each needed three review rounds; the new holes sat in each fix, not
in the original change. A subagent waiting on its own idle monitors re-sent its final report a dozen
times; stop it with TaskStop once its PR is pushed. Worktrees from this line under `../rigor-wt/`
(constant-through-rbs-include, sig-gen-toplevel-skip, vendored-partial-standdown) can be removed;
keep `toplevel-include-typing` while #1771 is open.

## Special-variable semantics (ADR-117), carried over unverified

- ADR-117 order: #1426, then #1427, then #1366's stream part (#1484 lands before it; #1366 stays
  `ready-for-human`). #1454 phase 3 waits for those three. #1500 builds on #1499; #1596 is the most
  common report left on that shape.
- Sibling Draft #1397 restructures `eval_ensure`; it must keep #1449's ensure rule for `$_`.
- `ready-for-agent` in `v0.4.x`: #1447, #1437, #1423, #1375, #1372, #1371, #1416, #1373, #1443.

## What bit

- Spec-expectation rewrites in a CI fix are where a gate silently weakens: #1629's fix round rewrote a
  stale-`--incremental` pin. A delta review that mutates the guarded code (not the spec) settled it.
- A lane told to fix two named sites switched ~25 (#1639); the review found the extra runtime sites were
  real crashes but the config-sourced ones broke `~/` in `.rigor.yml` and Bundler's `BUNDLE_PATH`.
  Brief the split (runtime vs config-sourced) up front.
- Many merges touched the same files; merge each landed PR before rebasing the next, and re-run a PR's
  targeted specs after merging master into it (#1644 conflicted in `cli_spec.rb` with #1643).
- Worktrees from this session under `../rigor-wt/` (review-*, fix-*, record-*, spec-lsp-stdin-eof) and
  scratchpad corpus copies (~4 GB) can be removed; nothing in them is unmerged.
