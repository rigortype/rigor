# frozen_string_literal: true

require_relative "check_rules"

module Rigor
  module Analysis
    # Single-source-of-truth metadata table for every CheckRule
    # the analyzer ships. Consumed by `rigor explain <rule>` so
    # users can read the same information the docs site eventually
    # publishes without leaving the terminal.
    #
    # Each entry carries:
    #
    # - `id` — canonical rule id (`call.undefined-method`).
    # - `summary` — single-line headline (≤ 80 chars).
    # - `fires_when` — bullet-shaped list of conditions that
    #   trigger the rule, in the order a reader can scan
    #   top-to-bottom.
    # - `does_not_fire_when` — explicit list of cases the rule
    #   intentionally skips. Useful for "why am I NOT seeing
    #   this diagnostic?" questions.
    # - `suppression` — short note on how to suppress (in-source
    #   `# rigor:disable` and the v0.1.2 file-scope variant
    #   `# rigor:disable-file`, plus `.rigor.yml` `disable:`,
    #   apply to every rule, so the note covers any rule-specific
    #   nuance — e.g. unreachable-branch lives on the dead-branch
    #   line, not the predicate line).
    # - `severity_authored` — Symbol the rule emits with.
    # - `severity_by_profile` — Hash of `:lenient` / `:balanced`
    #   / `:strict` to the configured severity per profile, taken
    #   from `Configuration::SeverityProfile::PROFILES`.
    # - `since` — first version the rule shipped in.
    module RuleCatalog # rubocop:disable Metrics/ModuleLength
      Entry = Data.define(:id, :summary, :fires_when, :does_not_fire_when,
                          :suppression, :severity_authored, :severity_by_profile, :since) do
        def aliases
          CheckRules::LEGACY_RULE_ALIASES.select { |_legacy, canonical| canonical == id }.keys
        end

        # Hash-shaped form for `--format=json` consumers. Keys are
        # Strings so the payload is JSON-stable without a transform
        # pass.
        def to_h
          {
            "id" => id,
            "aliases" => aliases,
            "summary" => summary,
            "fires_when" => fires_when,
            "does_not_fire_when" => does_not_fire_when,
            "suppression" => suppression,
            "severity_authored" => severity_authored.to_s,
            "severity_by_profile" => severity_by_profile.transform_keys(&:to_s).transform_values(&:to_s),
            "since" => since
          }
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
          since: "0.0.1"
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
          since: "0.0.1"
        ),

        CheckRules::RULE_ARGUMENT_TYPE => Entry.new(
          id: CheckRules::RULE_ARGUMENT_TYPE,
          summary: "Call passes an argument whose type the parameter cannot accept.",
          fires_when: [
            "The parameter type rejects the argument under `accepts(arg, mode: :gradual)`.",
            "Method has a single overload (multi-overload checking is deferred).",
            "Both sides have a non-Dynamic concrete type."
          ],
          does_not_fire_when: [
            "Either the parameter or the argument is `Dynamic[T]`.",
            "Method has multiple overloads.",
            "Method has `*rest_positionals`, required keywords, or trailing positionals."
          ],
          suppression: "`# rigor:disable call.argument-type-mismatch`.",
          severity_authored: :error,
          severity_by_profile: { lenient: :warning, balanced: :error, strict: :error },
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
          since: "0.1.2"
        ),

        CheckRules::RULE_RETURN_TYPE => Entry.new(
          id: CheckRules::RULE_RETURN_TYPE,
          summary: "Method body's last-expression type is incompatible with the declared return type.",
          fires_when: [
            "Method has a `def` body the engine can re-type.",
            "Method's RBS sig declares a non-`untyped` return type.",
            "Body's inferred return type does not flow into the declared type under gradual acceptance."
          ],
          does_not_fire_when: [
            "Method's declared return is `untyped` / `void`.",
            "Body's last expression is `Dynamic[T]` (the engine cannot rule out the declared type)."
          ],
          suppression: "`# rigor:disable def.return-type-mismatch`.",
          severity_authored: :warning,
          severity_by_profile: { lenient: :warning, balanced: :warning, strict: :error },
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
          since: "0.1.2"
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
          since: "0.1.2"
        )
      }.freeze

      module_function

      # Looks up a rule by canonical id, legacy alias, or family
      # wildcard. Returns an Array<Entry>:
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
    end
  end
end
