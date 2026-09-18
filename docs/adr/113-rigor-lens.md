# ADR-113 — `rigor lens`: a declaration map with type provenance, for agents and tools

Status: **Accepted, 2026-09-19. Nothing implemented yet.** Adds a `rigor lens` command. It is the
"Rigor lens" that ZARD's `CONTEXT.md` and ADR-0003 already name. This ADR reverses #512's ruling for
`rigor type-of`: that command stops printing "unseeded" and adopts WD2's computation. Implementation
is tracked by #1080–#1085.

Grounding: an adversarial review on 2026-09-19 found five premises of the first draft that do not
hold on current code. WD2, WD3, WD4, WD5 and WD6 are the corrected shapes. For the anchor format:
lisplens ADR-0008 (xxh3-64, 4 hex), ADR-0013 (one model, terse text first) and ADR-0017 (file-level
drift gating), in the sibling repository `rigortype/lisplens`.

## Context

An agent learning a Ruby codebase today has two options. It can grep and read whole files, which
costs tokens and misses everything grep cannot see: plugin-synthesized members, the type a method
actually has, which reopening redefined a library method. Or it can ask Rigor one position at a
time (`type-of FILE:LINE:COL`) or one slice at a time (`annotate`, `sig-gen --print`). No command
takes a symbol. No command gives a per-file map of declarations. The per-position commands answer
without cross-file discovery (`type_of_command.rb:91`, #512), so a sibling-file class reads
`Dynamic[top]`. Nothing reports where a type came from.

ZARD needs the same thing in structured form: a documentation tool that overlays API prose on
Rigor's facts (ZARD ADR-0003).

## Decision

> **A lens is `rigor check` for one target, rendered as a map rather than as diagnostics.** Every
> type it prints is the type `check` uses for that file, spelled as `sig-gen` would write it, with its
> type provenance and an anchor. It omits the source text. It never answers from less than `check`
> knows. A lens answer that disagrees with `check` is a bug, not a trade-off.

## Working decisions

### WD1 — One model, two renderings; the command surface

- **One model, two renderings.** The model is rendered as compact text for agents and as structured
  JSON for tools (lisplens ADR-0013's shape). The JSON ships as **`lens/v0`**, unfrozen, until ZARD
  reads it. It then becomes `lens/v1` on ADR-50 WD1's freeze list. The contract never covers type
  strings or which diagnostics fire (ADR-50 § Decision 3). The text layout is not frozen; the anchor
  token syntax inside it is (WD6).
- **Command surface.** `rigor lens` is a new command. `type-of`, `annotate` and `sig-gen --print`
  stay. MCP gains `rigor_lens`, which returns JSON.
- **Skill routing.** Among the user-facing skills, a "what is in this file" question routes to
  `rigor-ask` (ADR-108 WD1's question-shaped boundary). `rigor-type-oracle` points at lens when an
  agent checks a symbol's contract before writing a type.

### WD2 — Computation: a one-file `check`, and `type-of` follows

- **A lens runs the incremental check path for its target file(s).** The environment is built from the
  whole project's `source_files:` (runner.rb's #795 rule), so a `#:` in another file binds as it does
  under `check`. The ADR-46 snapshot is persisted, so the next lens or `check` is warm.
- **Why not a discovery-only pre-pass.** It synthesizes inline RBS only for the probed file and skips
  the Tier C / pre-eval / inflection passes (`runner/project_pre_passes.rb`), so it cannot reproduce
  `check`.
- **`type-of` adopts the same computation.** #512's "unseeded" note is withdrawn: two oracles that
  disagree on the same file damage both.
- **Cold cost.** The first-run cost on redmine is measured and recorded as an acceptance number.

### WD3 — Queries and what they return

- **Query forms.** A file, or a symbol (`Foo`, `Foo#bar`, `Foo.baz`).
- **Name resolution.** An exact qualified match wins. Otherwise the command lists the candidates and
  exits 2; it never guesses between `Order` and `Shop::Order`.
- **Symbol answers.** `Foo` merges every reopening across files, each member tagged with its file, and
  lists own members only. `--inherited` adds ancestors, grouped per ancestor. `Foo#bar` returns every
  overload.
- **Multi-site discovery.** Merging needs a discovery table that keeps **every** definition site.
  Today `fold_def_tables` folds `def_nodes` later-wins and `def_sources` first-wins
  (`scope_indexer.rb` ~:4193), so two reopenings of `Foo#bar` collapse into one row. A `def_sites`
  table is added; it bumps the incremental-snapshot schema, which costs one cold run.
- **A class defined in a library** (`String`). The lens lists only the project's reopenings. Library
  members are summarised as per-source counts, and `--library` lists them one per line.
  - Project `include` / `prepend` into such a class is marked in the ancestry line. The mark is a
    discovery fact only: it is not joined into dispatch (#900).
- **Reopenings are extensions or redefinitions, never merged into one kind.** A member that replaces
  an existing one is marked `redefines <origin>`. Its type column shows the effective type under
  [ADR-110](110-inherited-declaration-precedence.md).
- **`refine` members** form their own group, under their defining module, and are never merged into
  the class. Rigor does not analyse `refine` bodies today, so their types read as `Dynamic` with an
  origin.

### WD4 — What a row carries

- **Type spelling.** Types are written exactly as `sig-gen` writes `.rbs`: the erasure in the type
  position, plus `%a{rigor:v1:…}` where a refinement applies
  (`%a{rigor:v1:return: non-empty-string} def number: () -> String`). A row is always valid RBS, so an
  agent copying it cannot write a refinement into a type position (ADR-108's hazard, ADR-112 WD2).
- **Type provenance** is one of:
  - `sig` (with the `.rbs` path)
  - `inline`
  - `extrbs`
  - `inferred`
  - `plugin:<name>`
  - `library`

  It is taken from the declaring buffer: inline contributions carry virtual buffer names. A `Dynamic`
  slot shows its dynamic origin instead, which is available because WD2 types the target's bodies.
  Hand-written and generated `.rbs` are not distinguished; the environment cannot tell them apart.
- **One effective type per slot.** Per-source types are expanded only when the sources differ. That
  needs [ADR-112](112-extrbs-comment-channel.md) WD5 (#1075): until then ADR-32 WD13 strips the
  colliding inline member before the environment exists, and the lens shows the effective type
  alone.
- **Also on the row:** visibility, arity, line range, and diagnostic ids with their lines.
- **Plugin-synthesized members.** A plugin member (an ActiveRecord column reader, say) is listed by
  name and kind through a new `Plugin::Base#declared_members(class_name)` hook. The hook is additive
  before v1.0, as ADR-32 WD8 was. Plugins answer `dynamic_return` per call today, and nothing
  enumerates members per class.
  - A type is printed only where the plugin answers one: the ActiveRecord column readers answer
    `Dynamic[top]` on purpose (#963, 57 false positives otherwise).
  - Members of one kind collapse to one line of names.
- **Truncation.** Nothing is ever truncated silently.
- **Behind a flag:** effect labels.
- **Not carried:** API documentation (ZARD overlays it) and callers (no reference index, #143).

### WD5 — No source body in phase 1; `--annotate` is phase 2

Phase 1 is the declaration map. Phase 2's `--annotate` adds the body with per-line inferred types
(reusing `annotate`'s data), per-line anchors, and a token-budget design. Whether Rigor ever edits
files is deferred. WD6 keeps either answer open.

### WD6 — Anchors

- **What is hashed.** Each row carries `line:hash`: xxh3-64 truncated to 4 hex, over the verbatim
  span of the **leading annotation comment block (`#:` / `@rbs` / `@extrbs`) plus the declaration**.
  The header carries the file-level xxh3-64 in full.
- **Why this departs from lisplens.** lisplens hashes a datum without its surrounding comments
  (ADR-0008). In Ruby the annotation block is part of the type, so leaving it out would let a type
  change go unnoticed by the anchor. A Ruby edit tool adopts this span rule.
- **Collisions.** Rows sharing a span (`attr_accessor :a, :b`) take an ordinal. Gating is
  file-level, as in lisplens ADR-0017.
- **Implementation.** xxh3-64 is implemented in pure Ruby, with no new dependency
  ([ADR-31](31-contribution-and-supply-chain-policy.md)). It is verified against upstream vectors for
  inputs of length 0, 1–16, 17–128, 129–240 and 241+, and cross-checked against lisplens
  (`xxhash-rust`).

## Rejected alternatives

| Candidate | Reason |
| --- | --- |
| A discovery-only pre-pass, and "never unseeded" as the only rule | It does not reproduce `check`: inline RBS from other files and plugin pre-passes are missing (WD2). |
| Keep #512's "unseeded" note for `type-of` alongside a seeded lens | The same file would get two different answers from two oracles. |
| Extend `type-of` instead of a new command | A point query and a declaration map are different shapes; one command would render both badly. |
| Print Rigor's own spelling (`non-empty-string`) in the type position | It is not RBS until ADR-112 WD3 lands, and an agent copying it breaks `sig/`. The two-column form of `type-of` was also weighed; the sig-gen form keeps one spelling across lens, sig-gen and `.rbs`. |
| Include source bodies by default | It is no cheaper than reading the file; the line range lets an agent read what it needs. |
| lisplens's span rule (comments excluded) | The anchor would not change when the type annotation changes. |
| A native `xxhash` gem | A supply-chain addition for a few hundred bytes per call. |
| Freeze `lens/v1` now | No consumer reads it yet, and a frozen schema cannot fix what first use reveals. |

## Consequences

Positive:

- One command answers "what is here and what are its contracts", including plugin-synthesized
  members, reopenings and redefinitions that grep cannot see. Its types match `check`.
- `type-of` stops answering `Dynamic[top]` for a class declared in a sibling file.
- Anchors are compatible with lisplens and hashline, so a future edit tool, inside Rigor or outside it,
  can gate on them.

Negative and carry-over:

- The first lens on a cold project pays a one-file `check` plus environment build, and `type-of` pays
  it too.
- The `def_sites` schema bump costs one cold run. The plugin contract gains a hook.
- Per-source expansion waits on #1075. Anchors diverge from lisplens's comment rule, so a Ruby edit
  tool must adopt Rigor's.

Implementation issues:

- [#1080](https://github.com/rigortype/rigor/issues/1080): `def_sites` discovery
- [#1081](https://github.com/rigortype/rigor/issues/1081): pure-Ruby xxh3
- [#1082](https://github.com/rigortype/rigor/issues/1082): `declared_members`
- [#1083](https://github.com/rigortype/rigor/issues/1083): phase-1 lens, with `type-of`'s computation
- [#1084](https://github.com/rigortype/rigor/issues/1084): MCP and skills
- [#1085](https://github.com/rigortype/rigor/issues/1085): phase-2 `--annotate`

## Relationship to other ADRs

- **[ADR-0](0-concept.md)**: CLI-first; lens adds a read surface and no annotations.
- **[ADR-46](46-incremental-dependency-graph.md)**: WD2 reuses its session and snapshot.
- **[ADR-50](50-release-engineering-and-stability-strategy.md)**: `lens/v1` joins WD1's list only once
  a consumer exists.
- **[ADR-107](107-checked-types-and-typeless-comments.md) / [ADR-108](108-type-provenance-for-agents.md)**:
  lens is an oracle; every row is a type Rigor produced, spelled so an agent can copy it safely.
- **[ADR-110](110-inherited-declaration-precedence.md)**: the effective type of a redefinition.
- **[ADR-112](112-extrbs-comment-channel.md)**: `extrbs` provenance, the sig-gen spelling, and the WD5
  expansion.
