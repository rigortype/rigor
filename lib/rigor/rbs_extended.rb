# frozen_string_literal: true

require_relative "type"
require_relative "builtins/imported_refinements"
require_relative "flow_contribution"
require_relative "rbs_extended/reporter"
require_relative "rbs_extended/hkt_directives"

module Rigor
  # Slice 7 phase 15 — first-preview reader for the
  # `RBS::Extended` annotation surface described in
  # `docs/type-specification/rbs-extended.md`.
  #
  # This module reads `%a{rigor:v1:<directive> <payload>}`
  # annotations off RBS method definitions and returns
  # well-typed effect objects the inference engine can
  # consume. v0.0.2 recognises:
  #
  # - `rigor:v1:predicate-if-true <target> is <ClassName>`
  # - `rigor:v1:predicate-if-false <target> is <ClassName>`
  # - `rigor:v1:assert <target> is <ClassName>`
  # - `rigor:v1:assert-if-true <target> is <ClassName>`
  # - `rigor:v1:assert-if-false <target> is <ClassName>`
  #
  # `predicate-if-*` fires when the call is used as an
  # `if` / `unless` condition; `assert` fires unconditionally
  # at the call's post-scope; `assert-if-true` /
  # `assert-if-false` fire at the post-scope only when the
  # call's return value can be observed as truthy / falsey
  # (currently: when the call is the predicate of a
  # subsequent `if` / `unless`). Other directives in the spec
  # (`param`, `return`, `conforms-to`, negation `~T`,
  # `target: self` narrowing, ...) remain on the v0.0.x
  # roadmap. Annotations whose key is in the `rigor:v1:`
  # namespace but whose directive is unrecognised are
  # silently ignored at first-preview quality (a future slice
  # MAY surface them as diagnostics-on-Rigor-itself per the
  # spec's "unsupported metadata" guidance).
  #
  # The parser is minimal: it accepts a strict shape
  # `<target> is <ClassName>` where `<target>` is a Ruby
  # identifier (parameter name) or `self`, and `<ClassName>`
  # is a single non-namespaced class identifier or a
  # `::Foo::Bar` style constant path. Negative refinements
  # (`~T`), intersections, and unions are deferred to the
  # next iteration.
  module RbsExtended # rubocop:disable Metrics/ModuleLength
    DIRECTIVE_PREFIX = "rigor:v1:"

    # Returned for `predicate-if-true` / `predicate-if-false`.
    # `target_kind` is `:parameter` (with `target_name` the
    # Ruby parameter symbol) or `:self`. `negative` is true
    # when the directive uses the `~ClassName` form, in
    # which case the engine narrows AWAY from `class_name`
    # (`Narrowing.narrow_not_class`) instead of toward it.
    #
    # `refinement_type` is non-nil when the right-hand side is
    # a kebab-case refinement name (`non-empty-string`,
    # `lowercase-string`, …) instead of a Capitalised class
    # name. The narrowing tier substitutes the carrier for the
    # current local type; `class_name` is then nil and
    # `negative` is false (refinement-form directives do not
    # support `~T` negation in v0.0.4).
    class PredicateEffect < Data.define(:edge, :target_kind, :target_name, :class_name, :negative, :refinement_type)
      def truthy_only? = edge == :truthy_only
      def falsey_only? = edge == :falsey_only
      def negative? = negative == true
      def refinement? = !refinement_type.nil?

      # ADR-7 § "Slice 4-A" canonical translation. Lifts the
      # parser-side carrier into a `Rigor::FlowContribution::Fact`
      # that the merger and plugin contribution stream consume
      # uniformly. `class_name` lifts to `Nominal[<class>]`;
      # `refinement_type` is already a `Rigor::Type` and passes
      # through. The `edge` field doesn't survive the conversion —
      # the slot it lands in (truthy_facts / falsey_facts / ...)
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

    # Returned for `assert` / `assert-if-true` /
    # `assert-if-false`. `condition` is one of:
    #
    # - `:always`           — refines `target` at the call's
    #                        post-scope unconditionally
    #                        (`assert`).
    # - `:if_truthy_return` — refines `target` only when the
    #                        call's return value is observed
    #                        as truthy (currently: as the
    #                        predicate of a subsequent
    #                        `if` / `unless`).
    # - `:if_falsey_return` — symmetric for falsey.
    #
    # `negative` mirrors `PredicateEffect`: true when the
    # directive uses `~ClassName` syntax.
    class AssertEffect < Data.define(:condition, :target_kind, :target_name, :class_name, :negative, :refinement_type)
      def always? = condition == :always
      def if_truthy_return? = condition == :if_truthy_return
      def if_falsey_return? = condition == :if_falsey_return
      def negative? = negative == true
      def refinement? = !refinement_type.nil?

      # ADR-7 § "Slice 4-A" canonical translation. Same shape as
      # `PredicateEffect#to_fact`; the `condition` field
      # (`:always` / `:if_truthy_return` / `:if_falsey_return`)
      # routes which slot the resulting fact lands in at the
      # `read_flow_contribution` boundary, but does not surface
      # on the Fact itself.
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

    # Reads RBS::Extended predicate effects off
    # `RBS::Definition::Method#annotations`. Returns the
    # effects in source order; duplicates and unrecognised
    # `rigor:v1:` directives are dropped. Returns an empty
    # array (NEVER `nil`) for a method with no recognised
    # annotations so callers can iterate unconditionally.
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

    # The right-hand side accepts either a Capitalised class
    # name (with optional `~` negation, optional `::` prefix,
    # qualified names) OR a kebab-case refinement payload
    # routed through `Builtins::ImportedRefinements::Parser`
    # (bare names, `name[T]`, `name<min, max>`). The two arms
    # share the same overall directive shape; the parser
    # detects which form matched by looking at the `class_name`
    # vs `refinement` capture groups.
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

    # Reads RBS::Extended assertion effects (`assert`,
    # `assert-if-true`, `assert-if-false`) off
    # `RBS::Definition::Method#annotations`. Returns an empty
    # array when no recognised assertion directives are
    # attached to the method.
    #
    # See {.read_predicate_effects} for the `environment:`
    # keyword contract.
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

    # Reads the `rigor:v1:return: <kebab-name>` directive off
    # `RBS::Definition::Method#annotations`. The directive
    # overrides a method's RBS-declared return type with one of
    # the imported-built-in refinements registered in
    # `Rigor::Builtins::ImportedRefinements`. The override is the
    # primary integration path for refinement carriers
    # (`non-empty-string`, `positive-int`, `non-empty-array`, …)
    # in v0.0 — annotation-driven, opt-in per method, and never
    # silently rewrites a hand-authored RBS signature outside the
    # annotation.
    #
    # Example annotation in an RBS file:
    #
    #   class User
    #     %a{rigor:v1:return: non-empty-string}
    #     def name: () -> String
    #   end
    #
    # The RBS-declared return is `String`. The override
    # tightens it to `non-empty-string` (i.e.
    # `Difference[String, ""]`) for callers; RBS erasure of the
    # tightened return goes back to `String` so the round-trip
    # to ordinary RBS is unaffected.
    #
    # Returns the resolved `Rigor::Type` value, or `nil` when:
    # - the method has no annotations,
    # - none of the annotations match the `rigor:v1:return:`
    #   directive,
    # - the directive's payload names a refinement not
    #   registered in `Rigor::Builtins::ImportedRefinements`
    #   (the analyzer prefers a silent miss over crashing on a
    #   typo; ADR-13 slice 3b surfaces the miss as a
    #   `dynamic.rbs-extended.unresolved` `:info` diagnostic when
    #   an `environment:` is supplied).
    def read_return_type_override(method_def, environment: nil)
      return nil if method_def.nil?

      annotations = method_def.annotations
      return nil if annotations.nil? || annotations.empty?

      name_scope = environment&.name_scope
      reporter = environment&.rbs_extended_reporter

      annotations.each do |annotation|
        type = parse_return_type_override(
          annotation.string,
          name_scope: name_scope,
          reporter: reporter,
          source_location: annotation.location
        )
        return type if type
      end
      nil
    end

    # The trailing payload supports the full refinement
    # grammar in `Builtins::ImportedRefinements::Parser` —
    # bare kebab-case names plus parameterised forms like
    # `non-empty-array[Integer]`, `non-empty-hash[Symbol,
    # Integer]`, and `int<5, 10>`. The directive head is
    # consumed by the regex; the rest is forwarded to the
    # refinement parser. Anything the parser cannot resolve
    # falls back to nil so the call site keeps the
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

    def parse_return_type_override(string, name_scope: nil, reporter: nil, source_location: nil)
      match = RETURN_DIRECTIVE_PATTERN.match(string)
      return nil if match.nil?

      type = Builtins::ImportedRefinements.parse(
        match[:payload],
        name_scope: name_scope,
        reporter: reporter,
        source_location: source_location
      )
      record_unresolved(reporter, string, source_location) if type.nil?
      type
    end

    # Returned for `rigor:v1:param: <name> <refinement>`. The
    # parameter name is a Ruby identifier (Symbol); the type
    # is any `Rigor::Type` the refinement parser resolves
    # (bare kebab-case name, parameterised form, or `int<...>`
    # range — the same grammar the `return:` directive
    # accepts).
    ParamOverride = Data.define(:param_name, :type)

    # Reads every `rigor:v1:param: <name> <refinement>`
    # directive off `RBS::Definition::Method#annotations` and
    # returns the resolved `ParamOverride` list. Annotations
    # the parser cannot resolve (typo, unknown refinement, no
    # `param:` directive at all) are silently dropped — the
    # call site keeps the RBS-declared parameter type for
    # those parameters. The reader accepts a nil method
    # definition so call sites can pass through optional
    # method lookups without a guard.
    #
    # Example annotation in an RBS file:
    #
    #   class Slug
    #     %a{rigor:v1:param: id is non-empty-string}
    #     def normalise: (::String id) -> String
    #   end
    #
    # The RBS-declared type of `id` is `String`. The override
    # tightens it to `non-empty-string` for argument-check
    # purposes; passing a too-wide `Nominal[String]` argument
    # is flagged as an argument-type mismatch at the call
    # site.
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

    # Convenience reader for call sites that want to look up
    # a single override by parameter name. Returns a frozen
    # Hash<Symbol, Rigor::Type>; missing keys mean "use the
    # RBS-declared type". Callers MUST treat the hash as
    # read-only.
    def param_type_override_map(method_def, environment: nil)
      read_param_type_overrides(method_def, environment: environment)
        .to_h { |o| [o.param_name, o.type] }
        .freeze
    end

    # The `is` glue word is optional so authors can write
    # either `param: id is non-empty-string` (consistent with
    # the existing `assert` / `predicate-if-*` directives) or
    # the terser `param: id non-empty-string`. The trailing
    # payload accepts the full refinement grammar in
    # `Builtins::ImportedRefinements::Parser`.
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

    # The shared {Rigor::FlowContribution::Provenance} for every
    # bundle this module produces. `source_family: :rbs_extended`
    # so consumers (today the documentation surface; v0.1.0 the
    # plugin contribution merger) can attribute facts back to the
    # RBS::Extended layer.
    RBS_EXTENDED_PROVENANCE = FlowContribution::Provenance.new(
      source_family: :rbs_extended,
      plugin_id: nil,
      node: nil,
      descriptor: nil
    ).freeze

    # Rolls up every recognised RBS::Extended directive on
    # `method_def` into a single {Rigor::FlowContribution} with
    # the canonical {Rigor::FlowContribution::Fact} payload (see
    # ADR-7 § "Slice 4-A"):
    #
    # - `predicate-if-true`        → `truthy_facts`
    # - `predicate-if-false`       → `falsey_facts`
    # - `assert`                   → `post_return_facts`
    # - `assert-if-true`           → `truthy_facts`
    # - `assert-if-false`          → `falsey_facts`
    # - `return:` override         → `return_type` (`Rigor::Type`)
    #
    # Param overrides are intentionally NOT included — they refine
    # the call's signature contract rather than its flow facts and
    # do not fit ADR-2 § "Flow Contribution Bundle" slot semantics.
    # Callers that care about parameter contracts keep using
    # {.read_param_type_overrides} / {.param_type_override_map}.
    #
    # Returns `nil` when the method carries no recognised
    # contribution directives (callers can skip the merge step
    # without iterating an empty bundle).
    #
    # See {.read_predicate_effects} for the `environment:`
    # keyword contract.
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

    # ADR-13 slice 3b — guards every reporter call so the
    # in-RbsExtended-module call sites can record events
    # uniformly without nil-checking each time. When the
    # reporter is nil (the v0.1.0 → v0.1.3 default for call
    # sites that do not yet thread `environment:`), the call is
    # a no-op and the parser stays fail-soft.
    def record_unresolved(reporter, payload, source_location)
      return if reporter.nil?

      reporter.record_unresolved(payload: payload, source_location: source_location)
    end
  end
end
