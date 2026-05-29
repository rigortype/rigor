# ADR-31 — Contribution and supply-chain policy

Status: **accepted, 2026-05-25; in force.** The policy is reflected
in [`CONTRIBUTING.md`](../../CONTRIBUTING.md), `AGENTS.md`, and the
`rigor-plugin-author` / `rigor-ffi-plugin-author` SKILLs (Phase 0.5
routing). Records the project-wide contribution policy, organised by
**change magnitude**:

- **Minor focused changes anywhere in the repo** — code,
  documentation, tests, fixtures, tooling — are welcomed as
  direct pull requests under ordinary review.
- **Sweeping changes** — re-architectures, code-style sweeps,
  large refactors, new analyser features, new bundled plugins —
  go through an **issue-first** proposal route. If accepted, the
  Rigor team implements; the proposer is credited via
  `Co-authored-by:` on the implementation commit(s).
- **Third-party plugins** as separate `rigor-*` gems in the
  author's own repo are explicitly welcomed (WD4); subtree merge
  of a proven third-party plugin into the monorepo is reserved
  as an optional path (WD5).

Plugins remain the most active worked subdomain — WD2 through
WD5 record the plugin-specific instances of the general
issue-first / third-party / subtree-merge mechanisms.

## Context

Rigor is a static analyzer that runs in every user's CI / dev
environment — a high-leverage target for supply-chain attacks
analogous to `xz-utils` (2024), `ua-parser-js`, `event-stream`,
and the recurring npm-ecosystem incidents. A malicious commit
inserted via an outside pull request — anywhere along the
analysis path, whether engine internals or a bundled plugin's
recognizer — would execute in the rigor process during every
analysis of every downstream user's code.

The supply-chain argument is real but **calibrated by what code
review can reliably catch**. A small, focused PR is auditable at
merge time — diff is small, the change is scoped, malicious
patterns are visible to a careful reviewer. A sweeping PR
(thousand-line refactor, project-wide code-style sweep,
architectural rewrite) is not — the cognitive load of reading
the diff exceeds what merge-time review can deliver, and a
subtle malicious or behaviour-changing line can slip through.
The policy below maps this asymmetry onto the contribution
shape: small PRs land via ordinary review, sweeping changes go
through issue-first proposal so the team can engage with the
intent and own the implementation.

Plugins are a distinct category. A new bundled plugin defines
ecosystem identity (`plugins/rigor-foo/` carries an implicit
"this is the official rigor plugin for foo" signal), which is
a project-governance concern beyond per-PR review. The plugin-
specific paths (WD2's promotion-by-issue, WD3's vagueness, WD4's
third-party route, WD5's subtree merge) handle that boundary
regardless of any one plugin proposal's diff size.

The trigger to write this ADR was [ADR-30](30-rigor-ffi-plugin-shape.md)
WD10's initial draft, which proposed "PR accepted for OSS gems
subject to three conditions." Iterative review (recorded in the
git history of this ADR) led through "no plugin PRs" → "no
shipped-code PRs" → the current change-magnitude formulation.
The earlier "no PRs to shipped code" framing was too coarse: it
disincentivised the minor-PR contribution flow OSS projects
depend on. The change-magnitude axis captures the actual
risk / value trade-off.

### What ships in `rigortype`

For reference (the policy below applies to all paths, not just
shipped ones — but knowing what is shipped helps reason about
the relative supply-chain weight of changes in different areas):

| Path | Ships in `rigortype`? | Executes during analysis? |
| --- | --- | --- |
| `lib/rigor/` (engine) | yes | yes |
| `plugins/` (bundled plugins) | yes | yes |
| `examples/` (walkthrough plugins) | yes | yes |
| `ext/` (native extensions, if any) | yes | yes |
| `exe/` (CLI entry points) | yes | yes |
| `sig/` (RBS for `lib/`) | yes | yes (analyser-load) |
| Gemspec + executable scripts | yes | yes |
| `spec/` (test suite) | no — dev-only | no |
| `docs/` (this corpus) | no | no |
| `references/` (vendored read-only sources) | no | no |
| `CONTRIBUTING.md` / `AGENTS.md` / `CLAUDE.md` / `README.md` | no | no |
| `.claude/` / `.github/` (tooling) | no | no |

A change to shipped code carries higher supply-chain weight per
diff line than a change to docs / tests, but **both can be either
minor or sweeping** — the policy axis is magnitude, not path. A
small bug fix in `lib/rigor/inference/` is welcome as a direct
PR; a large rewrite of `docs/handbook/` is issue-first.

### Licensing framework

Rigor is licensed under the [Mozilla Public License Version 2.0](../../LICENSE)
(MPL-2.0). The MPL's vocabulary ([§1](../../LICENSE), Definitions)
shapes how this ADR talks about authorship, code provenance, and
the boundary between the bundled `rigortype` gem and third-party
extensions:

- **Covered Software** (§1.4) is the `rigortype` gem — every
  path enumerated as "in scope" in the table above
  (`lib/rigor/`, `plugins/`, `examples/`, `ext/`, `exe/`,
  `sig/`, gemspec) plus any **Modifications** (§1.10) thereto.
- **Contributor** (§1.1) is anyone who creates, contributes to,
  or owns Covered Software. Each Contributor grants the rights
  in §2.1 and makes the §2.5 representation (their Contributions
  are their original creation, or they have sufficient rights to
  grant the conveyed license).
- **Contribution** (§1.3) is the Covered Software of a particular
  Contributor.
- **Larger Work** (§1.7) is a work that combines Covered Software
  with other material **in a separate file or files** — the
  shape a third-party `rigor-<gem>` gem (in the author's own
  repo, depending on `gem "rigortype"`) takes. §3.3 permits
  distributing a Larger Work under terms of the author's choice
  for the non-Covered-Software portion.

The policy below reads naturally against these terms: WD1 limits
who may make a Contribution (to all of Covered Software, not
just plugins), WD2 distinguishes informational authorship credit
from Contributor status, WD4 frames third-party plugins as
Larger Work under §3.3, and WD5 notes that subtree merge brings
imported files **into** Covered Software as Modifications under
§1.10.

## Decision

Adopt a project-wide contribution policy organised by **change
magnitude**, with five working decisions: (a) the magnitude axis
itself — minor PRs direct, sweeping changes issue-first;
(b) the issue-first proposal route with `Co-authored-by:`
attribution; (c) the intentionally vague "widely used" criterion
that gates plugin promotion; (d) the welcomed third-party plugin
ecosystem; (e) the reserved subtree-merge option for third-party
plugins.

## Working decisions

### WD1 — PR receptivity by change magnitude

The policy axis is **how big and how scoped the change is**, not
which path it lands in.

#### Direct pull requests — welcomed

Pull requests for **minor, focused changes** are welcomed against
any path in the repo, including shipped code. Examples:

- Bug fixes with clear scope (one or a few files, one root cause).
- Documentation improvements: typo fixes, clarifications, broken-
  link fixes, small section rewrites.
- Test additions / fixture corrections.
- Tooling improvements (`.github/`, `.claude/`, `Makefile` tweaks).
- Small refactors that don't change architectural decisions
  recorded in ADRs.
- Maintenance: dependency bumps consistent with project policy
  (`AGENTS.md`), CI updates.

The heuristic — intentionally informal, like WD3's "widely used"
criterion — is "could a careful reviewer audit this diff in one
sitting and be confident nothing harmful is hiding in it." If
yes: send the PR, run `make verify` first, follow
[`CONTRIBUTING.md`](../../CONTRIBUTING.md). The merge-time review
is real: the team will read the diff carefully, run the test
suite, and ask questions before merging.

Bug fixes to existing bundled plugins (`plugins/rigor-*`) are
covered by this path — they're minor, scoped, and clearly
valuable.

#### Issue-first — for sweeping changes

The following kinds of changes go through an issue-first
proposal route rather than a direct PR:

- **Architectural rewrites or non-trivial refactors** of engine
  code (anything that changes how `Inference::` or `Analysis::`
  modules wire together, anything that touches a contract
  recorded in `docs/internal-spec/`).
- **New analyser features**, new diagnostic families, new
  inference passes.
- **Code-style sweeps / formatting reflows** across many files.
  These are often controversial (style preferences are personal)
  and the diff-noise cost is high relative to any individual
  improvement; alignment matters more than the implementation
  itself.
- **New bundled plugins** (`plugins/rigor-<gem>/`) — see WD2
  through WD5 for the plugin-specific paths.
- **Changes to spec / ADR corpus** that retract or modify an
  existing normative decision (additions / clarifications can be
  minor PRs).

For these: file an issue with the proposal and the rational
reasons. If the team agrees with the direction, the team
implements; the proposer is credited via `Co-authored-by:` on
the implementation commit(s) per WD2. The team may also accept a
sample implementation as reference material, but won't merge it
directly — see WD2's note on why re-authoring matters for both
license cleanliness and supply-chain hygiene.

#### Why the asymmetry — calibrated supply-chain weight

Merge-time code review can reliably catch malicious or
behaviour-changing patterns in a small focused diff (the entire
change fits in a reviewer's working memory). It can't reliably
catch them in a thousand-line refactor (cognitive load exceeds
review capacity; subtle behaviour drift hides in legitimate-
looking code motion). The change-magnitude axis maps onto the
review capacity asymmetry directly: where review is reliable,
direct PR is fine; where review is unreliable, the team takes
ownership of the implementation so the supply-chain guarantee
stays as strong as for any other team-authored line.

This is the same asymmetry every mature OSS project navigates;
this WD makes the rigor-specific cut explicit rather than
leaving it to maintainer discretion case-by-case.

#### Scope notes

- The boundary between "minor" and "sweeping" is **a judgement
  call**, deliberately. If unsure, file an issue first describing
  what you want to do — the team will tell you whether a PR is
  fine or whether to discuss the design before implementation.
  No PR is rejected for "being too small to bother with an
  issue"; PRs that turn out to be sweeping mid-review may be
  asked to be re-shaped as an issue.
- **All PRs are licensed under MPL-2.0 on merge** per the
  existing CONTRIBUTING.md note. The contributor becomes an
  MPL §1.1 Contributor on the files they touch and makes the
  §2.5 representation by submitting the PR. This is the same
  licensing posture as any other OSS contribution.

#### Rejected alternatives

- **Path-based scope (the previous version of this WD).** "No
  PRs to `lib/`, `plugins/`, `examples/`, `ext/`, `exe/`, `sig/`,
  gemspec." Too coarse: it blocked the minor-PR flow that OSS
  projects depend on for healthy maintenance. The change-magnitude
  axis captures the actual review-capacity / risk trade-off.
- **No external PRs anywhere.** Maximum supply-chain conservatism
  but at the cost of community participation. The merge-time
  review is sufficient for scoped changes; "no PRs" is a tax on
  every legitimate small contributor for a marginal incremental
  guarantee.
- **All PRs accepted with strict code review.** Sweeping diffs
  cannot be reliably audited at merge time; the asymmetry
  between minor and sweeping is real, and pretending it isn't
  invites the supply-chain risk the issue-first path defuses.

### WD2 — Issue-first proposal mechanics + `Co-authored-by:` attribution

WD1 splits the contribution shape into direct-PR (minor) and
issue-first (sweeping). WD2 records the mechanics of the
issue-first path. The same mechanics apply to **any** sweeping
proposal — engine refactors, new analyser features, new bundled
plugins — the only plugin-specific bit is the WD3 adoption-
evidence requirement (which is structurally inapplicable to
engine proposals).

**General shape (any sweeping change).** File a GitHub issue
that describes the proposal:

- What you want to change and why (the "rational reasons"
  alignment, per WD1's issue-first scoping).
- For engine / refactor proposals: which ADR / spec is affected,
  the design alternatives considered.
- Optional: a working sample implementation (in your own fork or
  a gist) the team can read as reference material.

The Rigor team responds with accept / decline / "let's iterate
on the design first". If accepted, the team **implements** the
change in this repository. When a sample implementation or
substantive analysis was provided, the implementation commit(s)
credit the proposer via the GitHub
[`Co-authored-by:` trailer](https://docs.github.com/en/pull-requests/committing-changes-to-your-project/creating-and-editing-commits/creating-a-commit-with-multiple-authors)
— one trailer per contributor:

```
Add foo subsystem

…subject and body…

Co-authored-by: Jane Doe <jane@example.com>
```

**Plugin-specific issue fields.** Anyone wanting an officially-
bundled plugin for a real OSS gem files an **issue** with:

- The wrapped gem's identity and homepage.
- Evidence of community adoption (see WD3 for the criterion).
- Optional: a working sample implementation (in the proposer's
  own repo or as a gist).
- Optional: confirmation that the wrapped gem's upstream
  maintainers are not authoring a parallel rigor plugin.

For plugin proposals, the Rigor team evaluates against WD3
(adoption evidence), accepts or declines (with reasons if
declined). If accepted, the team **re-implements** the plugin
in `plugins/` from scratch and credits the proposer via
`Co-authored-by:` per the general mechanic above.

**`Co-authored-by:` is informational attribution**, not a
transfer of MPL Contributor status. The MPL Contribution (in the
§1.3 sense) is made by the Rigor team member who authors the
implementation; that team member also makes the §2.5
representation that the code is their original creation. The
proposer's sample implementation is referenced material the team
draws inspiration from rather than text the team imports; if a
proposer ships a sample, by submitting it they implicitly
represent it is their original creation or that they have
sufficient rights to share it — equivalent to the §2.5
representation but extended courtesy. The team should rewrite
the sample's code structure rather than transcribe it verbatim,
both for license cleanliness and because re-authoring is the
whole point of the issue-first path (per WD1).

**Rejected alternative.** "Pre-review PR then squash-merge under
maintainer's signature" for sweeping changes: still ingests
external commits into git history, weakens the supply-chain
guarantee that the maintainer authored every line of the
sweeping diff. `Co-authored-by:` on a re-authored commit is the
right shape — explicit signal that the maintainer wrote the
code, the proposer informed it.

### WD3 — "Widely used" criterion stays intentionally vague

The criterion for "accept this promotion request" is **community
recognition**, not a numeric threshold.

- **Not** `downloads/day >= N` or `GitHub stars >= K`. Both
  metrics are gameable (download manipulation is a known
  ecosystem attack pattern; star farms exist) and would let
  attackers manufacture eligibility.
- **Yes** maintainer judgement based on signals like: the gem
  appears in the [real-world Rails / Ruby survey](../notes/20260515-real-world-rails-survey.md)
  corpus; multiple unrelated requesters; named as a dependency
  by a project rigor already analyses; cited in widely-read
  Ruby ecosystem write-ups.

The trade-off — subjectivity for unfakeability — is acceptable.
A decline can always be revisited if the gem's footprint grows.

**Rejected alternative.** Hard numeric thresholds: simplifies the
decision but invites gaming, which is precisely the kind of
adversarial pressure a supply-chain policy must resist.

### WD4 — Third-party plugins are explicitly welcomed (Larger Work under MPL §3.3)

Authoring a `rigor-<gem>` gem in **your own repo**, depending on
`gem "rigortype"`, is a fully supported path for any plugin the
Rigor team doesn't (yet) bundle. A third-party plugin gem is a
**Larger Work** in the MPL §1.7 sense — it combines Covered
Software (rigor's code, loaded via `require "rigor"`) with the
plugin author's own files (the plugin's `lib/`, `sig/`, gemspec,
tests). Under MPL §3.3, the plugin author distributes their
Larger Work under license terms of their choice for the
non-Covered-Software portion, as long as they comply with the
MPL for the Covered Software they redistribute. Concretely: the
plugin author's own files can be MIT, BSD, Apache 2.0, MPL, or
any other license they prefer; rigor's code stays under MPL when
their downstream users install both.

This includes:

- Private / internal company gem wrappers (no upstream
  intention).
- Public OSS gems that haven't (yet) been promoted via WD2.
- Speculative / experimental plugins exploring new analyser
  shapes.

The `rigor-*` naming convention is **community-shared**. Using
the prefix does not imply official endorsement; users should
check whether a `rigor-foo` they're installing is bundled (under
`plugins/` in this repo) or third-party (any other repo).

Operational notes for third-party plugin authors:

- **wrapped gem version pinning.** Pin the wrapped gem's version
  range in your plugin's gemspec. When the wrapped gem releases a
  new version that changes its FFI / RBS surface, update your
  plugin in your own repo. Orphan-plugin risk (the wrapped gem
  evolves, the plugin doesn't) is **the plugin author's
  responsibility**, not Rigor's.
- **License:** free choice per §3.3 — MPL-2.0 (matching Rigor),
  MIT, BSD, Apache 2.0, or any other licence permitted by your
  wrapped gem's licence. If you ever expect the plugin to be a
  candidate for WD5 subtree merge into the monorepo, licensing
  the plugin as MPL-2.0 from day one keeps that option open
  without a later relicensing pass.
- **Discovery:** the Rigor team will (separately, not in this ADR)
  set up an informational catalog (Wiki page or pinned forum
  thread) where third-party plugin authors can list their work.
  Listing is not endorsement.

A planned `rigor-plugin-author` external-user-facing SKILL variant
(queued for v0.2.0 per existing CLAUDE.md) covers this path
end-to-end.

### WD5 — Subtree merge of a third-party plugin is reserved as an option

In rare cases where a third-party plugin achieves significant
community adoption AND its author is willing to transfer
maintenance to Rigor team AND the code style matches Rigor's
conventions, `git subtree merge` is available as an option to
absorb the plugin into the monorepo. Subtree merge preserves
git history including the original author's commits — the
strongest form of contributor recognition under the §1.1
Contributor definition (every imported commit's author becomes
a Contributor to Covered Software, with their §2.5 representation
attached at import time).

All four conditions must hold:

1. **Significant adoption** — per WD3's vague criterion.
2. **Maintenance transfer** — the original author agrees that
   ongoing maintenance shifts to Rigor team after the merge
   (they can still contribute via WD2 like anyone else).
3. **Style and contract conformance** — the plugin follows the
   bundled-plugins shape (`Plugin::Base`, `signature_paths:`,
   spec layout, demo fixture, CHANGELOG discipline).
4. **License compatibility** — the plugin is MPL-2.0 or the
   author agrees to relicense it MPL-2.0 before the merge. This
   condition is load-bearing: once subtree-merged, the imported
   files **become Modifications** to Covered Software (§1.10) and
   so must ship under the MPL alongside the rest of `rigortype`.
   Plugins under MIT / BSD / Apache 2.0 / ISC are relicensable
   in the standard direction (the original author re-publishes
   their files under MPL-2.0 prior to the merge); plugins under
   GPL-family Secondary Licenses (§1.12) are eligible because
   the MPL is explicitly compatible with them at the file-
   combination level, but the author must consent to the change.

Subtree merge is **not a path third-party authors should plan
around**. The default expectation is "your plugin stays in your
repo, indefinitely." Subtree merge is a sometimes-appropriate
form of WD2's promotion when re-implementation would be
strictly redundant with a well-shaped existing implementation.

**Rejected alternative.** "Subtree merge as the default
promotion mechanism": the WD1 supply-chain guarantee would be
diluted (third-party commits enter monorepo history and the
Contributor set grows unbounded). WD2's re-implementation default
is the right baseline; subtree merge is the exception.

## Consequences

- **Minor PRs land at typical OSS velocity.** A bug-fix PR or a
  documentation improvement against any path in the repo follows
  ordinary review — clone, fix, `make verify`, open PR, merge
  when ready. This is the most common contribution shape and the
  policy explicitly invites it.
- **Sweeping changes are slower than they would be under
  "PRs always welcome" norms** because they take an issue-first
  detour. Counter-balance: explicit attribution
  (`Co-authored-by:`) + the work-investment-protection of having
  the team confirm direction before the proposer writes the full
  implementation. Many proposers prefer issue-first anyway — it
  avoids investing in code only to find the team would have gone
  a different direction.
- **The minor / sweeping boundary is a judgement call.** WD1
  scopes this explicitly — when in doubt, file an issue first
  and the team will route. Some PRs may be asked to be re-shaped
  as issues mid-review when the diff turns out larger than
  initially expected.
- **Plugin promotion workload is bounded by WD3's "widely used"
  filter.** Re-implementation cost per accepted plugin is real
  but capped — and the proposer's third-party plugin (when
  provided) dramatically reduces it (it documents the
  recognizer's intended behaviour, the maintainer re-authors the
  code).
- **Shipped code grows slowly and deliberately.** This is
  intended — every line shipped in `rigortype` is maintenance
  burden for the team and trust surface for every downstream
  user. A small, high-quality shipped set + a vibrant third-
  party plugin ecosystem + an active minor-PR contributor base
  is the target.
- **Newcomer-friendliness.** The policy is welcoming when read
  in full: "minor PRs land the normal way against any path;
  sweeping changes go through issue-first with `Co-authored-by:`
  attribution; for new bundled plugins specifically, build a
  third-party gem first and propose for bundling once adopted."
  It is only unwelcoming if read as "no PRs to shipped code",
  which the prior version of this ADR (now superseded) implied.
  Documentation should foreground the welcome on minor PRs +
  the attribution promise on sweeping proposals + the third-
  party-plugin welcome.

## Implementation slicing

No slice is scheduled by this ADR. The policy takes effect on
acceptance; the documentation rollout is mechanical:

| Slice | Scope |
| --- | --- |
| 1 | ADR-31 lands. [ADR-30 WD10](30-rigor-ffi-plugin-shape.md) simplifies to a reference to ADR-31 + FFI-specific bits only (wrapped-gem version pinning per WD4 above). |
| 2 | [`rigor-plugin-author`](../../.claude/skills/rigor-plugin-author/SKILL.md) SKILL updated: new Phase 0.5 "Where this plugin will live" routing new authors to WD2 / WD4; in-monorepo path retained only for maintenance of already-bundled plugins. |
| 3 | [`rigor-ffi-plugin-author`](../../.claude/skills/rigor-ffi-plugin-author/SKILL.md) SKILL updated: Phase 2 and Phase 6 reference ADR-31; Phase 3/4 add wrapped-gem version-pinning note. |
| 4 | [CLAUDE.md](../../CLAUDE.md) ADR table adds ADR-31 row; ADR-30 row simplified; SKILL rows updated; the existing "v0.2.0-queued external-SKILL" note reconciled with the new policy. |
| 5 | [`docs/ROADMAP.md`](../ROADMAP.md): Plugins / ecosystem section adds an ADR-31 governance reference at the top; FFI entry simplified. |
| 6 | (Deferred, no slice scheduled.) GitHub issue template for plugin proposals capturing the WD2 fields (wrapped gem identity, adoption evidence, sample-implementation pointer, upstream-effort confirmation). |
| 7 | (Deferred, no slice scheduled.) Informational catalog (Wiki or pinned discussion) where third-party plugin authors list their work. |

## Open questions

- **Internal-DSL plugins.** A plugin for an organisation's
  internal DSL has no wrapped-OSS-gem and no public footprint —
  WD3's "widely used" criterion is structurally inapplicable, so
  WD2 promotion is closed to it. The honest answer is "this stays
  third-party forever," which is fine but should be explicitly
  documented in the SKILL so authors don't wait for a promotion
  that won't come.
- **Co-authored-by attribution for partial / informal
  contributions.** If a proposer's contribution is "I filed the
  issue and answered three clarifying questions" (no code), does
  the attribution still apply? Lean yes — the threshold is
  "substantive informing" not "code provided" — but worth
  clarifying in the SKILL.
- **Multiple proposers for the same plugin.** If five people
  request `rigor-foo` independently over time, all five get
  `Co-authored-by:` on the implementation commit, or just the
  first / most-substantive? Lean "all who substantively informed
  the work", capped at reasonable commit-trailer length
  (~10 entries).
- **Discovery catalog hosting.** Wiki, pinned forum thread,
  `docs/third-party-plugins.md` in this repo? Each has different
  curation / spam-resistance properties. Decision deferred until
  the catalog is actually needed (i.e. when a non-trivial
  third-party plugin population exists).
