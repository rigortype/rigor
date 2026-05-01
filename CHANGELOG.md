# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.0.2] - 2026-05-01

The second preview. v0.0.2 closes the must-have envelope around the
v0.0.1 pipeline: a richer `RBS::Extended` directive surface
(`assert` / `assert-if-true` / `assert-if-false`, `~T` negation,
`target: self`), inter-procedural inference for user-defined
methods, an `argument-type-mismatch` rule, per-rule diagnostic
suppression (project-level + in-source comments),
configuration passthrough for stdlib libraries and signature
paths, and a `--explain` mode that surfaces fail-soft fallback
events.

### Added

- **`rigor check --explain` mode.** Surfaces fail-soft inference
  fallbacks as `:info` diagnostics so users can see where the
  engine degraded to `Dynamic[Top]`. Driven by
  `Rigor::Inference::CoverageScanner` so each event is attributable
  to the leaf node that triggered it (pass-through wrappers like
  `ProgramNode` / `StatementsNode` / `ParenthesesNode` are not
  double-counted). Each diagnostic carries `rule: "fallback"`,
  `severity: :info`, and a short message naming the node class
  and the type the engine fell back to. Info diagnostics do not
  fail the run.

- **`.rigor.yml` `libraries:` and `signature_paths:` keys.** The
  configuration layer now passes through to
  `Rigor::Environment.for_project`:
  - `libraries:` lists stdlib libraries to load on top of
    `Environment::DEFAULT_LIBRARIES` (e.g. `["csv", "set"]`). Each
    entry must be a name accepted by
    `RBS::EnvironmentLoader#has_library?`; unknown libraries
    fail-soft.
  - `signature_paths:` is an explicit list of `sig/`-style
    directories. Leaving the key unset (or `null`) preserves the
    auto-detect-`<root>/sig` default; `[]` disables project-RBS
    loading entirely.

  Wired through `rigor check`, `rigor type-of`, and `rigor type-scan`
  (the latter two gain a `--config=PATH` option matching `check`).

- **Per-rule diagnostic suppression.** Two mechanisms compose:
  - **Project-level**: `.rigor.yml`'s new `disable:` key
    accepts a list of `rigor check` rule identifiers
    (`undefined-method`, `wrong-arity`,
    `argument-type-mismatch`, `possible-nil-receiver`,
    `dump-type`, `assert-type`); matching diagnostics are
    silenced project-wide.
  - **In-source**: `# rigor:disable <rule>` (or
    `<rule1>, <rule2>`) at the end of an offending line
    silences per-line. `# rigor:disable all` suppresses
    every rule on that line.

  `Rigor::Analysis::Diagnostic` gains a `rule:` field
  carrying the source rule's stable identifier. Parse
  errors / path errors / internal analyzer errors leave
  `rule` as `nil` and stay unsuppressible.

- **Inter-procedural inference for user-defined methods.**
  When a call's receiver is `Nominal[T]` for a user-defined
  class without an RBS sig and the method has been
  discovered as an instance `def`, the engine re-types the
  method's body at the call site with the call's argument
  types bound to the parameters and returns the body's
  last-expression type. The `user_methods.rb` integration
  fixture now resolves `Parity.new.is_odd(3)` to
  `false | true` (was `Dynamic[top]` in v0.0.1) without
  requiring an RBS sig.

  First iteration accepts only the simplest parameter shape
  (required positionals, no optionals / rest / keywords /
  block params); receiver must be `Nominal` (not Singleton);
  recursion is guarded by a per-thread inference stack so
  mutually recursive helpers fall back to `Dynamic[Top]`
  rather than infinite-looping.

- `rigor check` ships an **argument-type-mismatch** rule. For
  every explicit-receiver `Prism::CallNode` whose method has
  exactly one RBS overload (no `rest_positionals`, no
  required keywords, no trailing positionals), the rule
  routes each positional argument's inferred type through
  `Rigor::Inference::Acceptance.accepts(parameter, argument,
  mode: :gradual)` and emits an `:error` for the first
  argument the parameter does not accept. Argument or
  parameter types known only as `Dynamic` skip the check
  (the call cannot be statically refuted). The receiver
  must be `Nominal` / `Singleton` / `Constant`; user-class
  fallback / shape carriers behave as in the wrong-arity
  rule. The rule respects RBS even when the user has both a
  `def` and a sig: the sig is the authoritative parameter
  contract.

- `Rigor::Inference::Acceptance` now treats `Singleton[T]`
  as a subtype of `Module`, `Class`, `Object`, and
  `BasicObject`. Without this rule a method whose parameter
  is typed `Class | Module` (e.g. `Object#is_a?`,
  `Module#define_method`) rejected every singleton receiver,
  producing systemic false positives across both `lib/` and
  `spec/`.

- `RBS::Extended` `target: self` directives now actually
  narrow the receiver local on the matching edge (was: parser
  accepted but engine discarded). Covers all three rule
  shapes:
  - `predicate-if-true self is LoggedInUser` /
    `predicate-if-false self is User` — narrows the receiver
    local on the truthy / falsey edge of an `if` / `unless`
    predicate.
  - `assert-if-true self is AdminUser` — same shape, applied
    when the call is observed as a truthy predicate.
  - `assert self is RegisteredUser` — narrows the receiver
    local unconditionally at the post-call scope.

  Narrowing only fires when the call's receiver is a
  `Prism::LocalVariableReadNode` (the engine's narrowing
  surface) AND the receiver type is statically known
  (Nominal / Singleton / Constant — required for the engine
  to even resolve which class's method carries the
  annotation).

- `RBS::Extended` recognises **negation** in predicate / assert
  directives via the `~ClassName` syntax:
  - `predicate-if-true value is ~NilClass` narrows `value`
    AWAY from `NilClass` on the truthy edge.
  - `assert value is ~NilClass` narrows `value` AWAY from
    `NilClass` in the post-call scope.

  `Rigor::RbsExtended::PredicateEffect#negative?` and
  `AssertEffect#negative?` are new boolean predicates; the
  parser sets them when the directive's type literal starts
  with `~`. The engine routes negative effects through
  `Narrowing.narrow_not_class` instead of `narrow_class` so
  the union loses the named class on the active edge.

- `RBS::Extended` recognises three additional directives:
  - `rigor:v1:assert <target> is <Class>` — refines the
    matching argument's local in the post-call scope
    unconditionally. Wires through
    `StatementEvaluator#eval_call`.
  - `rigor:v1:assert-if-true <target> is <Class>` — refines
    the argument when the call is observed as a truthy
    predicate (e.g. `if call_node`). Wires through
    `Narrowing.predicate_scopes` alongside `predicate-if-*`.
  - `rigor:v1:assert-if-false <target> is <Class>` —
    symmetric for falsey.

  The three directives complement `predicate-if-true` /
  `predicate-if-false` — together they cover the
  `must_be_string!` / `validate!` / `valid_string?` /
  `integer?` patterns common in Ruby. `Rigor::RbsExtended::AssertEffect`
  is the new data class returned by
  `RbsExtended.read_assert_effects(method_def)`.

- `Rigor::Environment::DEFAULT_LIBRARIES` now includes
  `tmpdir`, `stringio`, `forwardable`, `digest`, and
  `securerandom`. Common stdlib calls
  (`Dir.mktmpdir`, `StringIO.new`, `Forwardable#def_delegator`,
  `Digest::SHA256.hexdigest`, `SecureRandom.hex`) resolve
  through their RBS sigs without the user having to enumerate
  the libraries themselves.

### Changed

- `Rigor::Analysis::CheckRules` `dump_type` / `assert_type`
  rules are suppressed when the call site's `self_type` is
  `Rigor` or `Rigor::Testing`. The reflexive
  `Testing.dump_type(value)` / `Testing.assert_type(...)` calls
  inside Rigor's own stub no longer surface diagnostics on
  `rigor check lib`.

## [0.0.1] - 2026-05-01

The first preview release. Rigor can be pointed at a real Ruby
project, infer types end-to-end through a flow-sensitive scope,
and emit diagnostics for a small but practical rule catalogue.

The gem is published to RubyGems as **`rigortype`** (the
`rigor` name was already taken). The Ruby module name remains
`Rigor`, so user code uses `require "rigor"` and references
`Rigor::Scope`, `Rigor::Testing`, etc. — only the
`gem install` / `Gemfile` line uses `rigortype`.

### Added

- **`rigor check` end-to-end pipeline.** Parses Ruby through
  Prism, builds a per-node scope index, and runs a three-rule
  catalogue against it:
  - undefined method on a typed receiver,
  - wrong number of positional arguments,
  - possible nil receiver (with safe-navigation and
    early-return narrowing exclusions).
  False positives on reopened classes, `define_method`-defined
  methods, constant-decl-aliased classes (`YAML` → `Psych`),
  and dynamic / unknown receivers are suppressed.
- **`rigor type-of FILE:LINE:COL`** — probes the inferred
  type at any source position.
- **`rigor type-scan PATH...`** — coverage report over a tree.
- **`rigor init`** — writes a header-commented `.rigor.yml`.
- **Type model.** `Top`, `Bot`, `Dynamic[T]`, `Constant[v]`,
  `Nominal[Class, type_args]`, `Singleton[Class]`,
  `Union[A, B, ...]`, `Tuple[T1, ..., Tn]`, and `HashShape`
  carriers with required / optional / read-only key
  policies. `Trinary` (`yes`/`no`/`maybe`) and
  `AcceptsResult`.
- **Inference engine.** Local, instance, class, and global
  variable bindings tracked through `Rigor::Scope`.
  Cross-method ivar / cvar accumulators populated by a
  `ScopeIndexer` pre-pass; program-wide globals.
- **Compound writes** (`||=`, `&&=`, `+=`, `-=`, `*=`, ...)
  thread through scope for every variable kind, with
  operator dispatch via `MethodDispatcher`.
- **`self` typing.** Class- and method-body boundaries inject
  `Singleton[T]` / `Nominal[T]`; implicit-self call dispatch
  routes through the enclosing class's RBS.
- **Lexical constant lookup.** Project sig, RBS-core, common
  stdlib bundle (pathname, optparse, json, yaml, fileutils,
  tempfile, uri, logger, date, prism, rbs), in-source class
  discovery, and in-source constant value tracking.
- **Predicate narrowing.** Truthiness, `nil?`, `is_a?` /
  `kind_of?` / `instance_of?`, finite-literal equality,
  case-equality (`===`) for Class / Module / Range / Regexp,
  and `case` / `when` integration.
- **Block parameter binding** including destructuring
  (`|(a, b), c|`) and numbered parameters (`_1`, `_2`, ...).
  Block-return-type uplift through generic methods so
  `[1, 2, 3].map { |n| n.to_s }` resolves to `Array[String]`.
- **Closure escape analysis.** A core-and-stdlib catalogue of
  block-accepting methods is classified as `:non_escaping`
  (Array#each / map / select / ...), `:escaping`
  (Module#define_method, Thread.new, Proc.new, ...), or
  `:unknown`. Escaping calls drop narrowed types of captured
  outer locals the block can rebind and record a
  `closure_escape` fact in the FactStore.
- **`RBS::Extended` predicate effects.** Methods whose RBS
  signature carries `%a{rigor:v1:predicate-if-true target is T}`
  / `predicate-if-false` annotations narrow the matching
  argument on the corresponding edge.
- **PHPStan-style typing helpers.** `Rigor::Testing.dump_type`
  surfaces the inferred type as an `:info` diagnostic;
  `Rigor::Testing.assert_type("expected", value)` errors when
  the inferred type's short description does not match. Use
  in fixtures to make them self-asserting.
- **Self-asserting integration suite.** Fixture-driven
  examples under `spec/integration/fixtures/` covering
  parity / case-when / compound writes / is_a? narrowing /
  Tuple and HashShape access / Array#map block-return uplift
  / early-return narrowing / RBS::Extended predicates /
  user-defined method dispatch.

### Known limitations (deferred to v0.0.2)

- Inter-procedural inference for user-defined methods. A
  helper like `def is_odd(n) = n.odd?` types correctly inside
  the def, but the caller observes `Dynamic[top]` until an
  RBS sig is supplied. The `spec/integration/fixtures/user_methods*`
  pair pins both shapes (no sig vs project sig).
- `RBS::Extended` ships only the predicate-effect surface.
  `assert` / `assert-if-true` / `assert-if-false`, negation
  (`~T`), self-targeted narrowing, intersection / union
  refinements, `param` / `return` / `conforms-to` directives
  are deferred.
- No persistent cache — every `rigor check` run re-parses
  and re-types the project.
- No plugin contribution layer past the bundled
  `RBS::Extended` reader.
- Per-rule severity is hard-coded to `:error` (with `:info`
  reserved for `dump_type`); per-rule configuration and
  suppression comments are deferred.

[Unreleased]: https://github.com/rigortype/rigor/compare/v0.0.2...HEAD
[0.0.2]: https://github.com/rigortype/rigor/compare/v0.0.1...v0.0.2
[0.0.1]: https://github.com/rigortype/rigor/releases/tag/v0.0.1
