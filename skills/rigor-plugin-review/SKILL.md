---
name: rigor-plugin-review
description: |
  Review an existing Rigor plugin's source against the current authoring contract and produce a prioritized upgrade path — the modernization counterpart to rigor-plugin-author. Audits config-default declaration (ADR-40), the AST-walk model (node_rule vs a hand-rolled traversal), return-type / narrowing hooks (dynamic_return / narrowing_facts, not the removed flow_contribution_for or type_specifier), the ADR-60 WD4 authoring helpers (diagnostic / diagnostics_for / suggest / producer_value / read_fact), engine-collaboration vs reimplementation, cache-producer soundness, manifest-field hygiene, and doc freshness. Triggers: "review this Rigor plugin", "does my plugin follow best practices", "upgrade our rigor-prefixed plugin to the latest contract", "modernize this plugin", "is this plugin using the current API". NOT for authoring a new plugin (use rigor-plugin-author), enabling bundled plugins on a project (use rigor-plugin-tune), or tuning plugin config.
license: MPL-2.0
metadata:
  version: 0.1.0
  homepage: https://github.com/rigortype/rigor
---

# Rigor Plugin Review

Audit an **existing** Rigor plugin — a bundled one in the rigor
monorepo (`plugins/` or `examples/`), or your own `rigor-<id>` gem —
against the current `Rigor::Plugin::Base` authoring contract, and hand
back a **prioritized upgrade path**. This is the review / upgrade
counterpart to `rigor-plugin-author` (which creates new plugins).

Plugins written before a contract addition keep working — the gate is
compatibility, not currency — but they drift from the idiom other
authors copy. The commonest drift, in rough order of how often it
appears:

1. **Config defaults** declared with a `DEFAULT_*` constant +
   `config.fetch(k, DEFAULT)` instead of `config_schema {kind:,
   default:}` (ADR-40).
2. **Hand-rolled boilerplate** the ADR-60 WD4 authoring helpers now
   own — a Levenshtein "did you mean", a `@table`/`@load_error` memo +
   rescue, a `Diagnostic.new` where a node exists.
3. **A hand-rolled AST walk** where the engine-owned `node_rule` now
   fits (ADR-37 / ADR-52).
4. **Removed / renamed hooks** still named — `flow_contribution_for`
   (deleted, ADR-52 WD3) or `type_specifier` (removed in 0.3.0; renamed to
   `narrowing_facts`, ADR-80).
5. **Stale docs** — archaeology about deleted hooks, pinned version
   references that no longer mean anything.

## First: load the version-current copy

This skill audits against a contract that moves release to release (hook
renames, new helpers, deprecations), so its checklist — in its
`references/` files — is only as good as the Rigor it ships with. Follow
the copy that ships with the **installed** Rigor rather than any vendored
or frozen copy of this file. Get the complete current procedure (body + all
references, inline) in one call:

```sh
rigor skill --full rigor-plugin-review
```

If you already loaded this skill *via* `rigor skill` you have the current
copy — just proceed. If `rigor` is not on `PATH`, this task needs it: run
**`rigor-next-steps`** to install Rigor first, then come back.

## When to use / not use

**Use it** when someone asks to review a plugin's quality, check it
against best practices, or upgrade it to the current contract — whether
it lives in the rigor monorepo or in an external repo.

**Do not use it** for:

- **Authoring a new plugin** → `rigor-plugin-author`.
- **Choosing / enabling bundled plugins on a project** →
  `rigor-plugin-tune`.
- **A behavioural bug in a plugin** — that is ordinary debugging, not a
  contract-conformance pass.

## Read the plugin — and read the contract

Rigor is installed on disk, so both the plugin under review and the
worked-example plugins are readable source:

```sh
rigor plugin list                 # every bundled + example plugin, with paths
rigor plugin print rigor-<id>     # a plugin's main source, inline
rigor plugin path  rigor-<id>     # its directory, to browse
```

The **authoritative** authoring surface — the one this review scores
against — is the internal spec, not this file:

- [`docs/internal-spec/plugin.md`](../../docs/internal-spec/plugin.md)
  — manifest, `node_rule` / `node_file_context`, `dynamic_return` /
  `narrowing_facts`, the `#diagnostic` / `#diagnostics_for` / `.suggest`
  / `#read_fact` author helpers, `config_schema` `{kind:, default:}`.
- [`docs/internal-spec/plugin-cache-producers.md`](../../docs/internal-spec/plugin-cache-producers.md)
  — `producer` / `#cache_for` / `#producer_value` / `#producer_error`,
  ADR-60 WD3 record-and-validate.
- [`docs/internal-spec/plugin-trust.md`](../../docs/internal-spec/plugin-trust.md)
  — `TrustPolicy` / `IoBoundary`.

When the checklist below and the spec disagree, **the spec binds** —
it tracks the installed `rigor` version; this skill is a snapshot.

## Procedure

### Phase 1 — Inventory

Read the plugin's `lib/**/*.rb`, its `README.md`, and its integration /
unit spec. Note: the `manifest(...)` block, every `config.fetch` /
`DEFAULT_*` constant, every `Rigor::Analysis::Diagnostic.new`, any
hand-rolled `levenshtein` / `each_child` walk / cross-plugin `@*_resolved`
flag, and every mention of `flow_contribution_for` / `type_specifier`.

### Phase 2 — Score against the checklist

Walk [`references/01-best-practices-checklist.md`](references/01-best-practices-checklist.md)
concern by concern. For each finding, record: the smell, the modern
replacement, the authoritative citation, and — critically — whether the
change is **mechanical** (byte-identical diagnostics expected) or
**design-level** (needs judgment / may change behaviour).

### Phase 3 — Establish the oracle BEFORE changing anything

The plugin's integration spec is the contract you must preserve. Run it
green first, so you can prove each later step is a faithful refactor:

```sh
# external gem:
bundle exec rspec spec/
# in the rigor monorepo:
nix … develop --command bundle exec rspec spec/integration/<plugins|examples>/<id>_plugin_spec.rb
```

If there is no spec, **write one first** (per `rigor-plugin-author`
Phase 3) — a modernization with no oracle is a guess.

### Phase 4 — Apply the upgrade path, mechanical first

Order the work low-risk → high-risk, and **re-run the spec after every
step**:

1. **Mechanical (expect byte-identical diagnostics):** ADR-40 config
   defaults · helper swaps (`suggest` / `producer_value` / `diagnostic`
   / `diagnostics_for` / `read_fact`) · manifest-field renames (ADR-60
   WD1/WD2) · doc freshness. A spec that changes here means the swap was
   not faithful — fix it, do not re-baseline.
2. **Design-level (may change behaviour — validate empirically):** an
   AST-walk migration onto `node_rule`; an engine-collaboration refactor
   that reads `Scope#type_of` instead of a hand-rolled binding map.
   **Do not delete hand-rolled state before proving the engine gives you
   the same information** — see the `rigor-units` trap in the checklist
   (the diagnostics-side `Scope` is a *seed entry scope* without
   flow-accumulated local bindings, so a cross-statement binding map can
   be necessary, not redundant).

### Phase 5 — Verify

```sh
rigor check <plugin>/lib        # ADR-43 contract self-check — MUST be clean
rigor plugins --strict          # the plugin still loads
rigor plugins --capabilities    # node-rule types / dynamic_return receivers look right
bundle exec rspec …             # the oracle spec, still green
```

In the **rigor monorepo**, the gate is `make check-plugins` (runs
`rigor check` over every `plugins/*/lib` + `examples/*/lib`) plus
`make verify`; land the change as its own commit(s) with the spec as
the byte-identical gate.

## Output

Hand the user a table — smell → replacement → authority → mechanical /
design — ranked so the mechanical, oracle-gated wins land first, and
call out any finding (like the units binding-map case) where the
"obvious" modernization is actually wrong. If nothing is stale, say so
plainly: a plugin that already tracks the current contract is a pass,
not an occasion to invent churn.

## Next step

Re-run `rigor skill describe` for the next move, or `rigor-plugin-author`
if the review surfaced a *new* capability the plugin should grow.
