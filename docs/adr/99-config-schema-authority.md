# ADR-99 — The config schema is a source of truth: `.rigor.yml` tiers and the reserve pipeline

Status: **Accepted, 2026-07-17 — implemented.** `schemas/rigor-config.schema.json` becomes a named
source of truth for `.rigor.yml` in `docs/compatibility.md`'s frozen-surface table, and
[`docs/internal-spec/config.md`](../internal-spec/config.md) becomes the normative statement of the
three validation tiers, the reserved-namespace rule, and the reserve pipeline. The audit's three
defects are fixed alongside: the `cache` nested drift and its gate blind spot, the 404 `$id`, and the
missing `rigor_rs:` reservation.

Grounding: the 2026-07-17 config consistency audit recorded in § Context — every claim below was
reproduced against the tree, not read off a document.

## Context

Four artifacts describe `.rigor.yml`, and nothing said how they relate:

| Artifact | Job |
| --- | --- |
| `schemas/rigor-config.schema.json` | JSON Schema; reaches editors via the `# yaml-language-server: $schema=` comment that `.rigor.dist.yml` carries and `rigor init` writes |
| `lib/rigor/configuration.rb` | `DEFAULTS` + the coercers |
| `lib/rigor/config_audit.rb` | the resolves-to-nothing warnings |
| `docs/manual/03-configuration.md` | the user-facing key reference |

[`docs/compatibility.md`](../compatibility.md) carries the [ADR-50](50-release-engineering-and-stability-strategy.md)
WD1 frozen-surface table, and its `.rigor.yml` row names the source of truth as `Configuration::DEFAULTS`
plus the coercers, with the manual as the user doc. **The schema is absent from that row — and from the
manual.** It is therefore invisible at both places a config decision actually gets made, and the audit
found what that costs:

1. **`cache.max_bytes` and `cache.validation` are rejected by the schema.** Both are in `DEFAULTS`
   and both are documented in the manual; the schema's `cache` object declares only `path` and is
   `additionalProperties: false`. `spec/rigor/config_schema_spec.rb` pins DEFAULTS → schema for
   **top-level keys only**, so the nested surface drifted underneath the gate. A contributor adding a
   nested key is never told the schema exists.
2. **The schema URL `rigor init` writes 404s.** Its `$id`, and the URL written into every generated
   `.rigor.yml`, name `zenwerk/rigor`; this project is `rigortype/rigor`. So **every project
   initialised with `rigor init` has had no schema validation at all** — and a schema that fails to
   load is indistinguishable from a schema with no complaints, which is how this hid alongside (1)
   for as long as it did. This repo's own `.rigor.dist.yml` uses a relative path and only `cache.path`,
   so the one file that would have surfaced (1) happens to dodge it.
3. **rigor-rs vendors this schema as its authoritative config schema.** The port carries this repo as
   a submodule at `reference/rigor` and its copy is byte-identical. No document here grants it that
   role. And because the top level is `additionalProperties: false`, the vendored schema rejects
   `rigor_rs:` — the port's own namespace, in the port's own checkout.

(3) is the sharp one: **a second implementation depends on a file this repo does not list as a source
of truth.** The port's [ADR-0036](https://github.com/rigortype/rigor-rs/blob/master/docs/adr/0036-ruby-sidecar-default-reversal.md)
introduced `rigor_rs:` on the stated rationale that "the reference ignores unknown keys, so `rigor_rs:`
is transparent to it". That is a **runtime** claim, and it is true — a config carrying `rigor_rs:`
loads, checks clean, and exits 0 with no warning, because `Configuration` reads its keys one at a time
and never enumerates unknown ones. ADR-0036 simply never considered the schema layer. Neither did we.

## Decision

**The schema is a source of truth for `.rigor.yml`, co-equal with `Configuration::DEFAULTS` and its
coercers, and authoritative for both implementations.**

The discriminating criterion: **rigor-rs is a port, so the reference owns the config surface — including
the namespace a port needs for concepts the reference does not have.** A port-specific key is not the
port's private business; it is a reservation the reference grants. That inverts the intuition ADR-0036
encoded (each implementation owns its own namespace) and it is why the reference must declare
`rigor_rs:`'s shape rather than merely tolerate it.

### WD1 — three tiers, three failure modes

`.rigor.yml` is validated at three independent tiers. Which tier a key answers to is the design
question every config decision must answer:

| Tier | Checker | When | On failure |
| --- | --- | --- | --- |
| Schema | editor / CI | edit time | a squiggle; **no runtime effect** |
| `Configuration` load | this implementation | load time | `ArgumentError` |
| Config audit | this implementation | check time | STDERR warning; **exit code unchanged** |

A reserved namespace answers to the **schema tier only**: type-checked where it is written, never
read, never validated, never coerced, and never a runtime error however invalid its value. This is
what "validated but not evaluated" means concretely, and it is the position `rigor_rs:` occupies.

### WD2 — the reserve pipeline, and why the ordering is load-bearing

> propose in the port → **reserve in this repo's schema** → implement in the port → release here →
> release the port

Reserving before implementing is what stops a user's editor from flagging a key their newly-updated
port just started requiring. The pipeline has already run backwards once — the port implemented
`rigor_rs.ruby` before the reference reserved it, which is exactly why the schema rejects it today.

Because the reserve is **authoritative rather than a mirror**, constraining a reserved namespace's
contents is correct: an undeclared key under `rigor_rs:` means the port shipped something the reserve
never granted. This is the one place `additionalProperties: false` earns its keep on a namespace the
reference does not read.

### WD3 — documents make the schema findable; gates make forgetting it fail

Both halves are required, and the audit shows why neither suffices alone. The documents
(`internal-spec/config.md`, the compatibility row, the manual) reach someone who reads them — and not
reading them is precisely how all three defects happened. The gates catch the rest:

- **DEFAULTS → schema, nested** (`config_schema_spec`): a new key under `cache:` / `plugins_io:` /
  `bundler:` / … fails the build unless the schema knows it. This is the axis whose absence let (1)
  rot.
- **Reserved namespace → schema**: a *separate* axis, because a reserved namespace is **by definition
  not a `DEFAULTS` key** (`DEFAULTS.key?("rigor_rs") == false`). No amount of widening the
  DEFAULTS-keyed gate can ever reach it — the blind spot is structural, not an oversight of scope.
- **`$id` ↔ the init-written URL**: one constant, read by both, so they cannot disagree.

### WD4 — `AGENTS.md` is unchanged

By [ADR-98](98-development-flow-document-roles.md)'s premise test — *will a session that never thought
to look it up do the wrong thing?* — config semantics is a **lookup**: it matters to a session already
touching config. And the one demonstrated failure is now gated, so a reminder would be an instruction
duplicating a gate ([ADR-97](97-adr-index-budgets.md) criterion 2). `AGENTS.md` already routes analyzer
contracts to `docs/internal-spec/`, so `config.md` inherits the pointer for free — at zero bytes.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Declare `rigor_rs:` as an opaque `{"type": "object"}` | Rejected | The first instinct, and it inverts the authority: it treats the port as owning its namespace's grammar and the reference as merely tolerating it. Under WD1 the reference *grants* the namespace, so it declares the shape. An opaque object would also silently accept the typo (`rigor_rs: { rubi: auto }`) the reserve exists to catch. |
| Mirror the port's grammar and track its evolution | Rejected (mis-framing) | This was the objection to declaring the shape — that the reference would be chasing the port. It has the arrow backwards: the port tracks the reference. There is nothing to chase. |
| `$ref` the reserved namespace to a port-published schema | Rejected | Needs a remote reference to resolve in every editor and CI, and the port publishes no schema — it vendors ours. Defect (2) is a live demonstration of what a rotted schema URL costs, which is a poor foundation for adding one. |
| Constrain `rigor_rs.ruby` with an `enum` | Rejected | The port's grammar is `require` / `auto` / `off` **or any path** (`ruby_mode.rs` `parse_value`: reserved keyword, else `Path`). An enum would reject every path form — a reserve that lies about the shape is worse than no reserve. |
| A line in `AGENTS.md` pointing at the config semantics | Rejected | WD4. |
| Put the semantics in `docs/manual/03-configuration.md` | Rejected | The manual is user-facing, and the rationale here (schema authority, the port pipeline) is contributor material. The manual gets the *fact* that the schema exists and how to use it; `internal-spec/config.md` gets the semantics — the same split `baseline.md` and `cache.md` already use for their user-facing artifacts. |
| Warn on unknown top-level keys in the same change | Deferred | Tracked as #166 and blocked on this one — a new warning is BC-bearing and its `config_warnings` kind is v1.0-frozen vocabulary. Reserving first is what makes it safe to add at all. |

## Consequences

Positive:

- The schema is named where config decisions are made, and both ways of forgetting it now fail a build.
- "Validated but not evaluated" is a stated position with a document, not an emergent property of
  `Configuration` reading its keys one at a time.
- The port gets a reservation it can implement against, and the pipeline that keeps the two releases
  ordered.
- `rigor init` writes a URL that resolves, so schema validation reaches users at all for the first time.

Negative:

- The reference now declares a shape it does not read, so a port change needs a reference release in
  front of it. That is the cost the pipeline buys ordering with, and it is real: a port key cannot ship
  faster than our release cadence.
- Three tiers is more surface to explain than "the config is validated". The tiers already existed;
  this only names them.

## Relationship to other ADRs

- **[ADR-50](50-release-engineering-and-stability-strategy.md)** — WD1 owns the frozen public surface
  and already lists `.rigor.yml` keys; this adds the schema to that row's sources of truth. The
  reserve pipeline is a release-ordering constraint under its cadence.
- **[ADR-97](97-adr-index-budgets.md) / [ADR-98](98-development-flow-document-roles.md)** — criterion 2
  (an unenforced rule is a temporary state) is why WD3 pairs every document with a gate, and ADR-98's
  premise test is why WD4 leaves `AGENTS.md` alone.
- **[ADR-10](10-dependency-source-inference.md)** — `dependencies.source_inference:` is the precedent
  for a config key whose semantics are specified outside the manual
  (`docs/internal-spec/dependency-source-inference.md`); `config.md` is the general case.
- **rigor-rs ADR-0036** — introduced `rigor_rs:` on a runtime-only rationale and never considered the
  schema. This is the reference-side half it was missing; its namespace decision stands, its authority
  framing does not.
