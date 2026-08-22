# frozen_string_literal: true

require_relative "type"
require_relative "builtins/imported_refinements"
require_relative "flow_contribution"
require_relative "effects/envelope"
require_relative "effects/inline_anchor"
require_relative "effects/label"
require_relative "effects/label_set"
require_relative "effects/signature_sources"
require_relative "rbs_extended/reporter"
require_relative "rbs_extended/hkt_directives"

module Rigor
  # Reader for the `RBS::Extended` annotation surface described in `docs/type-specification/rbs-extended.md`.
  #
  # Reads `%a{rigor:v1:<directive> <payload>}` annotations off RBS method definitions and returns well-typed
  # effect objects the inference engine can consume. Implemented directives:
  #
  # - `rigor:v1:predicate-if-true <target> is <ClassName|refinement>`
  # - `rigor:v1:predicate-if-false <target> is <ClassName|refinement>`
  # - `rigor:v1:assert <target> is <ClassName|refinement>`
  # - `rigor:v1:assert-if-true <target> is <ClassName|refinement>`
  # - `rigor:v1:assert-if-false <target> is <ClassName|refinement>`
  # - `rigor:v1:param <name> <type-expr>` — per-call param narrowing
  # - `rigor:v1:return <type-expr>` — per-call return override
  # - `rigor:v1:conforms-to <InterfaceName>` — structural conformance
  #
  # `predicate-if-*` fires when the call is used as an `if` / `unless` condition; `assert` fires unconditionally
  # at the call's post-scope; `assert-if-true` / `assert-if-false` fire at the post-scope only when the call's
  # return value can be observed as truthy / falsey. Negation (`~T`) is supported for both class-name and
  # refinement right-hand sides. Parameterised refinements (`non-empty-array[T]`) are also recognised. Annotations
  # whose directive is unrecognised are silently ignored per the spec's "unsupported metadata" guidance.
  module RbsExtended # rubocop:disable Metrics/ModuleLength
    DIRECTIVE_PREFIX = "rigor:v1:"

    # Returned for `predicate-if-true` / `predicate-if-false`. `target_kind` is `:parameter` (with `target_name`
    # the Ruby parameter symbol) or `:self`. `negative` is true when the directive uses the `~ClassName` form, in
    # which case the engine narrows AWAY from `class_name` (`Narrowing.narrow_not_class`) instead of toward it.
    #
    # `refinement_type` is non-nil when the right-hand side is a kebab-case refinement name (`non-empty-string`,
    # `lowercase-string`, …) instead of a Capitalised class name. The narrowing tier substitutes the carrier for
    # the current local type; `class_name` is then nil. `negative` may be true for refinement-form directives —
    # `~T` negation is supported; the narrowing tier computes the complement decomposition (see `AssertEffect`
    # docs below).
    class PredicateEffect < Data.define(:edge, :target_kind, :target_name, :class_name, :negative, :refinement_type)
      def truthy_only? = edge == :truthy_only
      def falsey_only? = edge == :falsey_only
      def negative? = negative == true
      def refinement? = !refinement_type.nil?

      # ADR-7 § "Slice 4-A" canonical translation. Lifts the parser-side carrier into a
      # `Rigor::FlowContribution::Fact` that the merger and plugin contribution stream consume uniformly.
      # `class_name` lifts to `Nominal[<class>]`; `refinement_type` is already a `Rigor::Type` and passes through.
      # The `edge` field doesn't survive the conversion — the slot it lands in (truthy_facts / falsey_facts / ...)
      # encodes that.
      def to_fact
        FlowContribution::Fact.new(
          target_kind: target_kind,
          target_name: target_name,
          type: refinement_type || Rigor::Type::Combinator.nominal_of(class_name),
          negative: negative == true
        )
      end
    end

    # Returned for `assert` / `assert-if-true` / `assert-if-false`. `condition` is one of:
    #
    # - `:always`           — refines `target` at the call's post-scope unconditionally (`assert`).
    # - `:if_truthy_return` — refines `target` only when the call's return value is observed as truthy
    #                         (currently: as the predicate of a subsequent `if` / `unless`).
    # - `:if_falsey_return` — symmetric for falsey.
    #
    # `negative` mirrors `PredicateEffect`: true when the directive uses `~ClassName` syntax.
    class AssertEffect < Data.define(:condition, :target_kind, :target_name, :class_name, :negative, :refinement_type)
      def always? = condition == :always
      def if_truthy_return? = condition == :if_truthy_return
      def if_falsey_return? = condition == :if_falsey_return
      def negative? = negative == true
      def refinement? = !refinement_type.nil?

      # ADR-7 § "Slice 4-A" canonical translation. Same shape as `PredicateEffect#to_fact`; the `condition` field
      # (`:always` / `:if_truthy_return` / `:if_falsey_return`) routes which slot the resulting fact lands in at
      # the `read_flow_contribution` boundary, but does not surface on the Fact itself.
      def to_fact
        FlowContribution::Fact.new(
          target_kind: target_kind,
          target_name: target_name,
          type: refinement_type || Rigor::Type::Combinator.nominal_of(class_name),
          negative: negative == true
        )
      end
    end

    module_function

    # Reads RBS::Extended predicate effects off `RBS::Definition::Method#annotations`. Returns the effects in
    # source order; duplicates and unrecognised `rigor:v1:` directives are dropped. Returns an empty array (NEVER
    # `nil`) for a method with no recognised annotations so callers can iterate unconditionally.
    #
    # @param environment [Rigor::Environment, nil] ADR-13 slice
    #   3b. When provided, threads the plugin-supplied
    #   `name_scope:` and the per-run reporter through the
    #   annotation-parse path. `nil` (default) preserves the
    #   pre-slice-3b behaviour — no plugin resolvers consulted
    #   and no diagnostics accumulated.
    def read_predicate_effects(method_def, environment: nil)
      return [] if method_def.nil?

      annotations = method_def.annotations
      return [] if annotations.nil? || annotations.empty?

      name_scope = environment&.name_scope
      reporter = environment&.rbs_extended_reporter

      effects = []
      annotations.each do |annotation|
        effect = parse_predicate_annotation(
          annotation.string,
          name_scope: name_scope,
          reporter: reporter,
          source_location: annotation.location
        )
        effects << effect if effect
      end
      effects.uniq
    end

    # The right-hand side accepts either a Capitalised class name (with optional `~` negation, optional `::`
    # prefix, qualified names) OR a kebab-case refinement payload routed through
    # `Builtins::ImportedRefinements::Parser` (bare names, `name[T]`, `name<min, max>`). The two arms share the
    # same overall directive shape; the parser detects which form matched by looking at the `class_name` vs
    # `refinement` capture groups.
    PREDICATE_DIRECTIVE_PATTERN = /
      \A
      rigor:v1:(?<directive>predicate-if-(?:true|false))
      \s+
      (?<target>self|[a-z_][a-zA-Z0-9_]*)
      \s+is\s+
      (?<negation>~?)
      (?:
        (?<class_name>(?:::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)
        |
        (?<refinement>[a-z][a-z0-9-]*(?:[\[<][^\]>]*[\]>])?)
      )
      \s*
      \z
    /x
    private_constant :PREDICATE_DIRECTIVE_PATTERN

    def parse_predicate_annotation(string, name_scope: nil, reporter: nil, source_location: nil)
      match = PREDICATE_DIRECTIVE_PATTERN.match(string)
      return nil if match.nil?

      directive = match[:directive].to_s
      target = match[:target].to_s
      edge = directive == "predicate-if-true" ? :truthy_only : :falsey_only
      target_kind, target_name = target_fields(target)
      class_name, refinement_type, negative = resolve_directive_rhs(
        match,
        name_scope: name_scope,
        reporter: reporter,
        source_location: source_location
      )
      if class_name.nil? && refinement_type.nil?
        record_unresolved(reporter, string, source_location)
        return nil
      end

      PredicateEffect.new(
        edge: edge,
        target_kind: target_kind,
        target_name: target_name,
        class_name: class_name,
        negative: negative,
        refinement_type: refinement_type
      )
    end

    # Reads RBS::Extended assertion effects (`assert`, `assert-if-true`, `assert-if-false`) off
    # `RBS::Definition::Method#annotations`. Returns an empty array when no recognised assertion directives are
    # attached to the method.
    #
    # See {.read_predicate_effects} for the `environment:` keyword contract.
    def read_assert_effects(method_def, environment: nil)
      return [] if method_def.nil?

      annotations = method_def.annotations
      return [] if annotations.nil? || annotations.empty?

      name_scope = environment&.name_scope
      reporter = environment&.rbs_extended_reporter

      effects = []
      annotations.each do |annotation|
        effect = parse_assert_annotation(
          annotation.string,
          name_scope: name_scope,
          reporter: reporter,
          source_location: annotation.location
        )
        effects << effect if effect
      end
      effects.uniq
    end

    ASSERT_DIRECTIVE_PATTERN = /
      \A
      rigor:v1:(?<directive>assert(?:-if-(?:true|false))?)
      \s+
      (?<target>self|[a-z_][a-zA-Z0-9_]*)
      \s+is\s+
      (?<negation>~?)
      (?:
        (?<class_name>(?:::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)
        |
        (?<refinement>[a-z][a-z0-9-]*(?:[\[<][^\]>]*[\]>])?)
      )
      \s*
      \z
    /x
    private_constant :ASSERT_DIRECTIVE_PATTERN

    ASSERT_CONDITIONS = {
      "assert" => :always,
      "assert-if-true" => :if_truthy_return,
      "assert-if-false" => :if_falsey_return
    }.freeze
    private_constant :ASSERT_CONDITIONS

    def parse_assert_annotation(string, name_scope: nil, reporter: nil, source_location: nil)
      match = ASSERT_DIRECTIVE_PATTERN.match(string)
      return nil if match.nil?

      directive = match[:directive].to_s
      condition = ASSERT_CONDITIONS[directive]
      return nil if condition.nil?

      target = match[:target].to_s
      target_kind, target_name = target_fields(target)
      class_name, refinement_type, negative = resolve_directive_rhs(
        match,
        name_scope: name_scope,
        reporter: reporter,
        source_location: source_location
      )
      if class_name.nil? && refinement_type.nil?
        record_unresolved(reporter, string, source_location)
        return nil
      end

      AssertEffect.new(
        condition: condition,
        target_kind: target_kind,
        target_name: target_name,
        class_name: class_name,
        negative: negative,
        refinement_type: refinement_type
      )
    end

    # Resolves the `class_name` / `refinement` alternation in
    # the assert / predicate directive patterns. Returns
    # `[class_name, refinement_type, negative]`:
    #
    # - Class-name arm matched: `class_name` is the resolved
    #   string (leading `::` stripped), `refinement_type` is
    #   nil, `negative` reflects the optional `~` prefix.
    # - Refinement arm matched: `class_name` is nil,
    #   `refinement_type` is the resolved `Rigor::Type`,
    #   `negative` reflects the `~` prefix. v0.0.5 supports
    #   refinement-form negation for the `Difference[base,
    #   Constant]` shape (the narrowing tier computes the
    #   complement decomposition); other refinement carriers
    #   under negation fall back to the conservative
    #   "current_type unchanged" answer.
    # - Refinement payload unparseable: returns
    #   `[nil, nil, false]` so callers can drop the directive
    #   silently (fail-soft policy).
    def resolve_directive_rhs(match, name_scope: nil, reporter: nil, source_location: nil)
      negative = match[:negation].to_s == "~"
      class_capture = match[:class_name]
      return [class_capture.to_s.sub(/\A::/, ""), nil, negative] if class_capture

      refinement_capture = match[:refinement]
      return [nil, nil, false] if refinement_capture.nil?

      type = Builtins::ImportedRefinements.parse(
        refinement_capture,
        name_scope: name_scope,
        reporter: reporter,
        source_location: source_location
      )
      return [nil, nil, false] if type.nil?

      [nil, type, negative]
    end

    def target_fields(target)
      if target == "self"
        %i[self self]
      else
        [:parameter, target.to_sym]
      end
    end

    # Reads the `rigor:v1:return: <kebab-name>` directive off `RBS::Definition::Method#annotations`. The
    # directive overrides a method's RBS-declared return type with one of the imported-built-in refinements
    # registered in `Rigor::Builtins::ImportedRefinements`. The override is the primary integration path for
    # refinement carriers (`non-empty-string`, `positive-int`, `non-empty-array`, …) in v0.0 — annotation-driven,
    # opt-in per method, and never silently rewrites a hand-authored RBS signature outside the annotation.
    #
    # Example annotation in an RBS file:
    #
    #   class User
    #     %a{rigor:v1:return: non-empty-string}
    #     def name: () -> String
    #   end
    #
    # The RBS-declared return is `String`. The override tightens it to `non-empty-string` (i.e.
    # `Difference[String, ""]`) for callers; RBS erasure of the tightened return goes back to `String` so the
    # round-trip to ordinary RBS is unaffected.
    #
    # Returns the resolved `Rigor::Type` value, or `nil` when:
    # - the method has no annotations,
    # - none of the annotations match the `rigor:v1:return:` directive,
    # - the directive's payload names a refinement not registered in `Rigor::Builtins::ImportedRefinements` (the
    #   analyzer prefers a silent miss over crashing on a typo; ADR-13 slice 3b surfaces the miss as a
    #   `dynamic.rbs-extended.unresolved` `:info` diagnostic when an `environment:` is supplied).
    def read_return_type_override(method_def, environment: nil)
      return nil if method_def.nil?

      annotations = method_def.annotations
      return nil if annotations.nil? || annotations.empty?

      name_scope = environment&.name_scope
      reporter = environment&.rbs_extended_reporter
      hkt_registry = environment&.hkt_registry

      annotations.each do |annotation|
        type = parse_return_type_override(
          annotation.string,
          name_scope: name_scope,
          reporter: reporter,
          source_location: annotation.location,
          hkt_registry: hkt_registry
        )
        return type if type
      end
      nil
    end

    # The trailing payload supports the full refinement grammar in `Builtins::ImportedRefinements::Parser` — bare
    # kebab-case names plus parameterised forms like `non-empty-array[Integer]`, `non-empty-hash[Symbol,
    # Integer]`, and `int<5, 10>`. The directive head is consumed by the regex; the rest is forwarded to the
    # refinement parser. Anything the parser cannot resolve falls back to nil so the call site keeps the
    # RBS-declared return type.
    RETURN_DIRECTIVE_PATTERN = /
      \A
      rigor:v1:return:
      \s+
      (?<payload>\S(?:.*\S)?)
      \s*
      \z
    /x
    private_constant :RETURN_DIRECTIVE_PATTERN

    # ADR-20 slice 2d — recognises `App[<uri>, <ClassName>, ...]` syntax in a `rigor:v1:return:` payload before
    # falling through to the refinement-name parser. The match captures the namespaced URI (`json::value`) plus a
    # comma-separated list of bare class names (`String`, `Symbol`, `Integer`). Slice 2d keeps the arg vocabulary
    # intentionally narrow; parameterised forms (`Array[T]`, `Hash[K, V]`), unions, and refinements inside
    # `App[...]` wait for a follow-up slice's expression parser.
    APP_PAYLOAD_PATTERN = /
      \A
      App\[
      \s*
      (?<uri>[a-z_][a-z0-9_]*(?:::[a-z_][a-z0-9_]*)+)
      \s*,\s*
      (?<args>[^\[\]]+?)
      \s*\]
      \z
    /x
    private_constant :APP_PAYLOAD_PATTERN

    def parse_return_type_override(string, name_scope: nil, reporter: nil, source_location: nil, hkt_registry: nil)
      match = RETURN_DIRECTIVE_PATTERN.match(string)
      return nil if match.nil?

      app_type = parse_app_payload(
        match[:payload],
        name_scope: name_scope,
        reporter: reporter,
        source_location: source_location,
        hkt_registry: hkt_registry
      )
      return app_type if app_type

      type = Builtins::ImportedRefinements.parse(
        match[:payload],
        name_scope: name_scope,
        reporter: reporter,
        source_location: source_location
      )
      record_unresolved(reporter, string, source_location) if type.nil?
      type
    end

    # ADR-20 slice 2d. Parses `App[<uri>, <ClassName>, ...]` syntax into a `Rigor::Type::App`. When
    # `hkt_registry` is supplied and the URI is registered with a body_tree, the `App` is reduced eagerly via
    # {Inference::HktRegistry#reduce} so call sites observe the unfolded form (e.g.
    # `Union[nil, true, false, ..., Array[App[json::value, String]], Hash[String, App[json::value, String]]]`)
    # rather than the opaque carrier. When the registry is absent or the URI is unregistered, the carrier with
    # its registry-supplied bound (or `untyped` as a last-resort fallback) is returned as-is.
    def parse_app_payload(payload, name_scope: nil, reporter: nil, source_location: nil, hkt_registry: nil)
      match = APP_PAYLOAD_PATTERN.match(payload)
      return nil if match.nil?

      uri = match[:uri].to_sym
      arg_classes = match[:args].split(",").map(&:strip)
      args = arg_classes.map { |name| resolve_app_arg(name, name_scope: name_scope) }

      if args.any?(&:nil?)
        record_unresolved(reporter, "App payload `#{payload}`: unresolved arg class name", source_location)
        return nil
      end

      registration = hkt_registry&.registration(uri)
      bound = registration&.bound || Type::Combinator.untyped
      app = Type::App.new(uri, args, bound: bound)

      return app if hkt_registry.nil? || !hkt_registry.defined?(uri)

      reduced = hkt_registry.reduce(app)
      reduced || app
    end

    def resolve_app_arg(class_name, name_scope: nil)
      return nil unless /\A(?:::)?(?:[A-Z]\w*)(?:::[A-Z]\w*)*\z/.match?(class_name)

      normalized = class_name.sub(/\A::/, "")
      return Type::Nominal.new(normalized) if name_scope.nil?

      if name_scope.respond_to?(:nominal_for_name)
        resolved = name_scope.nominal_for_name(normalized)
        return resolved if resolved
      end
      Type::Nominal.new(normalized)
    end

    # Returned for `rigor:v1:param: <name> <refinement>`. The parameter name is a Ruby identifier (Symbol); the
    # type is any `Rigor::Type` the refinement parser resolves (bare kebab-case name, parameterised form, or
    # `int<...>` range — the same grammar the `return:` directive accepts).
    ParamOverride = Data.define(:param_name, :type)

    # Reads every `rigor:v1:param: <name> <refinement>` directive off `RBS::Definition::Method#annotations` and
    # returns the resolved `ParamOverride` list. Annotations the parser cannot resolve (typo, unknown refinement,
    # no `param:` directive at all) are silently dropped — the call site keeps the RBS-declared parameter type
    # for those parameters. The reader accepts a nil method definition so call sites can pass through optional
    # method lookups without a guard.
    #
    # Example annotation in an RBS file:
    #
    #   class Slug
    #     %a{rigor:v1:param: id is non-empty-string}
    #     def normalise: (::String id) -> String
    #   end
    #
    # The RBS-declared type of `id` is `String`. The override tightens it to `non-empty-string` for
    # argument-check purposes; passing a too-wide `Nominal[String]` argument is flagged as an argument-type
    # mismatch at the call site.
    def read_param_type_overrides(method_def, environment: nil)
      return [] if method_def.nil?

      annotations = method_def.annotations
      return [] if annotations.nil? || annotations.empty?

      name_scope = environment&.name_scope
      reporter = environment&.rbs_extended_reporter

      annotations.filter_map do |annotation|
        parse_param_annotation(
          annotation.string,
          name_scope: name_scope,
          reporter: reporter,
          source_location: annotation.location
        )
      end
    end

    # Convenience reader for call sites that want to look up a single override by parameter name. Returns a
    # frozen Hash<Symbol, Rigor::Type>; missing keys mean "use the RBS-declared type". Callers MUST treat the
    # hash as read-only.
    def param_type_override_map(method_def, environment: nil)
      read_param_type_overrides(method_def, environment: environment)
        .to_h { |o| [o.param_name, o.type] }
        .freeze
    end

    # The `is` glue word is optional so authors can write either `param: id is non-empty-string` (consistent with
    # the existing `assert` / `predicate-if-*` directives) or the terser `param: id non-empty-string`. The
    # trailing payload accepts the full refinement grammar in `Builtins::ImportedRefinements::Parser`.
    PARAM_DIRECTIVE_PATTERN = /
      \A
      rigor:v1:param:
      \s+
      (?<param>[a-z_][a-zA-Z0-9_]*)
      \s+
      (?:is\s+)?
      (?<payload>\S(?:.*\S)?)
      \s*
      \z
    /x
    private_constant :PARAM_DIRECTIVE_PATTERN

    def parse_param_annotation(string, name_scope: nil, reporter: nil, source_location: nil)
      match = PARAM_DIRECTIVE_PATTERN.match(string)
      return nil if match.nil?

      type = Builtins::ImportedRefinements.parse(
        match[:payload],
        name_scope: name_scope,
        reporter: reporter,
        source_location: source_location
      )
      if type.nil?
        record_unresolved(reporter, string, source_location)
        return nil
      end

      ParamOverride.new(param_name: match[:param].to_sym, type: type)
    end

    # A class- / module-level directive declaring that the annotated class satisfies a named structural interface
    # as part of its public contract (spec: `docs/type-specification/rbs-extended.md` § "Explicit conformance
    # directive"). Unlike the per-method directives above, this attaches to a `class` / `module` declaration and
    # names a single RBS interface (`_RewindableStream`); the right-hand side is therefore an interface name (its
    # last segment begins with `_`), never a refinement payload.
    #
    # This parser only extracts the interface name; the conformance check itself lives in
    # {Rigor::RbsExtended::ConformanceChecker}, which the {Rigor::Analysis::Runner} runs once per project run.
    CONFORMS_TO_DIRECTIVE_PATTERN = /
      \A
      rigor:v1:conforms-to
      \s+
      (?<interface>(?:::)?(?:[A-Z]\w*::)*_[A-Za-z]\w*)
      \s*
      \z
    /x
    private_constant :CONFORMS_TO_DIRECTIVE_PATTERN

    # Returns the interface name (leading `::` stripped) for a `rigor:v1:conforms-to <Interface>` annotation, or
    # `nil` when the string is not a conforms-to directive (so callers can walk an annotation list without
    # pre-filtering). The name is returned verbatim otherwise — namespace resolution happens at the loader
    # boundary when the interface is built.
    def parse_conforms_to_annotation(string)
      return nil if string.nil?

      match = CONFORMS_TO_DIRECTIVE_PATTERN.match(string)
      return nil if match.nil?

      match[:interface].to_s.sub(/\A::/, "")
    end

    # The shared {Rigor::FlowContribution::Provenance} for every bundle this module produces.
    # `source_family: :rbs_extended` so consumers (today the documentation surface; v0.1.0 the plugin contribution
    # merger) can attribute facts back to the RBS::Extended layer.
    RBS_EXTENDED_PROVENANCE = FlowContribution::Provenance.new(
      source_family: :rbs_extended,
      plugin_id: nil,
      node: nil,
      descriptor: nil
    ).freeze

    # Rolls up every recognised RBS::Extended directive on `method_def` into a single {Rigor::FlowContribution}
    # with the canonical {Rigor::FlowContribution::Fact} payload (see ADR-7 § "Slice 4-A"):
    #
    # - `predicate-if-true`        → `truthy_facts`
    # - `predicate-if-false`       → `falsey_facts`
    # - `assert`                   → `post_return_facts`
    # - `assert-if-true`           → `truthy_facts`
    # - `assert-if-false`          → `falsey_facts`
    # - `return:` override         → `return_type` (`Rigor::Type`)
    #
    # Param overrides are intentionally NOT included — they refine the call's signature contract rather than its
    # flow facts and do not fit ADR-2 § "Flow Contribution Bundle" slot semantics. Callers that care about
    # parameter contracts keep using {.read_param_type_overrides} / {.param_type_override_map}.
    #
    # Returns `nil` when the method carries no recognised contribution directives (callers can skip the merge
    # step without iterating an empty bundle).
    #
    # See {.read_predicate_effects} for the `environment:` keyword contract.
    def read_flow_contribution(method_def, environment: nil)
      return nil if method_def.nil?

      predicate_effects = read_predicate_effects(method_def, environment: environment)
      assert_effects = read_assert_effects(method_def, environment: environment)
      return_override = read_return_type_override(method_def, environment: environment)
      return nil if predicate_effects.empty? && assert_effects.empty? && return_override.nil?

      build_flow_contribution(predicate_effects, assert_effects, return_override)
    end

    def build_flow_contribution(predicate_effects, assert_effects, return_override)
      truthy = predicate_effects.select(&:truthy_only?).map(&:to_fact)
      falsey = predicate_effects.select(&:falsey_only?).map(&:to_fact)
      post_return = []

      assert_effects.each do |effect|
        case effect.condition
        when :if_truthy_return then truthy << effect.to_fact
        when :if_falsey_return then falsey << effect.to_fact
        else post_return << effect.to_fact
        end
      end

      FlowContribution.new(
        return_type: return_override,
        truthy_facts: nilable_slot(truthy),
        falsey_facts: nilable_slot(falsey),
        post_return_facts: nilable_slot(post_return),
        provenance: RBS_EXTENDED_PROVENANCE
      )
    end

    def nilable_slot(facts)
      facts.empty? ? nil : facts
    end

    # ── Effect envelopes (ADR-103 WD1 / WD5 / WD14; #383) ──────────────────────────────────────────
    #
    # Two spellings reach the same value. `%a{pure}` is the ecosystem's existing purity annotation
    # (rbs core and Steep both carry it) and reads as the EMPTY envelope; `%a{rigor:v1:effect …}` is
    # Rigor's labelled bound. `rigor:v1:pure` is deliberately NOT implemented — WD14 fixed `%a{pure}`
    # as the only purity spelling.

    # The bare rbs-native purity annotation. Matched whole, with surrounding whitespace tolerated, so
    # `%a{purely}` and `%a{pure io}` are not it.
    PURE_ANNOTATION_PATTERN = /\A\s*pure\s*\z/
    private_constant :PURE_ANNOTATION_PATTERN

    # `%a{rigor:v1:effect io.db, nondet.time}` — a space-separated head (the `assert` / `conforms-to`
    # family), then a comma-separated list of BARE label tokens. There is no parenthesised comment
    # form: RBS has real comments. The payload group is optional so that `%a{rigor:v1:effect}` still
    # MATCHES the directive and is reported as malformed rather than read as "not a directive".
    EFFECT_DIRECTIVE_PATTERN = /\Arigor:v1:effect(?:\s+(?<labels>.*?))?\s*\z/
    private_constant :EFFECT_DIRECTIVE_PATTERN

    # The outcome of reading one `%a{rigor:v1:effect …}` payload.
    #
    # `bound` is the declared {Rigor::Effects::LabelSet}, or {Effects::LabelSet::TOP} when the tag
    # could not be given a meaning. `malformed` says the grammar was violated (an empty list, a token
    # that is not a label); `unknown_labels` says the grammar held but the registry does not
    # recognise a spelling — a different condition with different handling, and what #384's
    # `effect.unknown-label` reads. `labels` is the list exactly as written, recognised or not, which
    # is what lets the diagnostic ask whether some OTHER member of the list was known.
    EffectAnnotation = Data.define(:bound, :labels, :unknown_labels, :malformed) do
      def malformed? = malformed
      def top? = bound.top?
    end

    NO_EFFECT_LABELS = [].freeze
    private_constant :NO_EFFECT_LABELS

    # Whether `string` is the bare `%a{pure}` annotation.
    def pure_annotation?(string)
      !string.nil? && PURE_ANNOTATION_PATTERN.match?(string)
    end

    # Reads one annotation string as an effect-envelope payload.
    #
    # Returns `nil` when the string is not a `rigor:v1:effect` directive at all (so a caller can walk
    # an annotation list without pre-filtering). Otherwise an {EffectAnnotation}:
    #
    # - well-formed and fully recognised → the declared bound;
    # - malformed (empty list, a token outside the label grammar) → {Effects::LabelSet::TOP}, and a
    #   `record_unresolved` event on `reporter`;
    # - well-formed but carrying a spelling `registry` does not know → {Effects::LabelSet::TOP} and
    #   the unrecognised spellings, because an unknown label makes the WHOLE tag ⊤ rather than the
    #   subset that happened to parse. Narrowing to the recognised subset would turn a typo into
    #   findings on correct code; widening suppresses them, which is the direction the false-positive
    #   budget runs (ADR-5).
    def parse_effect_annotation(string, registry: nil, reporter: nil, source_location: nil)
      match = EFFECT_DIRECTIVE_PATTERN.match(string.to_s)
      return nil if match.nil?

      tokens = match[:labels].to_s.split(",", -1).map(&:strip)
      if tokens.empty? || tokens.any? { |token| !Effects::Label.valid?(token) }
        record_unresolved(reporter, string, source_location)
        return EffectAnnotation.new(
          bound: Effects::LabelSet::TOP, labels: NO_EFFECT_LABELS, unknown_labels: NO_EFFECT_LABELS, malformed: true
        )
      end

      tokens = tokens.freeze
      unknown = registry.nil? ? [] : tokens.reject { |token| registry.known?(token) }
      EffectAnnotation.new(
        bound: unknown.empty? ? Effects::LabelSet.new(tokens) : Effects::LabelSet::TOP,
        labels: tokens, unknown_labels: unknown.uniq.sort.freeze, malformed: false
      )
    end

    # Reads the effect envelope off an annotation list — `RBS::Definition::Method#annotations`, or the
    # `#annotations` of an `RBS::AST::Members::MethodDefinition` / class declaration, which carry the
    # same `(string, location)` shape.
    #
    # Precedence, per the spec: `%a{pure}` and `%a{rigor:v1:effect …}` on ONE declaration are
    # contradictory and `pure` wins; the contradiction is recorded on `reporter` (the existing
    # `RBS::Extended` conflict channel) rather than silently resolved. Returns `nil` when the list
    # carries neither spelling.
    #
    # @param annotations [Array<#string>] the node's annotations, in source order.
    # @param owner_key [String] the method key (`Class#m` / `Class.m`) or class name the bound binds.
    # @param source [Symbol] {Effects::Envelope::SOURCES} member to stamp when the labelled spelling
    #   matched; `%a{pure}` always stamps `:pure_annotation`, and a class-level read overrides both.
    def read_effect_envelope(annotations, owner_key:, source: :effect_annotation, registry: nil, reporter: nil)
      return nil if annotations.nil? || annotations.empty?

      pure = annotations.find { |annotation| pure_annotation?(annotation.string) }
      labelled = nil
      parsed = nil
      annotations.each do |annotation|
        result = parse_effect_annotation(
          annotation.string, registry: registry, reporter: reporter, source_location: annotation_location(annotation)
        )
        next if result.nil?

        labelled = annotation
        parsed = result
        break
      end
      return nil if pure.nil? && labelled.nil?

      if pure && labelled
        record_unresolved(
          reporter,
          "`%a{pure}` and `%a{#{labelled.string}}` on one declaration are contradictory; `pure` wins",
          annotation_location(pure)
        )
      end
      return build_pure_envelope(pure, owner_key: owner_key, source: source) if pure

      build_effect_envelope(labelled, parsed, owner_key: owner_key, source: source)
    end

    def build_pure_envelope(annotation, owner_key:, source:)
      Effects::Envelope.build(
        owner_key: owner_key,
        bound: Effects::LabelSet::EMPTY,
        source: source == :class_annotation ? :class_annotation : :pure_annotation,
        location: render_annotation_location(annotation),
        spelling: "%a{#{annotation.string}}"
      )
    end

    def build_effect_envelope(annotation, parsed, owner_key:, source:)
      Effects::Envelope.build(
        owner_key: owner_key,
        bound: parsed.bound,
        source: source,
        location: render_annotation_location(annotation),
        spelling: "%a{#{annotation.string}}",
        unknown_labels: parsed.unknown_labels,
        declared_labels: parsed.labels
      )
    end

    def annotation_location(annotation)
      annotation.respond_to?(:location) ? annotation.location : nil
    end

    # `path:line` for the annotation, project-relative when it sits under the working directory, so a
    # diagnostic message names `sig/foo.rbs:12` rather than an absolute path.
    #
    # A synthesized buffer is re-anchored here rather than at any of the surfaces that render it
    # ({Effects::InlineAnchor}; #432). The buffer's own line numbers describe a document the author
    # never saw, so an envelope carrying one is wrong for every consumer at once — the diagnostic, the
    # `effect.unknown-label` position, `rigor explain`, the JSON formatter, LSP hover. Correcting it
    # where the value is *built* is what makes them agree without each learning the mapping.
    def render_annotation_location(annotation)
      location = annotation_location(annotation)
      return nil if location.nil?

      buffer = location.respond_to?(:buffer) ? location.buffer : nil
      name = buffer.respond_to?(:name) ? buffer.name.to_s : nil
      return nil if name.nil? || name.empty?

      path = relative_annotation_path(name)
      "#{path}:#{annotation_line(annotation, location, buffer, path)}"
    rescue StandardError
      nil
    end

    # The line a reader can open. For a real `.rbs` that is the parser's own answer; for the
    # `virtual:rbs-inline:…rb` buffer the writer produced, the annotation is found again in the Ruby
    # source by its own spelling.
    def annotation_line(annotation, location, buffer, path)
      line = location.respond_to?(:start_line) ? location.start_line : 1
      content = buffer.respond_to?(:content) ? buffer.content : nil
      return line if content.nil?

      Effects::InlineAnchor.ruby_line(
        path: path, buffer: content, buffer_line: line, spelling: "%a{#{annotation.string}}"
      )
    end

    # The buffer-name → readable-path rule lives with the walk that produces the buffers
    # ({Effects::SignatureSources}), so a `virtual:` name is stripped identically wherever it surfaces.
    def relative_annotation_path(name)
      Effects::SignatureSources.source_path(name)
    end

    # ADR-13 slice 3b — guards every reporter call so the in-RbsExtended-module call sites can record events
    # uniformly without nil-checking each time. When the reporter is nil (the v0.1.0 → v0.1.3 default for call
    # sites that do not yet thread `environment:`), the call is a no-op and the parser stays fail-soft.
    def record_unresolved(reporter, payload, source_location)
      return if reporter.nil?

      reporter.record_unresolved(payload: payload, source_location: source_location)
    end
  end
end
