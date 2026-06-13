# ADR-61 — Agent-friendly diagnostic statistics (structured selector axis)

Status: **Accepted — implemented 2026-06-13.** Two additive surfaces:
`rigor check --format json` now carries the structured `receiver_type` /
`method_name` fields on each diagnostic, and `rigor triage` gains a
`selectors` section — a by-(class, method) aggregation axis beside the
existing rule `distribution` and file `hotspots`. Both let an AI agent (or
a `jq` pipeline) compute class/method statistics over a run **without
parsing diagnostic message text**. Precision-additive: no new diagnostic,
no severity change, diagnostics byte-identical. Follow-up to
[ADR-23](23-diagnostic-triage-command.md) (which moved triage's *internals*
off message parsing); this lifts that rule onto the public stream and adds
the aggregation primitive.

Grounding: the exchange that motivated it (an agent wanting to triage by
class/method via `jq`), and the ADR-23 five-project survey + Mastodon
measurement that established diagnostics cluster by structural cause, not
scatter.

## Context

`rigor triage` already answers "what is the shape of this run?" — but only
along two axes: rule-ID `distribution` and per-file `hotspots`
([`triage.rb`](../../lib/rigor/triage.rb)). The third axis a maintainer or
an agent actually reasons in — *which class/method concentrates the
diagnostics* (`String#squish` × 31 across 12 files = one unloaded core-ext,
not 31 bugs) — was reachable only by reading the human-readable summary
strings the heuristic `Catalogue` emits. That is the gap.

Two structural facts made the gap fixable cheaply:

1. The `Diagnostic` object already carries `receiver_type` / `method_name`
   (ADR-23 WD3 added them so triage's recognisers stopped parsing
   messages) — but `Diagnostic#to_h`, the `--format json` serialisation,
   **dropped them**. The data existed; the public stream hid it.
2. Only 3 of 19 rules populated those fields, so even internally the
   by-method view was sparse.

Why now: ADR-50 freezes the public output surface at v1.0, and ADR-60 is
the pre-freeze window for getting that surface right. A structured
statistics contract is exactly the kind of thing to land *before* the
freeze, not bolt on after.

## Decision

Expose the structured fields on the public stream, and add a `selectors`
aggregation axis to triage, under two reusable criteria:

- **Criterion A — message text is presentation, not contract.** Any datum
  an agent needs to *aggregate or branch on* must be a structured JSON
  field; it may never be recoverable only by parsing the `message` string.
  ADR-50 already declares diagnostic wording non-contract (a strengthening
  may reword it in a minor) — so anything an agent parses out of the
  message is built on sand. This is ADR-23 WD3's "structured-not-string"
  rule, promoted from triage's internals to the public surface.
- **Criterion B — lossy folding lives at the aggregation layer, never on
  the primitive stream.** The `check` stream stays *faithful per-site*: a
  `Constant<"hello">` receiver renders `"hello"`, a `Constant<42>` renders
  `42` — that is the true per-site type, and an agent doing per-site work
  wants it. The *normalisation* that makes statistics meaningful (folding
  every string literal to `String`) is the rollup's job and lives in
  `triage`, not on `check`. Same data, two layers, each honest about its
  job.

### WD1 — structured fields on the check stream

[`Diagnostic#to_h`](../../lib/rigor/analysis/diagnostic.rb) emits
`receiver_type` and `method_name` **when populated**, omitted otherwise
(the same convention as the existing `project_definition_site`). An agent
groups per-site with
`jq '[.diagnostics[] | select(.method_name) | {receiver: .receiver_type, method: .method_name, rule}]'`.

### WD2 — the `selectors` axis on triage

`Triage.build_selectors` ([`triage.rb`](../../lib/rigor/triage.rb)) groups
every diagnostic carrying a `method_name` by its `(receiver, method)` pair
into a `Selector = {receiver, method, count, files, rules}`:

- `count` — total; `files` — distinct-file spread (the systemic-vs-localised
  signal: high `count` × high `files` = one structural cause); `rules` —
  per-rule breakdown so a selector that mixes `undefined-method` and
  `argument-type-mismatch` is legible.
- `receiver` is **nil** for method-only diagnostics (a `def`-side return /
  override finding has no call receiver); the row still groups by method.
- The JSON list is **uncapped** — it is the agent surface; the text
  renderer caps its own rows at 15
  ([`triage_renderer.rb`](../../lib/rigor/cli/triage_renderer.rb)).
  `--selectors-only` prints just this section.

Built **purely from the structured fields** (Criterion A) — `build_selectors`
never touches `message`.

### WD3 — normalisation placement (Criterion B, concretely)

The fold lives in `Triage.normalize_receiver`
([`triage.rb`](../../lib/rigor/triage.rb)), shared with the heuristic
`Catalogue` (whose `receiver_class` now delegates to it — the literal-fold
logic exists once). String / integer / float / symbol literals collapse to
their class; `singleton(C)` and a bare `C` fold to `C`; a generic `C[...]`
keeps the `Array[String]` element form the AR-relation heuristic needs. The
concrete hazard this guards: without the fold, `"x".nope` and `name.nope`
land in *different* selector rows (`"x"#nope`, `String#nope`), fragmenting
one idiom across every literal receiver — measured directly (`"x".nope` →
`"x"` on the raw stream, `String` after the fold). The check stream is left
un-normalised on purpose.

### WD4 — which rules populate the fields

A rule stamps the selector key only where the diagnostic has an unambiguous
**dispatch subject**:

- **Call-family** (`call.undefined-method`, `self-undefined-method`,
  `unresolved-toplevel`, `argument-type-mismatch`, `wrong-arity`,
  `possible-nil-receiver`, `method-visibility-mismatch`) → receiver class +
  method (nil receiver where the receiver is a union, e.g. nil-receiver).
- **Def-family** (`return-type-mismatch`, the three `override-*`) →
  method-only (the `def` name; no call receiver).
- **Excluded**: `flow.*` (unreachable / dead-assignment / always-truthy /
  always-raises) and `def.ivar-write-mismatch` carry no method-call
  subject; synthesising a key for them would manufacture null-receiver
  noise, not signal.

Population went 3/19 → 11/19 rules
([`check_rules.rb`](../../lib/rigor/analysis/check_rules.rb) `build_*`
sites).

### Guardrail — statistics never feed severity

A per-method statistic is **diagnostic-neutral**. "Method X accounts for
40 % of errors" is as likely an RBS-coverage gap as a real bug; the
project's false-positive discipline (`feedback_false_positive_discipline`)
means the axis must route attention (to `pre_eval:` / an RBS overlay / a
plugin) and **never** escalate a severity or create a diagnostic. The
selector axis only ever *reads* the existing diagnostic stream.

## Rejected / deferred alternatives

| Candidate | Status | Reason |
| --- | --- | --- |
| Keep parsing the `message` string (status quo for agents) | Rejected | Couples consumers to wording ADR-50 declares non-contract; a message strengthening in a minor would silently break every parser. Criterion A. |
| Normalise the receiver on the `check` stream too | Rejected | Destroys per-site precision — `Constant<"hi">` *is* `"hi"`, and the per-site consumer wants that. Folding is the rollup's job. Criterion B. |
| Two separate `by_class` and `by_method` axes | Rejected | One `(receiver, method)` primitive is strictly more flexible — `jq` composes both views (`group_by(.receiver)` / `group_by(.method)`) — and two axes duplicate the same rows. |
| Populate every rule (incl. `flow.*` / ivar) with a synthesised key | Rejected | Those diagnostics have no dispatch subject; a null-receiver or operator-named bucket is noise. WD4's subject test is the line. |
| Cap the JSON `selectors` list | Rejected | The JSON is the agent surface; capping breaks the `jq` use case. The text renderer caps instead. |
| A new top-level `rigor stats` command | Deferred | `triage` is already the aggregation home (ADR-23) and runs the analysis once; a new command would duplicate that pass for no new capability. Revisit only on demand for a non-triage statistics need. |

## Consequences

Positive:

- An agent triages by class/method with a `jq` one-liner over a stable
  contract — e.g. `jq '.selectors[] | select(.files >= 3)'` for cross-file
  systemic clusters — instead of regex over prose. The two onboarding
  skills (`rigor-project-init`, `rigor-baseline-reduce`) now teach this.
- The `check` per-site fields and the `triage` aggregate compose: precise
  per-site grouping on `check`, normalised rollup on `triage`.

Negative / carry-over:

- The selector fields and the `selectors` shape become **frozen public
  vocabulary** under ADR-50 WD1 at v1.0 — intentionally landed in the
  pre-freeze window (ADR-60), but a post-freeze rename is then a BC break.
- `flow.*` / ivar diagnostics are absent from the axis by design (WD4); a
  consumer wanting "every diagnostic by file" still uses `hotspots`.
- The acceptance bar was `make verify` green (6261 examples, 0 failures),
  self-check + `check-plugins` clean, diagnostics byte-identical — the
  change adds JSON fields and a report section, never a diagnostic.

## Relationship to other ADRs

- **[ADR-23](23-diagnostic-triage-command.md)** — parent. This extends WD3's
  "structured-not-string" rule from triage's internals onto the public
  stream, and adds the by-(class, method) axis its `distribution` /
  `hotspots` left open.
- **[ADR-50](50-release-engineering-and-stability-strategy.md)** — the
  output stream is public contract; the new fields and selector shape enter
  the frozen vocabulary. Landing pre-freeze is the deliberate timing.
- **[ADR-51](51-ci-diagnostic-output-formats.md)** — sibling: the CI
  formats are *presentation* over the same `Diagnostic` fields; this is the
  *aggregation* counterpart over the same fields.
- **[ADR-33](33-mcp-server.md)** — the MCP `rigor_triage` / `rigor_check`
  tools surface the same JSON to assistants; the structured fields sharpen
  what those tools can return.
- **`feedback_false_positive_discipline`** — the guardrail the statistics
  axis observes: it routes attention, never feeds severity.
