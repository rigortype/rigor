# Appendix — Coming from Steep

[Steep](https://github.com/soutaro/steep) is the established
Ruby static type checker, and the de-facto reference
implementation of RBS-driven analysis. If you have used Steep,
the most important thing to know is that **Rigor reads the
same `.rbs` files** — your existing signatures port over
unchanged. The two tools are complementary, not exclusive.

This appendix is for users who already think in Steep
vocabulary and want to know which Rigor concept matches which
Steep concept.

## The five-second pitch

| Question | Steep | Rigor |
| --- | --- | --- |
| Source of types | `.rbs` files (mandatory at boundaries) | `.rbs` files (optional — inference fills gaps) |
| Annotations in `.rb` | `# @type` comments, type assertions | Almost none — `assert_type` / `dump_type` are introspection helpers |
| Coverage requirement | Steepfile's `check`/`signature` directives demand annotated targets | None — `rigor check lib` works with zero `.rbs` |
| Default for unannotated code | Errors when you ask Steep to check it | Inferred precisely or `Dynamic[Top]` |
| Tool focus | Strong typing on opt-in surface | Best-effort precision on every file |
| Diagnostic philosophy | Surface all type-shape mismatches | Stay silent unless the bug is provable |

If Steep's slogan is "Ruby with optional manifest types,"
Rigor's is "Ruby with proven facts." The two are designed for
overlapping but distinct workflows.

## Both consume RBS — that is the common ground

This is the headline. RBS is Ruby's standard signature
language; both Steep and Rigor read it as their canonical
type source. A `.rbs` file you wrote for Steep works in Rigor
without changes:

```rbs
# sig/slug.rbs
class Slug
  def normalise: (String) -> String
  def self.default_length: () -> Integer
end
```

Steep checks the body of `Slug#normalise` against this sig and
errors when the return type drifts. Rigor checks the same
thing under the `def.return-type-mismatch` rule (Chapter 8).
Both tools agree on the contract.

The tools diverge on what they layer on top:

- **Steep** adds method-body type-checking and a strict
  "every method on the path must have a sig" expectation
  (configurable, but the default).
- **Rigor** adds inference everywhere (so missing sigs
  produce `Dynamic[Top]`, not errors), refinement carriers,
  constant folding, and plugin-side narrowing.

## Type vocabulary — the RBS-level mapping is identity

Because both tools speak RBS, the type vocabulary at the
declaration level is the same:

| RBS form | Steep | Rigor |
| --- | --- | --- |
| `String` | `String` | `Nominal[String]` (display: `String`) |
| `Integer?` | `Integer \| nil` | `Integer \| Constant<nil>` (display: `Integer?`) |
| `Array[Integer]` | `Array[Integer]` | `Array[Integer]` |
| `[Integer, String]` (tuple) | tuple | `Tuple[Integer, String]` |
| `{name: String, age: Integer}` (record) | record | `HashShape{name: String, age: Integer}` |
| `_Comparable` (interface) | structural | structural facet |
| `untyped` | `untyped` | `Dynamic[Top]` (display: `untyped`) |
| `bot` | `bot` | `Bot` |
| `top` | `top` | `Top` |
| `bool` | `bool` | `Constant<true> \| Constant<false>` (display: `bool`) |
| `void` | `void` | `void` |

Rigor's internal type carriers (`Type::Constant`,
`Type::IntegerRange`, `Type::Refined`, `Type::Tuple`,
`Type::HashShape`) do NOT exist in Steep's surface. They are
**erased to the RBS-equivalent** at the boundary, so a method
declared `-> String` in RBS still satisfies its caller's
expectation even if Rigor knows the result is
`non-empty-lowercase-string` internally.

This erasure contract is documented at
[`docs/type-specification/rbs-erasure.md`](../type-specification/rbs-erasure.md).

## Annotations in `.rb` source

Steep recognises a small set of in-source type annotations:

| Steep `.rb` annotation | Rigor equivalent |
| --- | --- |
| `# @type var x: Integer` | (no analogue in core) |
| `# @type self: Foo` | `T.bind(self, Foo)` via `rigor-sorbet` plugin |
| `# @type method foo: () -> String` | RBS file declaration |
| `_ = x` (type cast) | `T.cast(x, T)` via `rigor-sorbet` plugin |

Rigor deliberately does NOT ship in-source annotation comments
in core. The reasoning (ADR-0, ADR-5, robustness principle):

1. **`.rb` files stay clean for runtime developers.** Authors
   who do not care about types do not see type comments.
2. **Annotations belong at the boundary.** Rigor's stance is
   that the public contract lives in `.rbs`, not at every
   variable assignment.
3. **Inference covers most variables.** When `x = some_call`,
   Rigor knows the return type of `some_call` — there is
   nothing to annotate.

When you genuinely want in-source assertions (you are
migrating from Steep or Sorbet, or you have a complex
narrowing the engine cannot follow), the `rigor-sorbet`
plugin is the supported path — see Chapter 10.

## Steepfile vs `.rigor.yml`

| Steep `Steepfile` | Rigor `.rigor.yml` |
| --- | --- |
| `target :lib do ... end` | `paths: [lib]` |
| `check "lib"` | covered by `paths:` |
| `signature "sig"` | `signature_paths: [sig]` (auto-detected when omitted) |
| `library "set", "json"` | `rbs_collection.lock.yaml` (RBS gem-collection) — same mechanism Steep uses |
| `configure_code_diagnostics` | `severity_overrides:`, `severity_profile:` |
| Multiple targets per Steepfile | Multiple `paths:` entries (single profile per project) |

The biggest config difference: Steep's per-target structure
lets you check `lib/` strictly and `app/` permissively in the
same project. Rigor's profile is project-wide, with per-rule
and per-file overrides for granularity.

## Severity model

Both tools have severity controls; the shapes are slightly
different.

| Steep | Rigor |
| --- | --- |
| `configure_code_diagnostics(D::Ruby.strict)` per target | `severity_profile: strict` project-wide |
| `D::Ruby.lenient` / `default` / `strict` / `all_error` | `lenient` / `balanced` / `strict` |
| Per-diagnostic severity in Steepfile | `severity_overrides:` in `.rigor.yml` |
| `D::Ruby::UnknownConstant = :error` | `severity_overrides: { call.undefined-method: error }` |

The rule identifiers do not align 1:1 — Steep's are class
names, Rigor's are dotted families. The conceptual model is
the same: a default level, plus per-rule promotion / demotion.

## Diagnostic vocabulary

Steep's diagnostic catalogue and Rigor's overlap for the same
underlying conditions, but the names differ.

| Steep | Rigor |
| --- | --- |
| `Ruby::NoMethod` | `call.undefined-method` |
| `Ruby::ArgumentTypeMismatch` | `call.argument-type-mismatch` |
| `Ruby::IncompatibleAssignment` | (covered by `def.ivar-write-mismatch` for instance variables; locals are not flagged) |
| `Ruby::MethodBodyTypeMismatch` | `def.return-type-mismatch` |
| `Ruby::UnknownConstant` | (covered by `call.undefined-method` against the receiver class) |
| `Ruby::UnexpectedKeywordArgument` | `call.argument-type-mismatch` (keyword binding flows through the same rule) |
| `Ruby::IncompatibleTypeCase` | (no direct analogue today) |

A practical implication: a project that runs both Steep and
Rigor will see overlapping diagnostics on shape errors and
complementary diagnostics on the things each tool catches that
the other does not. The
[`docs/notes/20260503-steep-cross-check-triage.md`](../notes/20260503-steep-cross-check-triage.md)
note is a worked example — Steep and Rigor were run against
the same project and the diagnostic streams categorised.

## Suppression

| Steep | Rigor |
| --- | --- |
| `# steep:ignore` | `# rigor:disable all` |
| `# steep:ignore Ruby::NoMethod` | `# rigor:disable call.undefined-method` |
| (no file-scope syntax) | `# rigor:disable-file <rule>` |
| `Steepfile`: per-target `ignore_paths:` | `.rigor.yml`: `disabled_rules:` (rule-scoped) |

Rigor's suppression vocabulary is closer to PHPStan's and
RuboCop's than to Steep's, but the intent matches.

## "No annotations needed" — the largest practical difference

Steep, by default, expects every method on the checked path
to have an RBS sig (or to opt out via `# @type` annotations).
Running `steep check` on a project with no `sig/` directory
produces lots of "missing sig" reports.

Rigor, by default, infers what it can and stays silent when it
cannot. Running `rigor check lib` on a project with no `sig/`
directory produces a small number of high-confidence
diagnostics — the methods Rigor was able to prove unsound from
the body alone.

This is by design (ADR-0). The two tools serve different
adoption stages:

- **Greenfield, type-discipline-from-day-one project.** Steep
  is excellent. Write the RBS first; check the body against
  it.
- **Existing codebase, gradual hardening.** Rigor is excellent.
  Start with zero `.rbs`, get diagnostics on the worst bugs
  immediately, add `.rbs` only where inference cannot see far
  enough.
- **Both at once.** Run them side by side. They share input
  (the same RBS). Steep's diagnostic stream and Rigor's
  diagnostic stream complement each other.

## What Steep has and Rigor does not

- **`@type` comments in source.** Whatever your stance on
  in-source annotations, Steep ships a richer surface for
  them. `# @type var x: Integer`, `# @type self: Foo`, and
  the `_ = x` cast operator have no Rigor-core equivalent.
  The `rigor-sorbet` plugin fills the gap (Chapter 10).
- **Method-body type checking against declared params.** Steep
  enforces "every reference to parameter `x` inside the body
  agrees with the declared `x: Integer`." Rigor's analogous
  check is `def.return-type-mismatch`; the parameter-side check
  is comparable but more conservative (RBS-erased view).
- **Tighter generics inference.** Steep's generic instantiation
  in chained calls is more aggressive than Rigor's today.
- **Diagnostic taxonomy maturity.** Steep's diagnostic
  catalogue has had more years to settle; Rigor's is smaller
  and growing.

## What Rigor has and Steep does not

- **Inference without RBS.** A `lib/` directory with zero
  `.rbs` files produces useful Rigor output. Steep needs sigs.
- **Refinement carriers with automatic narrowing.**
  `non-empty-string` from `unless s.empty?`, `positive-int`
  from `n > 0`, etc.
- **Constant folding through method calls.** `"foo".upcase`
  resolves to `Constant<"FOO">`, not just `String`. Steep's
  literal types are narrower than Rigor's.
- **Plugin-side return-type contributions.** Steep does not
  have an equivalent to Rigor's `flow_contribution_for` —
  if a domain DSL's return type depends on the literal first
  argument, Rigor models it; Steep does not.
- **Sorbet-input adapter.** A `rigor-sorbet` migration is
  zero-cost for projects mid-Sorbet (`sig { ... }` blocks and
  RBI files become inputs to Rigor's catalog). Steep does not
  read Sorbet sigs.
- **Cache-driven incremental analysis.** Rigor's per-file
  cache survives across runs and across machine boundaries
  (ADR-6). Steep's incremental story is improving but not
  yet at parity.

## A coexistence pattern

A common, low-friction setup for a project that wants both
checkers:

```yaml
# .rigor.yml
paths: [lib]
severity_profile: balanced
# signature_paths is auto-detected; sig/ is shared with Steep
```

```ruby
# Steepfile
target :lib do
  check "lib"
  signature "sig"
  configure_code_diagnostics D::Ruby.default
end
```

Both tools read the same `sig/`. CI runs `steep check` and
`bundle exec rigor check lib` as separate steps. Each tool's
output goes to its own annotation channel. When they disagree
on the same line, the standing rule is: **if Steep flags it
and Rigor does not, investigate**. Steep tends to surface sig
drift that Rigor's RBS-erasure consciously absorbs; Rigor
tends to surface body-level facts that Steep does not check.

## A migration vignette

Suppose you maintain a project that has been on Steep for two
years. The `sig/` tree is comprehensive; `# @type` annotations
appear in a handful of files where inference fell short. You
want to add Rigor without uprooting anything.

Steps:

1. **Add Rigor as a dev dependency.** No changes to `sig/`.
2. **Run `bundle exec rigor check lib` once.** You will see a
   small number of new diagnostics — typically narrowing-aware
   findings Steep does not produce (`flow.always-truthy-condition`,
   `def.return-type-mismatch` against an `RBS::Extended`-tightened
   return). Triage as bugs vs noise.
3. **Decide what to do with `# @type` annotations.** Rigor
   ignores them (they are comments to the parser). Two
   options:
   a. Leave them — Steep keeps using them, Rigor ignores
      them. No-op coexistence.
   b. Convert to `T.let` / `T.cast` from the `rigor-sorbet`
      plugin if you want Rigor to honour the assertion as
      well.
4. **Add Rigor to CI.** Both checkers run; both gates must
   pass before merge.
5. **Optionally tighten existing sigs with `RBS::Extended`.**
   Steep treats `%a{rigor:v1:...}` as ordinary RBS comments;
   Rigor treats them as refinement directives. The same
   `.rbs` file produces stricter Rigor output and unchanged
   Steep output.

The migration is genuinely low-friction because the
foundational assumption (RBS as the contract language) is
shared.

## What's next

You probably do not need to read the rest of this appendix
section sequentially. Three useful pointers:

- [Chapter 7 — RBS and `RBS::Extended`](07-rbs-and-extended.md)
  if you want to see how the directive grammar layers on top
  of the RBS you already write.
- [Chapter 8 — Understanding errors](08-understanding-errors.md)
  for the rule catalogue, severity profiles, and baseline
  diffing — the analogue to Steep's diagnostic config.
- [`docs/notes/20260503-steep-cross-check-triage.md`](../notes/20260503-steep-cross-check-triage.md)
  for a worked side-by-side run of Steep and Rigor on the
  same project (the project itself).

If you want to compare against another tool, the sibling
appendix pages cover [TypeScript](appendix-typescript.md),
[PHPStan](appendix-phpstan.md), and [mypy](appendix-mypy.md).
