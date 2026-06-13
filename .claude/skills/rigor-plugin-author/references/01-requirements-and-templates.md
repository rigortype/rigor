# Phases 1–2 — Requirements gathering & template selection

Before any code, get the user to commit to answers for **all five** questions below. Ask them in a single message; do NOT scaffold anything yet. The answers narrow the architecture choice in [Phase 2](02-template-selection.md).

## Q1. Trigger surface — what call shape activates the plugin?

- **A.** A specific module / class method (`Module.method(...)`, `Class#method(...)`).
- **B.** A specific implicit-receiver method (top-level `helper(...)`).
- **C.** A method whose name matches a pattern (`*_path`, `*_url`, `transition_to_*`).
- **D.** A constructor chain on a built-in type (`100.kilometers`, `"x".validates_as(:email)`).
- **E.** A DSL block (`state_machine do ... end`, `validates_with do ... end`).

## Q2. What does the plugin need to LOOK at?

- **A.** Just the call site (literal arguments, immediate receiver).
- **B.** The local-variable bindings flowing INTO the call site (variable came from earlier in the file).
- **C.** Declarations from EARLIER in the same file (a `state` block before the `transition_to` call).
- **D.** Declarations from ANOTHER file in the project (cross-file).
- **E.** An external resource — `config/routes.yml`, `db/schema.rb`, `config/locales/*.yml`.

## Q3. What does the plugin need to PROVE?

- **A.** The argument is one of a known finite set (route name, state name, deprecated method name).
- **B.** The argument's literal value matches a pattern (regex, format string).
- **C.** The arguments compose dimensionally (Distance + Distance = Distance; Distance + Time = error).
- **D.** The arity / shape matches a declared signature.
- **E.** The literal expression evaluates to a known type (Lisp eval pattern).

## Q4. What diagnostic output does the user want?

- **A. Info-only** — surface the inferred type / matched name as a trace, no errors.
- **B. Error on mismatch** — flag wrong inputs, otherwise stay silent.
- **C. Both** — info on success, error on mismatch.
- **D. Warning** — deprecation / soft contract violation.

## Q5. What is the plugin's CONFIGURATION shape?

- **A. None** — behaviour is hard-coded.
- **B. A few string knobs** (`module_name`, `severity`).
- **C. A list / hash of rules** (deprecation entries, regex patterns).
- **D. An external file path** (`routes_file: "config/routes.yml"`).
- **E. All of the above** (rich configuration).

---

Two authoring paths exist as of v0.1.x:

1. **Macro expansion substrate** (ADR-16) — declarative `manifest` entries; substrate handles AST walking, name-interpolation, and synthesis. Use this when the plugin's job fits one of the three ADR-16 tiers below. (Note: ADR-60 WD2 renamed `BlockAsMethod`'s `verbs:` → `method_names:` and `NestedClassTemplate`'s `name_arg_position:` → `symbol_arg_position:`; the old keywords raise `ArgumentError`.)
2. **Node rules + narrow contribution DSLs** (ADR-37) — `node_rule` for per-call diagnostics (the engine owns the walk), `node_file_context` for same-file two-pass, `dynamic_return(receivers:)` for call-site return types, `type_specifier(methods:)` for post-return narrowing facts (truthy/falsey/type guards — used by `rigor-rspec`/`rigor-sorbet`/`rigor-minitest`), and `type_node_resolvers:` (ADR-13) for custom `%a{rigor:v1:…}` type vocabulary (`rigor-typescript-utility-types`). `diagnostics_for_file(path:, scope:, root:)` is the **file-rule** surface — keep it for diagnostics a per-node walk can't express (discovery load-error reporting, cross-file aggregation), not as a legacy node-rule. **`flow_contribution_for` was removed in ADR-52 WD3 (2026-06-11)** — a plugin that still defines it raises `ArgumentError` at load time. Use `dynamic_return` instead: `dynamic_return receivers: ["MyClass"] do |call_node, scope| T end` (add `methods: [...]` to narrow); `receivers:` and `methods:` each accept a callable for sets only known after `#prepare`; `file_methods: ->(path) { names }` handles per-file name sets; `type_specifier methods: [...]` contributes post-return narrowing facts. Map a violation array to diagnostics with `diagnostics_for(violations, path:, node:)` (ADR-60 WD4) rather than a hand-rolled `.map { diagnostic(...) }`.

## Step 2A — Try the macro substrate first

If the target DSL fits one of these shapes, ship a **declarative manifest only** — no walker code is needed.

| If the DSL is… | Substrate tier | Manifest entry | Reference plugin |
| --- | --- | --- | --- |
| `<Class>.<verb>(path) do … end` where the block runs as an instance method on `<Class>` (Sinatra-shape) | **Tier A** | `block_as_methods: [Macro::BlockAsMethod.new(receiver_constraint:, method_names:)]` | [`rigor-sinatra`](../../../../plugins/rigor-sinatra/) |
| `<Class>.<dsl_method>(:sym_a, :sym_b)` where each symbol maps via a bundled registry to a module that gets `include`d (Devise-shape) | **Tier B** | `trait_registries: [Macro::TraitRegistry.new(receiver_constraint:, method_name:, modules_by_symbol:, always_included:)]` | [`rigor-devise`](../../../../plugins/rigor-devise/) |
| `<Class>.<dsl_method>(:name, T)` where the framework `class_eval`s a heredoc interpolating `name` (dry-struct-shape, ActiveStorage-shape) | **Tier C** | `heredoc_templates: [Macro::HeredocTemplate.new(receiver_constraint:, method_name:, symbol_arg_position:, emit:)]` | [`rigor-dry-struct`](../../../../plugins/rigor-dry-struct/) |

`ActiveSupport::Concern.included do ... end` re-targeting is handled automatically by the substrate — a Tier B/C call inside an `included do` block fires on whoever later `include`s the concern, not on the concern module itself.

The substrate floor (per ADR-16 § WD13) is "synthetic methods emit by name, return types degrade to `Dynamic[T]`." Precise return-type promotion via ADR-13's resolver chain is the **ceiling**, deferred to a future slice — declare `returns:` strings in the manifest today, unlock precision later without changes to the plugin gem.

If the DSL fits a substrate tier, skip the rest of this phase and jump to [Phase 5](05-demo.md). The plugin's `lib/rigor/plugin/<id>.rb` is a 20-line manifest declaration — no walker.

## Step 2B — Hand-rolled walker (when the substrate does not fit)

Map the [Phase 1](01-requirements.md) answers to one of the six existing hand-rolled examples. Use the chosen example as the **structural template** — copy the directory layout and adapt the analyser body.

| If the answers look like… | Use template | Why |
| --- | --- | --- |
| Q1=A/B, Q2=A, Q3=A, Q5=C | [`rigor-deprecations`](../../../../examples/rigor-deprecations/) | Smallest possible plugin; pure config-driven rules; ~80 lines. |
| Q1=A, Q2=A, Q3=E, Q5=A/B | [`rigor-lisp-eval`](../../../../examples/rigor-lisp-eval/) | Recursive interpretation of the literal AST argument. |
| Q1=D, Q2=B, Q3=C, Q5=A | [`rigor-units`](../../../../examples/rigor-units/) | Local-variable flow tracking through arithmetic and chained calls. |
| Q1=C/E, Q2=C, Q3=A, Q5=A/B | [`rigor-statesman`](../../../../plugins/rigor-statesman/) | Two-pass DSL analysis — collect declarations, then validate uses. |
| Q1=B, Q2=A/B, Q3=B, Q5=C | [`rigor-pattern`](../../../../examples/rigor-pattern/) | Plugin asks the analyser via `Scope#type_of` + `literal_string_compatible?`; matches against a literal value. |
| Q1=A/B/C, Q2=E, Q3=A/D, Q5=C/D | [`rigor-routes`](../../../../examples/rigor-routes/) | Reads a project file via `IoBoundary` under `TrustPolicy`; caches the parse via `Plugin::Base.producer`. |

If the requirement fits neither the substrate tiers nor the six hand-rolled templates, **stop and ask the user**. The v0.1.x plugin contract may not yet expose what they need; don't invent a workaround. The [per-library survey](../../../../docs/notes/20260515-macro-expansion-library-survey.md) records which Ruby libraries the substrate covers and which fall outside (GraphQL-Ruby is the canonical "schema-graph recorder" case that the substrate does NOT fit).
