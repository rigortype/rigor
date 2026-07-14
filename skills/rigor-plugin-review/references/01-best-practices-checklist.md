# Plugin best-practices checklist

Score a plugin concern by concern. Each row is **smell → modern
replacement → authority**. The authority column names the binding
surface (`docs/internal-spec/*` or the ADR); when it disagrees with
this file, it wins.

`M` = mechanical (byte-identical diagnostics expected; oracle-gated).
`D` = design-level (may change behaviour; validate empirically).

---

## 1. Manifest & config defaults (ADR-40) — `M`

**Smell:**

```ruby
DEFAULT_ROUTES_FILE = "config/routes.yml"
config_schema: { "routes_file" => :string }
# …
@routes_file = config.fetch("routes_file", DEFAULT_ROUTES_FILE)
```

**Modern:**

```ruby
config_schema: { "routes_file" => { kind: :string, default: "config/routes.yml" } }
# …
@routes_file = config["routes_file"]   # default merged under user config
```

`Base#config` merges `manifest.config_defaults` beneath the user config,
so the plugin reads the key directly and the `DEFAULT_*` constant goes
away. Keep a constant only where a value needs *validation the merged
default cannot express* (e.g. an allow-listed `severity` that must fall
back when a user supplies a bad value).

**Authority:** `docs/internal-spec/plugin.md` § "Declared config
defaults — `config_schema` `{ kind:, default: }`".

---

## 2. AST-walk ownership (ADR-37 / ADR-52) — `D`

**Smell:** a hand-rolled traversal for per-node checks —
`root.compact_child_nodes.each { … }`, a bespoke `Walker` that recurses
the tree, or a `#diagnostics_for_file` that re-walks to find call sites.

**Modern:** declare `node_rule(Prism::CallNode) { |node, scope, path| … }`
and let the engine own the single per-file walk. For a two-pass
(collect-then-validate) plugin, add `node_file_context { |root, scope| … }`
— it runs once before the node rules and threads a file-local value in
as the rule block's fourth argument.

**Keep `#diagnostics_for_file`** only for genuinely whole-file
diagnostics a per-node walk cannot express — see concern 5 for the case
where a stateful whole-file walk is *required*, not lazy.

**"Genuinely whole-file" is a sharp line — apply it, don't defer to
precedent.** A per-*class* or per-*def* contract check (does this class
define `#get`? does its body return the contracted type?) IS
node-expressible — migrate it to `node_rule(Prism::ClassNode)` /
`node_rule(Prism::DefNode)`, even if a shipped production plugin still
uses `#diagnostics_for_file` + a hand-rolled `class_nodes` walk for the
same job (`rigor-hanami`'s ADR-28 check half does — an equivalent,
older shape, not a reason to keep a new copy hand-rolled). The genuine
whole-file case is a diagnostic whose *identity or count is not tied to
any one node* — e.g. `rigor-routes`'s "routes file failed to load"
warning, which must fire exactly once per file (or run) even on a file
with zero matching nodes. That cannot be a node rule; a per-class check
can.

**Authority:** `docs/internal-spec/plugin.md` §§ "Node-scoped rules —
`node_rule`", "`node_file_context`".

---

## 3. Return-type & narrowing hooks (ADR-37 / ADR-52 / ADR-80) — `M`/`D`

**Smell:** `flow_contribution_for` (deleted in ADR-52 WD3 — *defining it
now raises `ArgumentError`*), or `type_specifier` (the pre-ADR-80 name,
removed in 0.3.0 — it now raises `NoMethodError`).

**Modern:** `dynamic_return(receivers:/methods:/file_methods:)` to
*supply* a return type, `narrowing_facts(methods:)` to supply
post-return narrowing facts. Rename any surviving `type_specifier` to
`narrowing_facts`.

The gate resolves after `#init` when passed a callable
(`methods: -> { [@method_name] }`), so config-derived method names work.

**Authority:** `docs/internal-spec/plugin.md` § "Return-type and
narrowing contributions". `M` for the pure rename; `D` if you are adding
a contribution the plugin did not have.

---

## 4. Authoring helpers (ADR-37 / ADR-60 WD4) — `M`

The single richest source of drift. Each helper replaces a hand-rolled
shape and is expected to be diagnostics-preserving.

| Smell | Modern | Authority |
| --- | --- | --- |
| `Rigor::Analysis::Diagnostic.new(line:, column: loc.start_column + 1, …)` where a node exists | `#diagnostic(node, path:, message:, severity:, rule:)` (or `location: node.message_loc` for a sub-span) | plugin.md § "Positioning a diagnostic — `#diagnostic`" |
| `violations.map { |v| diagnostic(node, message: v.message, …) }` | `#diagnostics_for(violations, path:, node:)` — duck-types `#message` / `#node` / `#severity` / `#rule` / `#location` | plugin.md § author helpers (ADR-60 WD4) |
| A hand-rolled `levenshtein` / `closest_*` "did you mean" | `Rigor::Plugin::Base.suggest(name, candidates)` (`DidYouMean::SpellChecker`) — a **class** method, callable from an `Analyzer` too | plugin.md § "`Base.suggest`" |
| `@table ||= cache_for(id).call` + a multi-`rescue` ladder + an `@load_error` ivar | `#producer_value(id, params:)` (memoised incl. nil) + `#producer_error(id)` (the rescued exception, for a tailored message) | plugin-cache-producers.md § "Invalidation contract" |
| `@x_resolved` flag guarding `services.fact_store.read` | `#read_fact(plugin_id:, name:)` — nil-inclusive memo, retires the flag | plugin.md § author helpers (ADR-60 WD4) |
| Hand-parsing a `Prism::SymbolNode#value` / string literal | `Rigor::Source::Literals` | plugin.md § "Extracting argument literals" |
| A private reimplementation of a target library (own inflector, own pure helper) | Call the library's safe methods directly — `Plugin::Inflector` over real `ActiveSupport::Inflector` (ADR-39) | plugin.md § "Target-library invocation" |

**Note on tailored load-error messages:** `#producer_value` rescues
every `StandardError` into `#producer_error`, so a plugin that wants
class-specific messages ("not found" vs "failed to parse" vs
access-denied) switches on `producer_error(id)`'s class when building
the load-error diagnostic — cleaner than an inline rescue ladder and
still message-preserving. A *file-level* load-error (line 1, no node)
legitimately keeps a direct `Diagnostic.new` — `#diagnostic` needs a
node to position at.

---

## 5. Engine collaboration vs reimplementation — `D` (read the trap)

**Principle (rigor-pattern):** do not re-implement a fact the engine
already computes. If you need "is this a literal string?" / "what type
did inference give this expression?", read `Scope#type_of(node)` rather
than tracking it yourself. `rigor-pattern` reads the engine's
`LiteralStringFolding` result back instead of propagating strings by
hand.

**The trap (rigor-units) — when a hand-rolled binding map is NOT
redundant:** the `Scope` handed to the **diagnostics** side
(`#diagnostics_for_file` / a `node_rule`) is the **seed entry scope**.
`Scope#type_of` re-evaluates a *self-contained* expression on demand
(`scope.type_of(100.kilometers)` folds through the plugin's own
`dynamic_return`), but it carries **no flow-accumulated local
bindings**: for `speed = distance / time`, `scope.type_of(distance)` is
`untyped`, because the entry scope never bound the earlier assignment.
Only the **flow scope** handed to a `dynamic_return` block resolves such
locals. So a diagnostics-side check that must follow a dimension /
type across statements legitimately keeps its own single-pass binding
map — deleting it and reaching for `scope.type_of` collapses
cross-statement propagation.

**How to tell which case you are in:** if the value you need lives *at
the call site you are inspecting* (a literal argument, a self-contained
sub-expression) → read `Scope#type_of`. If it lives *in an earlier
statement's local binding* and you are on the diagnostics side → the
engine will not hand it to you; keep the binding map, and document why.
**Validate empirically before deleting state:** run the integration
spec after the change; a wave of failures on multi-statement fixtures is
this trap.

**Authority:** the reasoning is recorded in
`docs/notes/20260704-examples-plugin-modernization-survey.md` (the
`rigor-units` section) and the `rigor-units` class comment itself.

---

## 6. Cache producers (ADR-60 WD3) — `M`/`D`

**Smell:** a "prime the read before `cache_for` so the digest is
captured" comment, or a producer that globs a directory but does not
declare `watch:`.

**Modern:** record-and-validate — the `io_boundary.read_file` inside the
`producer` block is captured into the dependency descriptor *after* the
block runs, so there is nothing to prime. A producer that reads a *set*
of files by glob declares `watch:` so file *additions* invalidate too.

**Authority:** `docs/internal-spec/plugin-cache-producers.md` §§
"Invalidation contract", "`producer(... watch:)`".

---

## 7. Manifest-field hygiene (ADR-60 WD1 / WD2) — `M`

**Smell:** `external_files:` (never wired — removed in ADR-60 WD1);
`BlockAsMethod verbs:` (renamed → `method_names:`); `NestedClassTemplate
name_arg_position:` (renamed → `symbol_arg_position:`).

**Modern:** drop `external_files:`; use the renamed keys.

**Authority:** `docs/internal-spec/plugin.md` § "`Rigor::Plugin::Manifest`"
and `macro-substrate.md`.

---

## 8. Documentation freshness — `M`

**Smell:** "the former `flow_contribution_for` hook was removed"
archaeology in a README / class comment (a reader who never knew the
deleted hook does not need it named); pinned version references that no
longer carry meaning ("introduced in v0.0.9").

**Modern:** describe the *current* mechanism directly. Keep a historical
note only where a reader migrating an old plugin genuinely needs it —
and put that in a CHANGELOG / migration note, not the class docstring.

---

## 9. Verification (ADR-43) — always

- `rigor check <plugin>/lib` — the ADR-43 contract self-check resolves
  the plugin's inherited `Plugin::Base` calls and warns on contract
  misuse. MUST be clean; fix the cause, never disable the rule.
- `rigor plugins --strict` — the plugin still activates.
- `rigor plugins --capabilities` — `node_rule_types` /
  `dynamic_return_receivers` / `narrowing_facts_methods` reflect the
  declarations.
- The integration / unit spec — green, and byte-identical across every
  mechanical step.
- In the monorepo: `make check-plugins` + `make verify`.
