# ADR-19 — Language Server packaging

Status: **accepted, 2026-05-17.** Decides the packaging shape for
Rigor's Language Server implementation so future LSP work
(refactoring features, additional capabilities, ecosystem
integration) starts from a written premise instead of re-litigating
the gem-boundary question every cycle.

## Context

Language Server v1 landed in v0.1.6 (commits `a3e9c47` → `e2d1c9a`,
twelve commits across one design doc + eight slices + cleanup).
The full design lives at
[`docs/design/20260517-language-server.md`](../design/20260517-language-server.md);
this ADR addresses the orthogonal question of **where the LSP code
lives**.

Today's shape: `rigor lsp` is a CLI subcommand of the main
`rigortype` gem, with implementation under `lib/rigor/language_server/`
and a new runtime dependency on `language_server-protocol ~> 3.17`.
The LSP reads internal Rigor APIs directly — `Analysis::Runner`,
`Scope#type_of`, `Environment`, `BufferTable`, `Inference::ScopeIndexer`,
`Source::NodeLocator` — none of which are promised public per
ADR-0's CLI-first scope.

The question — **does the LSP stay bundled, split into a separate
gem, or become an addon to an existing LSP framework?** — needs an
explicit answer before LSP feature additions (refactoring,
codeAction, rename, etc.) accrete and make the boundary harder to
move later.

The Ruby ecosystem has three real precedents:

| Pattern | Examples | Shape |
|---|---|---|
| **A. Single gem, LSP as subcommand** | Steep (`steep langserver`), Solargraph (`solargraph stdio`) | Analyzer + LSP server live in one gem. The tool author owns both layers. |
| **B. Standalone LSP gem depending on the analyzer** | (few precedents in Ruby; closer in TS ecosystem with `typescript-language-server` over `tsc`) | Analyzer gem and LSP gem are separately versioned. LSP gem depends on the analyzer's public API. |
| **C. Addon to a shared LSP shell** | `ruby-lsp-rubocop`, `ruby-lsp-rails`, `ruby-lsp-sorbet` against [`ruby-lsp`](https://github.com/Shopify/ruby-lsp) | A common LSP shell hosts multiple analyzers via an addon protocol. Multiple analyzers can coexist in one editor session. |

Steep and Solargraph — the two Ruby projects most structurally
similar to Rigor (analyzer-first, single tool, type-aware) — both
chose **A**. Ruby LSP chose **C** but is an LSP orchestrator
shell, not an analyzer; it sits one layer above tools like Rigor.

## Decision

**Pattern A — keep the LSP bundled in the `rigortype` gem.**

- `rigor lsp` stays as a subcommand alongside `check` / `type-of` /
  `sig-gen`. No gem split.
- LSP implementation lives under `lib/rigor/language_server/` with
  direct access to Rigor's internal APIs. No public-API stability
  pledge is required at the LSP / analyzer boundary.
- `language_server-protocol ~> 3.17` stays as a runtime dependency
  of `rigortype`. It's a thin gem (~500 lines + auto-generated LSP
  types), and the bundle cost is acceptable for the entire user
  base.

Rejected alternatives are recorded under "Alternatives considered"
along with the trigger conditions that would re-open this decision.

## Rationale

Why A:

1. **Internal API coupling.** The LSP reads `Analysis::Runner` /
   `Scope#type_of` / `Environment` / `BufferTable` /
   `Inference::ScopeIndexer` / `Source::NodeLocator` directly.
   None of these are promised public per ADR-0 — they're treated
   as "may change at any time" internal surfaces the analyzer
   evolves freely. Splitting into a separate gem would either:
   - force those APIs to become public (chilling effect on
     analyzer evolution), or
   - duplicate internal helpers into the LSP gem (rot under
     version drift).
   Neither outcome serves the analyzer's primary mission.

2. **Steep and Solargraph precedent.** The two Ruby projects most
   structurally similar to Rigor both ship LSP as a subcommand of
   the analyzer gem. Their experience suggests the bundled shape
   is the natural fit for analyzer-first tools, and there's no
   evidence the boundary has caused friction for either project.

3. **No demand pressure to split.** Splitting solves problems the
   project doesn't currently have: install bloat (no user
   complaints), independent release cadence (no scheduling
   conflict), multiple LSP backends (no second backend on the
   horizon).

4. **Refactoring features are orthogonal to packaging.** The
   framing question — "should we split so we can build
   refactoring features?" — has a false premise. Refactoring
   capability (`textDocument/codeAction`, `textDocument/rename`,
   `textDocument/formatting`) is implementable inside `rigortype`
   identically to a split-gem implementation. The architectural
   gates are type-aware code rewriting and edit-application
   semantics, both of which sit equally well in either layout.

5. **Reversibility is high.** A future split (A → B or A → C)
   requires moving files between gems and adjusting one gemspec
   dependency line; the LSP code itself doesn't need redesign.
   Premature splitting, by contrast, locks in API surfaces that
   become hard to redact.

## Trigger conditions for re-evaluation

This ADR is accepted **subject to** these conditions. If any
trigger fires, the next implementer SHOULD re-open the
packaging question.

| Trigger | Re-evaluate toward |
|---|---|
| LSP implementation grows past ~2,000 lines (today: ~360 lines) | B (standalone `rigor-lsp`). The split cost is justified when the LSP is itself a substantial subsystem. |
| Concrete user demand for "I use `rigor check` from CI but don't want `language_server-protocol` in my Gemfile.lock" | B with `rigortype` losing the runtime dep; `rigor-lsp` carrying it. |
| Independent release cadence becomes painful (rigor analyzer ships on type-correctness rhythm; LSP ships on UX rhythm; the rhythms conflict) | B with separate versioning. |
| A second LSP backend appears (e.g. an LSP for a different audience using the same analyzer) | B so both backends can compose without cross-gem coupling. |
| Concrete user demand for "I want rigor's analysis composed with RuboCop/Sorbet/Rails LSP in one editor session" | C (`ruby-lsp-rigor` addon, in parallel with A). |
| A new LSP shell project supersedes Ruby LSP and Rigor needs to integrate | C against the new shell. |

The expectation is that **none of these will fire in the v0.1.x
or v0.2.x cycle.** They're recorded so the v0.3.x / v0.4.x
implementer doesn't have to re-derive them.

## Naming convention if split

If trigger conditions fire and the split happens:

- **`rigor-lsp`** — matches the existing Rigor plugin family
  prefix (`rigor-rails-routes`, `rigor-dry-types`,
  `rigor-activerecord`, etc.). Stage under `examples/rigor-lsp/`
  per the [`rigor-plugin-author`](../../.codex/skills/rigor-plugin-author/SKILL.md)
  SKILL discipline if the move is gradual; extract via
  `git subtree split` once stable.
- **`ruby-lsp-rigor`** — if the split is toward C (Ruby LSP
  addon), follow Ruby LSP's `ruby-lsp-<name>` addon naming
  convention. Released independently of `rigor-lsp` (A) if both
  shapes coexist.
- **NOT `lsp-rigor`** — backwards order vs. Rigor's existing
  prefix regime; rejected for consistency reasons.

## Alternatives considered

### B. Standalone `rigor-lsp` gem depending on `rigortype`

**Pros**

- Dedicated product surface: `rigor-lsp` is discoverable by name
  for users searching for "Ruby Language Server."
- `rigortype` runtime stays minimal (no `language_server-protocol`
  dependency for CLI-only users).
- Independent release cadence. LSP UX changes ship without
  bumping the analyzer; analyzer type-correctness changes ship
  without bumping the LSP.
- Theoretically enables a different LSP shell consuming
  `rigortype` (unlikely in practice).

**Cons**

- Forces the analyzer's internal APIs (Runner / Scope /
  Environment / BufferTable / ScopeIndexer / NodeLocator) to
  become public — or forces duplication of internal helpers
  into `rigor-lsp`. Both outcomes are worse than the current
  shape.
- Cross-gem version-compatibility matrix (`rigortype 0.x` ↔
  `rigor-lsp 0.y`). Solvable but adds release coordination.
- Higher cognitive overhead for contributors who touch both
  layers.

**Rejected because** the API-coupling cost dominates every
listed pro. The pros become real only when the LSP grows large
enough or user demand for split installs surfaces — see the
trigger table.

### C. `ruby-lsp-rigor` addon under the Ruby LSP shell

**Pros**

- Coexistence with other Ruby LSP addons (RuboCop, Rails,
  Sorbet) in one editor session.
- Less LSP plumbing to maintain (Ruby LSP owns the framing,
  lifecycle, capability negotiation).
- Matches the v2-Ruby-tooling-ecosystem direction Shopify is
  pushing.

**Cons**

- Significant rearchitecture: the ~250-line `Server` / `Loop`
  layer landed in v0.1.6 would be largely replaced by Ruby LSP
  addon scaffolding.
- Subject to Ruby LSP's addon protocol stability — Shopify can
  change the contract; Rigor follows or stops working.
- Forfeits architectural control over LSP lifecycle (capability
  selection, startup ordering, request prioritisation).
- Confines Rigor to whatever LSP feature set Ruby LSP exposes
  through its addon API.

**Rejected for now**, but worth revisiting if a concrete user
demand for multi-analyzer composition surfaces. The ideal path
in that case is **A + C in parallel** (keep the standalone
subcommand for users who want only Rigor; add the addon for users
who want composition).

### Mega-gem with refactoring tools included

Consideration: bundle codemod tooling, Prism rewriters, etc.
into `rigortype` as part of the LSP slice so the gem becomes the
all-in-one "static analysis + IDE" tool for Ruby.

**Rejected because** the codemod / rewriter layer should be its
own addressable subsystem, not absorbed into the gem's runtime
identity. When refactoring features ship (queued under ROADMAP
§ "Editor / IDE integration"), the rewriter should live under
its own `lib/rigor/refactoring/` namespace inside `rigortype`,
with a clean internal API the LSP layer calls into. That keeps
analyzer / refactoring / LSP as three identifiable subsystems
under one gem boundary — the bundled-but-modular shape Steep
demonstrates.

## Consequences

**Positive**

- LSP development continues against the same internal-API
  surface that already drives `rigor check` and `rigor type-of`.
  No new public-API stability burden.
- Single-gem install model for the foreseeable future. One
  command (`gem install rigortype`) gives users CLI + LSP.
- The Rails / dry-rb plugin family pattern (per-gem under
  `examples/`, extract on stability) stays the canonical
  multi-gem path — the LSP simply doesn't fit it.

**Negative / cost**

- The `language_server-protocol` runtime dep is now permanent
  for every `rigortype` install, including CI-only users.
  Mitigation: the gem is small and has no transitive runtime
  deps beyond `json` (stdlib in Ruby 3+). Acceptable until the
  trigger table fires.
- Future re-evaluation needs to happen explicitly. This ADR is
  the bookmark that prevents the question being forgotten.

**Neutral**

- Refactoring features land inside `rigortype` when they ship,
  not in a new gem. Consumers of `rigor check` who don't use
  the LSP pay the code-size cost but not the runtime cost
  (refactoring code only loads via `rigor lsp` paths).

## Status review cadence

This ADR is reviewed when:

- Any trigger condition above fires (mandatory review).
- A major LSP capability lands (refactoring, semantic tokens,
  inlay hints) — sanity-check that the bundled shape still
  serves.
- Ruby ecosystem shifts (Ruby LSP becomes ubiquitous as a shell
  or fades; a new shell appears).

Until one of these happens, this ADR stays load-bearing as
written.
