# frozen_string_literal: true

require_relative "check_rules/rule_ids"

module Rigor
  module Analysis
    # Single-source-of-truth metadata table for every CheckRule the analyzer ships. Consumed by `rigor
    # explain <rule>` so users can read the same information the docs site eventually publishes without
    # leaving the terminal.
    #
    # Each entry carries:
    #
    # - `id` — canonical rule id (`call.undefined-method`).
    # - `summary` — single-line headline (≤ 80 chars).
    # - `fires_when` — bullet-shaped list of conditions that trigger the rule, in the order a reader can
    #   scan top-to-bottom.
    # - `does_not_fire_when` — explicit list of cases the rule intentionally skips. Useful for "why am I NOT
    #   seeing this diagnostic?" questions.
    # - `suppression` — short note on how to suppress (in-source `# rigor:disable` and the v0.1.2
    #   file-scope variant `# rigor:disable-file`, plus `.rigor.yml` `disable:`, apply to every rule, so
    #   the note covers any rule-specific nuance — e.g. unreachable-branch lives on the dead-branch line,
    #   not the predicate line).
    # - `severity_authored` — Symbol the rule emits with.
    # - `severity_by_profile` — Hash of `:lenient` / `:balanced` / `:strict` to the configured severity per
    #   profile, taken from `Configuration::SeverityProfile::PROFILES`.
    # - `evidence_tier` — `:high` / `:medium` / `:low` (or `nil` for informational helpers), Rigor's own
    #   confidence that a firing is a true positive, derived from the rule's firing gates. `:high` rules
    #   fire only on a concrete, statically- known type with no metaprogramming escape (Rigor's
    #   false-positive discipline has already filtered the uncertain cases); `:medium` rules rest on flow /
    #   inference proofs that inherit a documented FP envelope (loop / mutation / RBS-strictness modelling
    #   gaps); `:low` rules are resolution- or coverage-gap signals where a firing often reflects missing
    #   context rather than a definite bug. The tier routes a consumer's attention (and lets a downstream
    #   classifier promote a `:high` firing without cross-tool corroboration); it never feeds severity —
    #   that stays the `severity_profile:` decision.
    # - `since` — first version the rule shipped in.
    module RuleCatalog # rubocop:disable Metrics/ModuleLength
      # Stable documentation home for a built-in rule. `documentation_url` appends a per-rule fragment that
      # resolves to the rule's anchor in the published diagnostics catalogue; the page itself points at
      # `rigor explain <rule>` as the authoritative per-rule reference. Mirrors the gemspec
      # `documentation_uri` URL scheme (`…/tree/main`).
      DOCUMENTATION_BASE = "https://github.com/rigortype/rigor/blob/main/docs/manual/04-diagnostics.md"

      class Entry < Data.define(:id, :summary, :fires_when, :does_not_fire_when,
                                :suppression, :severity_authored, :severity_by_profile,
                                :evidence_tier, :since)
        def aliases
          CheckRules::LEGACY_RULE_ALIASES.select { |_legacy, canonical| canonical == id }.keys
        end

        # Stable per-rule documentation URL (see {RuleCatalog.documentation_url}).
        def documentation_url
          RuleCatalog.documentation_url(id)
        end

        # Hash-shaped form for `--format=json` consumers. Keys are Strings so the payload is JSON-stable
        # without a transform pass. `evidence_tier` is omitted when nil (informational helpers carry no
        # confidence tier).
        def to_h
          base = {
            "id" => id,
            "aliases" => aliases,
            "summary" => summary,
            "fires_when" => fires_when,
            "does_not_fire_when" => does_not_fire_when,
            "suppression" => suppression,
            "severity_authored" => severity_authored.to_s,
            "severity_by_profile" => severity_by_profile.transform_keys(&:to_s).transform_values(&:to_s),
            "documentation_url" => documentation_url,
            "since" => since
          }
          base["evidence_tier"] = evidence_tier.to_s if evidence_tier
          base
        end
      end

      ENTRIES = {
        CheckRules::RULE_UNDEFINED_METHOD => Entry.new(
          id: CheckRules::RULE_UNDEFINED_METHOD,
          summary: "Method does not exist on the receiver's statically-known class.",
          fires_when: [
            "The call is `receiver.method(...)` with an explicit receiver.",
            "The receiver type resolves to `Type::Nominal` / `Singleton` / `Constant` / `Tuple` / `HashShape`.",
            "The receiver class is RBS-known (declared in the loaded environment).",
            "The user has not declared the method via `def` or recognised `define_method`.",
            "Neither the receiver class nor an ancestor's RBS sig declares the method."
          ],
          does_not_fire_when: [
            "Implicit-self calls (no receiver) — too noisy without per-method RBS for every helper.",
            "Receiver is `Dynamic[T]` / `Top` / `Union` — by definition the method set isn't enumerable.",
            "Receiver class is in the loader but its RBS definition cannot be built (constant aliases)."
          ],
          suppression: "`# rigor:disable call.undefined-method` on the call line, " \
                       "or `disable: [\"call.undefined-method\"]` in `.rigor.yml`.",
          severity_authored: :error,
          severity_by_profile: { lenient: :error, balanced: :error, strict: :error },
          evidence_tier: :high,
          since: "0.0.1"
        ),

        CheckRules::RULE_SELF_UNDEFINED_METHOD => Entry.new(
          id: CheckRules::RULE_SELF_UNDEFINED_METHOD,
          summary: "Implicit-self call resolves to no method on a confidently-closed class.",
          fires_when: [
            "The call is an implicit-self call (no explicit receiver) inside a class body.",
            "The engine's own resolution (RBS dispatch + the user-class ancestor walk) found nothing.",
            "The enclosing class is a STANDALONE project class: no superclass and no `include`/`prepend`.",
            "It defines no `method_missing` and no dynamic `attr_*(*splat)` accessor.",
            "It is not a plugin-declared open receiver (ADR-26)."
          ],
          does_not_fire_when: [
            "The enclosing scope is a `module` (a mixin contract — methods may come from includers).",
            "The class has a superclass or mixes in a module (surface extends beyond this file — a later slice).",
            "`self` is `Dynamic` / top-level (the gradual guarantee), or the method exists via any project signal.",
            "Off in every shipped profile pending the external corpus FP gate — opt in via `severity_overrides:`."
          ],
          suppression: "`# rigor:disable call.self-undefined-method`, or enable/disable via " \
                       "`severity_overrides: { call.self-undefined-method: warning }` in `.rigor.yml`.",
          severity_authored: :warning,
          severity_by_profile: { lenient: :off, balanced: :off, strict: :off },
          # Off by default and metaprogramming-prone — a firing on a class whose real surface the
          # per-class scan cannot enumerate (C-extension, `class << self`, dynamic accessors) is the known
          # FP mode, so a firing is a candidate to review, not a high-confidence bug.
          evidence_tier: :low,
          since: "0.1.17"
        ),

        CheckRules::RULE_UNRESOLVED_TOPLEVEL => Entry.new(
          id: CheckRules::RULE_UNRESOLVED_TOPLEVEL,
          summary: "Top-level implicit-self call resolves against no def, pre_eval: patch, or Kernel method.",
          fires_when: [
            "The call is an implicit-self call (no receiver) at top level (outside any class / module body).",
            "Its name resolves against no same-file top-level `def`.",
            "No ADR-17 `pre_eval:` monkey-patch on `Object` / `Kernel` declares it.",
            "It is not a standard `Kernel` / `Object` private method (`puts`, `require`, `loop`, …)."
          ],
          does_not_fire_when: [
            "The call has an explicit receiver, or sits inside a `def` / `class` / `module` body (ADR-24 WD3 " \
            "stays lenient there).",
            "A project file defines the name via a top-level `def` or an Object/Kernel monkey-patch listed in " \
            "`.rigor.yml`'s `pre_eval:` (ADR-17).",
            "The name is a Kernel/Object method visible in the loaded RBS environment."
          ],
          suppression: "`# rigor:disable call.unresolved-toplevel` on the call line, or list the defining " \
                       "file in `.rigor.yml`'s `pre_eval:` so the analyzer sees the top-level `def` / patch.",
          severity_authored: :warning,
          severity_by_profile: { lenient: :off, balanced: :warning, strict: :error },
          # A firing is frequently a resolution gap — the defining file is not in the analyzed set or
          # injects the method via a metaprogramming patch the analyzer does not see — rather than a
          # definite typo, so it routes to the `pre_eval:` review path.
          evidence_tier: :low,
          since: "0.1.14"
        ),

        CheckRules::RULE_WRONG_ARITY => Entry.new(
          id: CheckRules::RULE_WRONG_ARITY,
          summary: "Call's positional argument count is outside the declared overloads' envelope.",
          fires_when: [
            "Call is `receiver.method(args...)` with explicit receiver + plain positional args.",
            "Receiver class is RBS-known and the method has a definition.",
            "Actual positional count is below the min or above the max across all overloads."
          ],
          does_not_fire_when: [
            "Call uses `*splat`, keyword arguments, block-pass, or forwarded arguments.",
            "Method declares required keyword arguments (caller must pass kwargs the rule doesn't model).",
            "Method has a `*rest` positional parameter (max arity is unbounded)."
          ],
          suppression: "`# rigor:disable call.wrong-arity`.",
          severity_authored: :error,
          severity_by_profile: { lenient: :error, balanced: :error, strict: :error },
          evidence_tier: :high,
          since: "0.0.1"
        ),

        CheckRules::RULE_ARGUMENT_TYPE => Entry.new(
          id: CheckRules::RULE_ARGUMENT_TYPE,
          summary: "Call passes an argument whose type the parameter cannot accept.",
          fires_when: [
            "The parameter type rejects the argument under `accepts(arg, mode: :gradual)`.",
            "Single-overload: no overload accepts the arg class (ADR-64 non-nil channel).",
            "Multi-overload: every overload rejects a pure-`nil` arg (ADR-64 nil channel) " \
            "or every overload rejects a single concrete non-nil arg class (non-nil channel).",
            "Both sides have a non-Dynamic concrete type."
          ],
          does_not_fire_when: [
            "Either the parameter or the argument is `Dynamic[T]`.",
            "The call is a coerce-dispatch operator (`+`, `-`, `*`, `/`, `<`, `>`, …) — " \
            "excluded because the `coerce` protocol makes acceptance undecidable.",
            "Method has `*rest_positionals`, required keywords, or trailing positionals.",
            "The argument type is a union (not a single concrete class)."
          ],
          suppression: "`# rigor:disable call.argument-type-mismatch`.",
          severity_authored: :error,
          severity_by_profile: { lenient: :warning, balanced: :error, strict: :error },
          evidence_tier: :high,
          since: "0.0.2"
        ),

        CheckRules::RULE_NIL_RECEIVER => Entry.new(
          id: CheckRules::RULE_NIL_RECEIVER,
          summary: "Receiver may be nil and the method is not defined on NilClass.",
          fires_when: [
            "Receiver type is `Type::Union` containing `Constant<nil>` (or `nil` from the RBS Optional).",
            "The non-nil branch has the method, but `NilClass` does not.",
            "Call is not safe-navigation (`x&.method`)."
          ],
          does_not_fire_when: [
            "Method exists on every member of the union (including NilClass).",
            "Receiver was narrowed via `return if x.nil?` / similar early-return guard.",
            "Call uses safe-navigation (`x&.method`)."
          ],
          suppression: "`# rigor:disable call.possible-nil-receiver`.",
          severity_authored: :error,
          severity_by_profile: { lenient: :warning, balanced: :error, strict: :error },
          evidence_tier: :high,
          since: "0.0.2"
        ),

        CheckRules::RULE_DUMP_TYPE => Entry.new(
          id: CheckRules::RULE_DUMP_TYPE,
          summary: "`dump_type(expr)` from Rigor::Testing — informational type print.",
          fires_when: [
            "Top-level / DSL-block call to `dump_type(expr)` after `include Rigor::Testing`."
          ],
          does_not_fire_when: [
            "Outside a context that includes Rigor::Testing.",
            "Argument is not a single expression."
          ],
          suppression: "Remove the `dump_type` call (it's a debug helper, not a real diagnostic).",
          severity_authored: :info,
          severity_by_profile: { lenient: :info, balanced: :info, strict: :error },
          # Informational helper, not a correctness finding — no
          # confidence tier applies.
          evidence_tier: nil,
          since: "0.0.1"
        ),

        CheckRules::RULE_ASSERT_TYPE => Entry.new(
          id: CheckRules::RULE_ASSERT_TYPE,
          summary: "`assert_type(\"<expected>\", expr)` from Rigor::Testing — type-equality check.",
          fires_when: [
            "Inferred type's display does not match the asserted string.",
            "Useful in fixture self-assertions (every `spec/integration/fixtures/*.rb` uses it)."
          ],
          does_not_fire_when: [
            "Inferred type matches the assertion exactly."
          ],
          suppression: "Update the assertion to the actual inferred type, or correct the source.",
          severity_authored: :error,
          severity_by_profile: { lenient: :error, balanced: :error, strict: :error },
          evidence_tier: :high,
          since: "0.0.1"
        ),

        CheckRules::RULE_ALWAYS_RAISES => Entry.new(
          id: CheckRules::RULE_ALWAYS_RAISES,
          summary: "Call provably raises (today: Integer division-by-zero).",
          fires_when: [
            "Receiver is `Integer` / `IntegerRange` / `Constant<Integer>`.",
            "Operator is `/` / `%` / `div` / `modulo` / `divmod`.",
            "Argument is a `Constant<Integer>` whose value is exactly zero."
          ],
          does_not_fire_when: [
            "Receiver is Float / Rational (those return Infinity / NaN, not an exception).",
            "Argument is a Union containing zero (\"may raise\" not \"always raises\")."
          ],
          suppression: "`# rigor:disable flow.always-raises`.",
          severity_authored: :error,
          severity_by_profile: { lenient: :warning, balanced: :error, strict: :error },
          evidence_tier: :high,
          since: "0.0.3"
        ),

        CheckRules::RULE_UNREACHABLE_BRANCH => Entry.new(
          id: CheckRules::RULE_UNREACHABLE_BRANCH,
          summary: "An if / unless / ternary's literal predicate makes one branch dead.",
          fires_when: [
            "Predicate is a syntactic literal: `true` / `false` / `nil` / Integer / Float / String / Symbol / Regexp.",
            "The corresponding dead branch carries a non-empty body."
          ],
          does_not_fire_when: [
            "Predicate is an inferred-constant expression (not a literal). The literal-only envelope avoids " \
            "false positives from Rigor's incomplete loop / mutation / RBS-strictness modelling.",
            "The dead branch is empty (no useful location to point at)."
          ],
          suppression: "`# rigor:disable unreachable-branch` on the dead-branch line (the diagnostic " \
                       "points at the dead branch, not the predicate, so the suppression goes there).",
          severity_authored: :warning,
          severity_by_profile: { lenient: :info, balanced: :warning, strict: :error },
          # The literal-only firing envelope makes the deadness provable from syntax alone — no inference
          # uncertainty.
          evidence_tier: :high,
          since: "0.1.2"
        ),

        CheckRules::RULE_ALWAYS_TRUTHY_CONDITION => Entry.new(
          id: CheckRules::RULE_ALWAYS_TRUTHY_CONDITION,
          summary: "An if / unless / ternary predicate's inferred type folds to a constant.",
          fires_when: [
            "Predicate's inferred type is `Type::Constant<true | false | nil | ...>`.",
            "Predicate is NOT a syntactic literal (the literal-only `flow.unreachable-branch` rule covers those)."
          ],
          does_not_fire_when: [
            "Predicate sits inside a `WhileNode` / `UntilNode` / `ForNode` / `BlockNode` ancestor — " \
            "Rigor's mutation tracking through loop bodies is incomplete enough that an inferred " \
            "`Constant<bool>` can be a false positive.",
            "Predicate is a defensive `.nil?` / `.empty?` / `.zero?` / `.any?` / `.none?` / `.all?` / " \
            "`.respond_to?` call — these typically fire when the user is being more cautious than the " \
            "RBS strict-on-returns sig admits.",
            "Predicate folds to a non-Constant type (Union / Nominal / Dynamic / etc.)."
          ],
          suppression: "`# rigor:disable always-truthy-condition` on the predicate line.",
          severity_authored: :warning,
          severity_by_profile: { lenient: :info, balanced: :warning, strict: :error },
          # Rests on inferred-constant folding, which inherits the loop / mutation FP envelope the
          # `does_not_fire_when` guards narrow — true positive in the common case, but not
          # literal-provable like `unreachable-branch`.
          evidence_tier: :medium,
          since: "0.1.2"
        ),

        CheckRules::RULE_UNREACHABLE_CLAUSE => Entry.new(
          id: CheckRules::RULE_UNREACHABLE_CLAUSE,
          summary: "A `case` / `when` clause the flow engine's narrowing proves can never match.",
          fires_when: [
            "The subject is a `case <local>` (`LocalVariableReadNode`), the only shape the engine narrows.",
            "Every `when` condition is a class / module constant (`when String` / `when MyClass`).",
            "The clause's narrowed body subject is `Type::Bot` — disjoint from the subject (`when String` " \
            "over an `Integer`) or already exhausted by an earlier clause (prior-exhaustion)."
          ],
          does_not_fire_when: [
            "The subject's type at case entry is `Dynamic` (disjointness is never provable under gradual " \
            "`Dynamic`, preserving the gradual guarantee) or already `Bot` (dead code, not a clause error).",
            "A `when` condition is not a class / module constant — `when nil`, ranges, regexps, and " \
            "arbitrary expressions are out of the WD1 scope.",
            "The clause sits inside a `WhileNode` / `UntilNode` / `ForNode` / `BlockNode` (mutation tracking " \
            "through those is incomplete), or its body is empty (no useful location)."
          ],
          suppression: "`# rigor:disable unreachable-clause` on the dead-clause body line.",
          severity_authored: :warning,
          # ADR-47 WD4: balanced stays :info (one notch below its `flow.*` siblings' :warning) until the
          # regression-corpus FP gate is green.
          severity_by_profile: { lenient: :info, balanced: :info, strict: :warning },
          # Narrowing-driven proof that inherits the `always-truthy` FP envelope; balanced keeps it `:info`
          # pending the corpus gate.
          evidence_tier: :medium,
          since: "0.1.17"
        ),

        CheckRules::RULE_DEAD_ASSIGNMENT => Entry.new(
          id: CheckRules::RULE_DEAD_ASSIGNMENT,
          summary: "Local variable assigned in a method body but never read.",
          fires_when: [
            "Plain `LocalVariableWriteNode` (not `+=` / `||=` / multi-assign) inside a `DefNode` body.",
            "The target name does not appear as a `LocalVariableReadNode` anywhere in the same body, " \
            "including nested blocks / lambdas.",
            "The write is not the last statement of the body (Ruby's implicit return)."
          ],
          does_not_fire_when: [
            "Top-level / class-body assignments (their reachability spans the file's introspection / require surface).",
            "The target name starts with `_` (Ruby convention for intentionally-unused).",
            "The write is a destructure (`a, b = foo`) or operator-write (`x += 1` / `x ||= 1`).",
            "The write is the last statement of the method body (assignments return their rvalue)."
          ],
          suppression: "`# rigor:disable dead-assignment` on the offending line, or rename the local to `_<name>`.",
          severity_authored: :warning,
          severity_by_profile: { lenient: :info, balanced: :warning, strict: :error },
          # The unread-write proof is reliable, but it flags a code smell rather than a runtime fault, and
          # the syntactic write classification has narrow corners (the `does_not_fire_when` exclusions).
          evidence_tier: :medium,
          since: "0.1.2"
        ),

        CheckRules::RULE_RETURN_TYPE => Entry.new(
          id: CheckRules::RULE_RETURN_TYPE,
          summary: "Method body's last-expression type is incompatible with the declared return type.",
          fires_when: [
            "Method has a `def` body the engine can re-type.",
            "Method's RBS sig declares a non-`untyped` return type.",
            "Body's inferred return type does not flow into the declared type under gradual acceptance.",
            "When the RBS sig carries `%a{rigor:v1:return: <refinement>}` (v0.1.2), the refinement " \
            "carrier — `non-empty-string`, `positive-int`, etc. — replaces the bare RBS class for the " \
            "comparison, so a body the bare class would accept may still fail the refinement."
          ],
          does_not_fire_when: [
            "Method's declared return is `untyped` / `void`.",
            "Body's last expression is `Dynamic[T]` (the engine cannot rule out the declared type)."
          ],
          suppression: "`# rigor:disable def.return-type-mismatch`.",
          severity_authored: :warning,
          severity_by_profile: { lenient: :warning, balanced: :warning, strict: :error },
          # Depends on re-typing the body against an authored RBS return; RBS strict-on-returns plus
          # incomplete body inference makes a firing usually-right but not concrete-call certain.
          evidence_tier: :medium,
          since: "0.1.0"
        ),

        CheckRules::RULE_VISIBILITY_MISMATCH => Entry.new(
          id: CheckRules::RULE_VISIBILITY_MISMATCH,
          summary: "Explicit-receiver call to a method declared `private` in source.",
          fires_when: [
            "Call is `receiver.method(...)` with explicit non-self receiver.",
            "Receiver type resolves to `Type::Nominal[X]`.",
            "X is a user-defined class whose source carries the method under `private`."
          ],
          does_not_fire_when: [
            "Implicit-self call (no receiver) — always allowed for private.",
            "Receiver is `self` (Ruby 2.7+ permits `self.private_method`).",
            "Receiver class is RBS-known but not user-source-defined (RBS-side visibility is deferred).",
            "Method is `:protected` (subclass tracking is deferred)."
          ],
          suppression: "`# rigor:disable method-visibility-mismatch`.",
          severity_authored: :error,
          severity_by_profile: { lenient: :warning, balanced: :error, strict: :error },
          evidence_tier: :high,
          since: "0.1.2"
        ),

        CheckRules::RULE_OVERRIDE_VISIBILITY_REDUCED => Entry.new(
          id: CheckRules::RULE_OVERRIDE_VISIBILITY_REDUCED,
          summary: "Instance-method override reduces the visibility it inherits from an ancestor.",
          fires_when: [
            "An instance `def` shadows a same-name instance method defined by a project-discovered " \
            "ancestor (included/prepended module or superclass, cross-file).",
            "The override's source-discovered visibility is strictly more restrictive than the " \
            "ancestor's (public → protected/private, or protected → private).",
            "Both visibilities are statically observable from project source."
          ],
          does_not_fire_when: [
            "Override raises or preserves visibility (only reductions break substitutability).",
            "The shadowed method lives on an RBS-known / third-party ancestor (RBS models only " \
            "public/private; RBS-parent visibility is a deferred follow-on).",
            "`def self.foo` singleton methods (visibility is instance-side only).",
            "The `private def foo; end` wrap-around form (not yet tracked by the visibility walker)."
          ],
          suppression: "`# rigor:disable def.override-visibility-reduced` on the override.",
          severity_authored: :warning,
          severity_by_profile: { lenient: :off, balanced: :warning, strict: :error },
          # Both the override and the shadowed ancestor visibility are statically observed from project
          # source — the substitutability violation is concrete.
          evidence_tier: :high,
          since: "0.1.15"
        ),

        CheckRules::RULE_OVERRIDE_RETURN_WIDENED => Entry.new(
          id: CheckRules::RULE_OVERRIDE_RETURN_WIDENED,
          summary: "Instance-method override widens the return type it inherits from an ancestor.",
          fires_when: [
            "An instance `def` with an authored RBS signature overrides a same-name method whose " \
            "RBS signature is declared by a project-discovered ancestor (module or superclass).",
            "The override's declared return is not acceptable where the ancestor's declared return " \
            "is expected (`parent_return.accepts(override_return)` is `:no`) — a covariance violation."
          ],
          does_not_fire_when: [
            "Either side lacks an authored RBS signature (WD1 both-sides-authored gate).",
            "The override narrows or preserves the return (covariant-safe).",
            "The ancestor's return is `untyped` / `self` / an unbound generic (degrades to " \
            "`Dynamic[Top]`, which accepts everything — FP-safe).",
            "The subtype relationship between the two return types is not resolvable from loaded " \
            "Ruby classes / their ancestors (a user-only class hierarchy degrades to `:maybe` and " \
            "stays silent — the check has reach over core / stdlib / loadable-gem hierarchies).",
            "`def self.foo` singleton methods (instance-side only in v1).",
            "The shadowed method lives only on an RBS-known / third-party ancestor not in the " \
            "project-discovered chain (user-source ancestor scope in v1)."
          ],
          suppression: "`# rigor:disable def.override-return-widened` on the override.",
          severity_authored: :warning,
          severity_by_profile: { lenient: :off, balanced: :warning, strict: :error },
          # Gated on both-sides-authored RBS and a resolvable subtype relationship, so a firing is a
          # concrete covariance violation.
          evidence_tier: :high,
          since: "0.1.15"
        ),

        CheckRules::RULE_OVERRIDE_PARAM_NARROWED => Entry.new(
          id: CheckRules::RULE_OVERRIDE_PARAM_NARROWED,
          summary: "Instance-method override narrows a parameter type it inherits from an ancestor.",
          fires_when: [
            "An instance `def` with an authored RBS signature overrides a same-name method whose " \
            "RBS signature is declared by a project-discovered ancestor (module or superclass).",
            "At some matching positional parameter index, the override's slot cannot accept the " \
            "ancestor's parameter type (`override_param.accepts(parent_param)` is `:no`) — a " \
            "contravariance violation (the override narrowed the parameter)."
          ],
          does_not_fire_when: [
            "Either side lacks an authored RBS signature (WD1 both-sides-authored gate).",
            "The override widens or preserves the parameter (contravariant-safe).",
            "Either side is overloaded (more than one method type — arm mapping is ambiguous).",
            "The ancestor's parameter is `untyped` / an unbound generic / an interface (degrades " \
            "to `Dynamic[Top]`, which is passable to anything — FP-safe).",
            "The subtype relationship between the two parameter types is not resolvable from loaded " \
            "Ruby classes / their ancestors (a user-only class hierarchy degrades to `:maybe` and " \
            "stays silent — the check has reach over core / stdlib / loadable-gem hierarchies).",
            "Arity / keyword-requiredness divergence (out of scope for v1 — positional types only).",
            "`def self.foo` singleton methods (instance-side only in v1).",
            "The shadowed method lives only on an RBS-known / third-party ancestor (user-source " \
            "ancestor scope in v1)."
          ],
          suppression: "`# rigor:disable def.override-param-narrowed` on the override.",
          severity_authored: :warning,
          severity_by_profile: { lenient: :off, balanced: :warning, strict: :error },
          # Gated on both-sides-authored RBS and a resolvable subtype relationship, so a firing is a
          # concrete contravariance violation.
          evidence_tier: :high,
          since: "0.1.15"
        ),

        CheckRules::RULE_IVAR_WRITE_MISMATCH => Entry.new(
          id: CheckRules::RULE_IVAR_WRITE_MISMATCH,
          summary: "Same instance variable assigned a different concrete class within one class.",
          fires_when: [
            "Two or more `@var = ...` writes occur in instance methods of the same class.",
            "First write's rvalue resolves to a concrete class (Nominal / Singleton / Constant / Tuple → " \
            "\"Array\" / HashShape → \"Hash\").",
            "A later write's rvalue resolves to a different concrete class."
          ],
          does_not_fire_when: [
            "Later write is `nil` — the `@cache = nil` clear-idiom is allowlisted.",
            "Either side is Union / Dynamic / IntegerRange / a shape-varied carrier.",
            "Writes live in different classes that happen to share an ivar name.",
            "Writes are in `def self.foo` (singleton) bodies — those track separately."
          ],
          suppression: "`# rigor:disable ivar-write-mismatch` on the offending write.",
          severity_authored: :error,
          severity_by_profile: { lenient: :warning, balanced: :warning, strict: :error },
          # Both writes resolve to concrete classes before firing; the union / Dynamic / clear-idiom
          # escapes are excluded.
          evidence_tier: :high,
          since: "0.1.2"
        )
      }.freeze

      module_function

      # Looks up a rule by canonical id, legacy alias, or family wildcard. Returns an Array<Entry>:
      #
      # - canonical id → 1-element array,
      # - legacy alias → 1-element array (resolved to canonical),
      # - family token (`call`) → every entry under that family,
      # - unknown token → empty array.
      def resolve(token)
        token = token.to_s
        return [ENTRIES.fetch(token)] if ENTRIES.key?(token)

        if CheckRules::LEGACY_RULE_ALIASES.key?(token)
          canonical = CheckRules::LEGACY_RULE_ALIASES.fetch(token)
          return [ENTRIES.fetch(canonical)]
        end

        if CheckRules::RULE_FAMILIES.include?(token)
          return ENTRIES.values.select { |entry| entry.id.start_with?("#{token}.") }.sort_by(&:id)
        end

        []
      end

      def all
        ENTRIES.values.sort_by(&:id)
      end

      # Rigor's confidence tier (`:high` / `:medium` / `:low`) that a firing of `token` is a true positive,
      # or nil for an informational rule (`dump.type`) or an unknown / non-built-in token (plugin and
      # `rbs_extended.*` rules carry no built-in tier). Resolves legacy aliases. See {Entry}'s
      # `evidence_tier` documentation for the tier semantics.
      def evidence_tier(token)
        entries = resolve(token)
        return nil unless entries.size == 1

        entries.first.evidence_tier
      end

      # Stable documentation URL for `token`, or nil for an unknown / non-built-in token. The URL is the
      # published diagnostics catalogue page anchored at the rule's per-rule anchor
      # (`#rule-<id-with-dots-as-dashes>`); the page itself names `rigor explain <rule>` as the
      # authoritative per-rule reference. Resolves legacy aliases to the canonical id.
      def documentation_url(token)
        entries = resolve(token)
        return nil unless entries.size == 1

        "#{DOCUMENTATION_BASE}##{doc_anchor(entries.first.id)}"
      end

      # The per-rule fragment a `documentation_url` points at: `call.undefined-method` →
      # `rule-call-undefined-method`. The `04-diagnostics.md` catalogue carries the matching `<a id>`
      # anchors.
      def doc_anchor(rule_id)
        "rule-#{rule_id.tr('.', '-')}"
      end
    end
  end
end
