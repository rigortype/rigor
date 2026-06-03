# `Rigor::Analysis::Diagnostic` shape

## Status

**Descriptive, not yet locked.** This documents the *current* shape of the
diagnostic carrier so consumers (triage, baseline, plugins reading the
JSON stream) can rely on a written contract. It does **not** pin the
surface: per [`public-api.md`](public-api.md) the per-rule identifiers and
the structured-field set may still change before v0.1.0 locks them, so
`Rigor::Analysis::Diagnostic` is intentionally absent from the public-API
drift spec. The *identifier taxonomy*, severity resolution, and
suppression semantics are normative in
[`diagnostic-policy.md`](../type-specification/diagnostic-policy.md); this
page is only about the object's field shape.

## Fields

`Rigor::Analysis::Diagnostic` carries:

| Field | Type | Meaning |
| --- | --- | --- |
| `path` | `String` | The analysed file the diagnostic is reported against. |
| `line` | `Integer` | 1-based source line. |
| `column` | `Integer` | **1-based** column (Prism columns are 0-based; the constructors add 1). |
| `message` | `String` | Human-readable text. |
| `severity` | `Symbol` | The *authored* severity (`:error` / `:warning` / `:info`) before profile re-stamping ([severity resolution](../type-specification/diagnostic-policy.md#severity-resolution)). |
| `rule` | `String?` | Stable kebab-case rule id (`call.undefined-method`). `nil` for diagnostics not produced by `CheckRules` (parse errors, path errors, internal-analyzer errors) — a `nil`-rule diagnostic is **unsuppressible**. |
| `source_family` | `Symbol` | The rule's producer. Default `:builtin`; non-default families carry provenance (`"plugin.<id>"`, `:rbs_extended`, `:generated`). |
| `receiver_type` | `String?` | Structured field — the rendered receiver type for call-related rules; `nil` otherwise. |
| `method_name` | `String?` | Structured field — the called method name for call-related rules; `nil` otherwise. |
| `project_definition_site` | `String?` | `"path:line"` set by `call.undefined-method` when the project itself defines the called method elsewhere in the analysed set (a reopened class the dispatcher does not apply cross-file). `nil` for every other diagnostic. |

`receiver_type` / `method_name` exist so `rigor triage`'s recognisers
([ADR-23](../adr/23-diagnostic-triage-command.md)) read the structured pair
instead of parsing the message; a consumer that finds them `nil` falls
back to message parsing. `project_definition_site`'s presence is the
high-confidence "project monkey-patch, not a bug" signal triage keys on to
recommend `pre_eval:` ([ADR-17](../adr/17-monkey-patch-pre-evaluation.md)).

## Construction and position convention

Two factories internalise the load-bearing position convention so callers
do not re-derive it:

- `Diagnostic.from_node(node, path:, message:, …)` — positions at `node`,
  with `line = node.location.start_line` and `column =
  node.location.start_column + 1`.
- `Diagnostic.from_location(location, path:, message:, …)` — same
  convention from an explicit Prism location, used to point at a
  *sub-location* (most often a call's `message_loc`, the matcher / method
  name, rather than the receiver-spanning whole node). `from_node` is
  sugar for `from_location(node.location, …)`.

Plugin authors call `Plugin::Base#diagnostic` (which wraps these) and MUST
NOT set `source_family` — the runner stamps the plugin provenance. Core
rules and other producers may call the factories directly.

## `qualified_rule` derivation and provenance

`#qualified_rule` is the identifier consumers key on (suppression,
baseline buckets, `--format json`). It MUST be:

- `nil` when `rule` is `nil`.
- `rule` verbatim when `source_family` is the default `:builtin`.
- `"<source_family>.<rule>"` otherwise — so a plugin rule surfaces as
  `plugin.<id>.<rule>`, an RBS::Extended rule as `rbs_extended.<rule>`,
  and a generated-signature rule as `generated.<provider>.<rule>`
  ([ADR-2](../adr/2-extension-api.md) § "Plugin Diagnostic Provenance").

`#to_s` (the `rigor check` text line `path:line:column: severity:
message`) appends `[<qualified_rule>]` only when `source_family` is
non-default, so provenance is visible without changing the layout for
built-in rules.
