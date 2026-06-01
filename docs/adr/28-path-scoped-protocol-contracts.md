# ADR-28 — Path-scoped method-protocol contracts

Status: **Accepted, 2026-05-23; implemented in the same commit
cluster (commits 481d810, a54cd2d).**

Records the decision to add a
plugin extension point that lets a plugin make a *behavioural*
protocol — "every class in this directory must define a method
of this shape" — statically enforceable, without the class
opting in. The mechanism is a new `Manifest` field
(`protocol_contracts:`) carrying `Rigor::Plugin::ProtocolContract`
value objects, consumed at two engine sites: parameter-type
**provision** in `Inference::MethodParameterBinder` and method
presence + return-type **check** in the contributing plugin's
`#diagnostics_for_file` hook. Two worked consumers ship:
`examples/rigor-web/` (RigWeb framework tutorial) and
`plugins/rigor-hanami/` (production Hanami plugin).

## Context

Ruby frameworks routinely impose *behavioural* protocols that no
class declaration records. A Rack-shaped web framework expects a
controller action to take a `Rack::Request` and return a
`Rack::Response`; a job framework expects `#perform`; a
serializer expects `#call`. The convention is real, but it lives
in the framework's prose, not in the source of the conforming
class — so nothing checks it, and a violation is found at
runtime.

Rigor's plugin contract, before this ADR, gives a plugin three
ways to react to a project:

- `flow_contribution_for(call_node:, scope:)` — per *call site*.
- `diagnostics_for_file(path:, scope:, root:)` — per *file*,
  **after** inference; the plugin walks the AST itself.
- macro-substrate manifest declarations (ADR-16) — Tier A
  (`block_as_methods`) narrows the `self` of a *block* passed to
  a class-level DSL call; Tiers B–D synthesise methods.

None of these expresses "a class defined under path glob G
implicitly carries protocol P." Two capabilities are missing:

1. **A directory → protocol binding.** No manifest mechanism
   targets *classes by the path of the file that defines them*.
2. **Parameter-type provision into a plain `def`.** This is the
   sharp gap. A controller's `def get(request)` has no RBS, so
   the engine binds `request` to `Dynamic[Top]` — and a
   `Dynamic[Top]` receiver answers every method, so neither a
   misuse inside the body nor an imprecise return type surfaces.
   The existing ways to give a parameter a type all fall short:
   `%a{rigor:v1:param:}` (RBS::Extended) requires the method to
   be **RBS-declared**; macro Tier A narrows a **block**'s
   `self`, not a `def`'s parameter; an RBS interface
   (`_Controller`) is not *implicitly* bound to a class — RBS has
   no "every class under this directory implements this
   interface" form.

A plugin *can* already check a return type by hand in
`diagnostics_for_file` (walk to the `def`, `Scope#type_of` the
body). But without (2), that check is near-worthless: with
`request` typed `Dynamic[Top]`, any return expression built from
the request is itself `Dynamic[Top]`, which conforms to
everything. Provision is the load-bearing half.

## Decision

Add `protocol_contracts:` to the plugin `Manifest`. Each entry is
a frozen `Rigor::Plugin::ProtocolContract` value object naming:

- `path_glob` — a `File.fnmatch` glob (project-root-relative,
  e.g. `lib/controller/**/*.rb`) selecting the files the contract
  applies to;
- `method_name` + `singleton` — the method every class in those
  files must define;
- `param_types` — positional `index → type-name` provisions;
- `return_type_name` — the type the method's body must conform
  to;
- `severity` — the violation diagnostic severity.

The contract is consumed at two sites — **provide-and-check**:

- **provide** (engine-side). `Inference::MethodParameterBinder`
  gains a tier, applied last (most authoritative) and regardless
  of RBS presence: when the `def` being bound matches a contract
  for its file, the contract's `param_types` replace the bound
  parameter types. The method body is then analysed as if the
  parameter carried its protocol type — so a misuse
  (`request.no_such_method`) surfaces as an ordinary core
  diagnostic, and the body's inferred return type is precise.
- **check** (plugin-side). The contributing plugin's
  `#diagnostics_for_file` confirms each class in a matching file
  defines the method (else `missing-protocol-method`) and that
  its inferred return type conforms to `return_type_name` (else
  `protocol-return-mismatch`).

## Working decisions

**WD1 — a `Manifest` field, not a `.rigor.yml` config key.** A
protocol contract is a property of the *plugin* that knows the
framework, not of the analysed project. It joins the existing
declarative manifest fields (`owns_receivers`, `open_receivers`,
`block_as_methods`, …). The per-project lever is config
*override* of the convention path (WD5), not config *authorship*
of the contract.

**WD2 — provide-and-check, not check-only.** Provision is the
half that makes the feature worth shipping (see Context (2)). It
must be engine-side because it precedes inference; check-only
would leave controller bodies typed against `Dynamic[Top]` and
the return check vacuous.

**WD3 — the contract is the top precedence tier in the binder.**
Order: `Dynamic[Top]` fallback → RBS overloads → RBS::Extended
`param:` override → **protocol contract**. A class that *also*
carries an RBS signature for the contracted method has its
parameter types overridden by the contract. This is intended —
the contract is the framework-author's enforced requirement —
and is the documented behaviour of the field.

**WD4 — the engine provides; the plugin checks.** Parameter
provision is the *only* engine-side change; it must precede
inference, so it cannot live in a plugin hook. Method-presence
and return-type checks run after inference and are left to the
plugin's `#diagnostics_for_file` — `Analysis::CheckRules` is the
engine's fixed rule catalogue and stays free of plugin concepts.
The plugin re-binds the contract's parameter types onto its query
scope so `Scope#type_of` types the body identically to the
engine's own inference.

**WD5 — manifest-declared default path, per-project override.**
The manifest carries the convention `path_glob`
(`lib/controller/**/*.rb`). A plugin MAY override
`Plugin::Base#protocol_contracts` — the same indirection
`#signature_paths` uses — to fold a per-project `config` value
into the contract set (e.g. retarget to `app/controllers/`). The
manifest stays config-unaware; the instance method is where
config enters.

**WD6 — silent on `Dynamic[Top]`.** When the engine cannot pin
a contracted method's return type down, the check stays silent.
Per the project's false-positive discipline, an uncertain return
is deferred to runtime rather than flagged.

**WD7 — fail-soft on unresolvable type names.** `param_types` /
`return_type_name` are carried as Strings and resolved against
the analysed project's environment lazily. An unresolvable name
(the protocol's RBS not loaded) drops the provision / skips the
check rather than raising — consistent with the binder's
existing fail-soft posture. A plugin shipping its own RBS for the
protocol types via `signature_paths:` (ADR-25) makes resolution
reliable.

**WD8 — additive to the pre-1.0 plugin contract.** A new optional
manifest field and a new optional `MethodParameterBinder`
constructor keyword (`source_path:`, defaulting to `nil`). No
existing plugin or caller breaks; safe in v0.1.x.

## Engine surface

- `lib/rigor/plugin/protocol_contract.rb` — the `ProtocolContract`
  value object (+ nested `ParamType`).
- `lib/rigor/plugin/manifest.rb` — the `protocol_contracts:`
  field.
- `lib/rigor/plugin/base.rb` — `#protocol_contracts` instance
  method (manifest-backed, override-friendly per WD5).
- `lib/rigor/plugin/registry.rb` — `#protocol_contracts`
  aggregator + `#contracts_for_path` glob lookup.
- `lib/rigor/inference/method_parameter_binder.rb` — the
  `apply_protocol_contract` provision tier; constructor gains
  `source_path:`.
- `lib/rigor/inference/statement_evaluator.rb` — threads
  `scope.source_path` into the binder; `build_fresh_body_scope`
  carries `source_path` through body-scope derivation (it was
  previously dropped, which would also have starved
  `flow_contribution_for`'s file-resolution for nested scopes).

## Consequences

- A framework plugin can enforce a controller / job / serializer
  protocol with no opt-in on the conforming class.
- Controller-style bodies gain real inference: the provided
  parameter type turns the whole body into checkable code.
- Two consumers shipped together: `examples/rigor-web/` (the RigWeb
  framework tutorial — the minimal reference consumer) and
  `plugins/rigor-hanami/` (production use: Hanami 2 action classes
  under `app/actions/` enforcing the `#handle(request) -> response`
  protocol).

## Rejected / deferred alternatives

- **An RBS interface implicitly bound by directory.** RBS has no
  "every class under path G implements interface I" form, and
  inventing one would push the binding into the type language
  (ADR-0 / ADR-1 keep core RBS-canonical). The contract stays a
  plugin-side declaration.
- **Check-only (no engine change).** Rejected per WD2 — vacuous
  without provision.
- **Provision via synthetic RBS injected per matching class.**
  Would let the existing `def.return-type-mismatch` rule do the
  check half for free, but injecting per-file synthetic RBS into
  the shared environment is a heavier, less predictable change
  than a binder tier. Deferred unless a second consumer wants it.
- **A general structural "class implements interface" check
  rule.** A larger feature (a first-class `Rigor::Type::Interface`
  carrier, a conformance diagnostic) — out of scope here; the
  contract covers the concrete need.
