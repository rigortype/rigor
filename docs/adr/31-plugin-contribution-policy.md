# ADR-31 — Plugin contribution and supply-chain policy

Status: **proposed, 2026-05-25.** Records the project-wide policy
that Rigor does not accept external pull requests into
`plugins/`. New officially-bundled plugins are authored by the
Rigor team, optionally crediting the proposer via
`Co-authored-by:`. Third-party plugins (separate `rigor-*` gems in
the author's own repo, depending on `gem "rigortype"`) are
explicitly welcomed as a parallel ecosystem. Subtree merge of a
proven third-party plugin into the monorepo is reserved as an
optional, conditional path.

## Context

Rigor is a static analyzer that runs in every user's CI / dev
environment — a high-leverage target for supply-chain attacks
analogous to `xz-utils` (2024), `ua-parser-js`, `event-stream`,
and the recurring npm-ecosystem incidents. A malicious recognizer
inserted via an outside pull request would execute in the rigor
process during every analysis of every downstream user's code,
regardless of whether that user depends on the wrapped gem.

All currently-bundled plugins under `plugins/` and `examples/` —
the Rails family, dry-rb adapters, ADR-16 substrate consumers
(`rigor-sinatra`, `rigor-devise`, `rigor-dry-struct`),
`rigor-hanami` (ADR-28), and the four FFI consumers queued by
[ADR-30](30-rigor-ffi-plugin-shape.md) — were and will be
authored by the Rigor team. No bundled plugin has ever been
merged from an external PR. This ADR codifies that de facto
practice as binding policy and clarifies the welcoming
alternative routes for the community.

The trigger to write this ADR was [ADR-30](30-rigor-ffi-plugin-shape.md)
WD10's initial draft, which proposed "PR accepted for OSS gems
subject to three conditions." On review, the supply-chain argument
was found to be **plugin-shape-agnostic** — there is no reason
FFI plugins are more or less risky than Rails plugins or dry-rb
adapters. The policy therefore lifts out of ADR-30 and becomes
project-wide.

## Decision

Adopt a single project-wide plugin contribution policy with five
working decisions covering: (a) the no-external-PR rule, (b) the
proposal-and-credit route into bundled plugins, (c) the
intentionally vague "widely used" criterion, (d) the welcomed
third-party ecosystem, (e) the reserved subtree-merge option.

## Working decisions

### WD1 — No external pull requests into `plugins/` or `examples/`

The supply-chain rationale governs **uniformly**:

- Bundled plugins ship inside the `rigortype` gem, which runs in
  every analysed user's CI / dev environment.
- A malicious recognizer can execute arbitrary Ruby in the rigor
  process during analysis — including reading the analysed project's
  source, exfiltrating environment variables, writing files, or
  making network calls if the host permits.
- The blast radius extends to **every rigor user**, not just users
  of the wrapped gem.
- This risk is **independent of what the plugin wraps** — a
  Rails-adapter PR has the same attack surface as an FFI-binding PR.

Scope:

- Applies uniformly to **code, RBS files, fixtures, and config**.
  Drawing a "pure RBS contributions are safe" carve-out adds
  judgement cost without changing the policy meaningfully:
  RBS still flows attributes / annotations to the engine, and
  maintainer time spent classifying "is this just data?" exceeds
  the savings from accepting low-risk drops.
- Applies to **new plugins**. Maintenance of existing bundled
  plugins (bug fixes, refactors, dependency bumps) is by Rigor
  team only — no external PR path here either.

This codifies existing practice. No current bundled plugin came
from an external PR, so the policy introduces no retroactive
inconsistency.

**Rejected alternative.** "PR accepted with strict code review":
the audit cost per PR is high, the cost of one missed malicious
contribution is catastrophic, and the asymmetry doesn't pay back.
The Linux kernel / curl / OpenSSL projects all use variants of
"maintainer-authors" precisely because the
threat-model-vs-velocity trade-off lands the same way for
high-trust upstream packages.

### WD2 — Promotion path via issue + `Co-authored-by:` attribution

Anyone wanting an officially-bundled plugin for a real OSS gem
files an **issue** with:

- The wrapped gem's identity and homepage.
- Evidence of community adoption (see WD3 for the criterion).
- Optional: a working sample implementation (in the proposer's
  own repo or as a gist).
- Optional: confirmation that the wrapped gem's upstream
  maintainers are not authoring a parallel rigor plugin.

Rigor team evaluates against WD3, accepts or declines (with
reasons if declined). If accepted, the team **re-implements**
the plugin in `plugins/` from scratch. When a sample
implementation or substantive analysis was provided by the
proposer, the implementation commit(s) credit them via the
GitHub
[`Co-authored-by:` trailer](https://docs.github.com/en/pull-requests/committing-changes-to-your-project/creating-and-editing-commits/creating-a-commit-with-multiple-authors)
— one trailer per contributor:

```
Add rigor-foo plugin

…subject and body…

Co-authored-by: Jane Doe <jane@example.com>
```

This preserves attribution (GitHub renders co-authors on the
commit and counts the contribution toward the proposer's profile)
without granting write access through the PR-merge code path.

**Rejected alternative.** "Pre-review PR then squash-merge under
maintainer's signature": still ingests external commits into
git history, weakens the supply-chain guarantee that the
maintainer authored every line. `Co-authored-by:` on a re-authored
commit is the right shape — explicit signal that the maintainer
wrote the code, the proposer informed it.

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

### WD4 — Third-party plugins are explicitly welcomed

Authoring a `rigor-<gem>` gem in **your own repo**, depending on
`gem "rigortype"`, is a fully supported path for any plugin the
Rigor team doesn't (yet) bundle. This includes:

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
- **License:** free choice — MPL-2.0 (matching Rigor), MIT, BSD,
  Apache 2.0, or others. The only constraint is what your wrapped
  gem's license permits.
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
strongest form of contributor recognition.

All four conditions must hold:

1. **Significant adoption** — per WD3's vague criterion.
2. **Maintenance transfer** — the original author agrees that
   ongoing maintenance shifts to Rigor team after the merge
   (they can still contribute via WD2 like anyone else).
3. **Style and contract conformance** — the plugin follows the
   bundled-plugins shape (`Plugin::Base`, `signature_paths:`,
   spec layout, demo fixture, CHANGELOG discipline).
4. **License compatibility** — the plugin is MPL-2.0 or the
   author agrees to relicense to MPL-2.0 (the project license).

Subtree merge is **not a path third-party authors should plan
around**. The default expectation is "your plugin stays in your
repo, indefinitely." Subtree merge is a sometimes-appropriate
form of WD2's promotion when re-implementation would be
strictly redundant with a well-shaped existing implementation.

**Rejected alternative.** "Subtree merge as the default
promotion mechanism": the WD1 supply-chain guarantee would be
diluted (third-party commits enter monorepo history). WD2's
re-implementation default is the right baseline; subtree merge
is the exception.

## Consequences

- **Contribution velocity is slower than typical OSS norms.** A
  user with a working plugin must file an issue and wait for
  maintainer-authored implementation, rather than opening a PR.
  Counter-balance: explicit attribution (Co-authored-by) +
  welcomed third-party ecosystem (WD4) means contribution is
  acknowledged, just not directly merged.
- **Maintainer workload is bounded by WD3's "widely used"
  filter.** Re-implementation cost per accepted plugin is real
  but capped — and the proposer's sample implementation, when
  provided, dramatically reduces it (the sample documents the
  recognizer's intended behaviour, the maintainer re-authors the
  code).
- **Newcomer-friendliness.** The policy is welcoming when read in
  full: "build it privately today, use it forever, propose for
  bundling when you have evidence of community uptake, get credit
  when accepted." It's only unwelcoming if read as just "no PRs".
  Documentation should foreground WD4 + WD2's attribution promise.
- **The bundled plugin set grows slowly and deliberately.** This
  is intended — every bundled plugin is maintenance burden for
  the Rigor team and trust surface for every downstream user. A
  small, high-quality bundled set + a vibrant third-party
  ecosystem is the target.
- **Consistency across rigor-* plugin types.** Whether someone
  proposes `rigor-foo-graphql-extension` or `rigor-myffigem`, the
  same policy applies. No special-casing by plugin domain.

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
