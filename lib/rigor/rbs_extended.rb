# frozen_string_literal: true

require_relative "type"

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
  module RbsExtended
    DIRECTIVE_PREFIX = "rigor:v1:"

    # Returned for `predicate-if-true` / `predicate-if-false`.
    # `target_kind` is `:parameter` (with `target_name` the
    # Ruby parameter symbol) or `:self`. `negative` is true
    # when the directive uses the `~ClassName` form, in
    # which case the engine narrows AWAY from `class_name`
    # (`Narrowing.narrow_not_class`) instead of toward it.
    PredicateEffect = Data.define(:edge, :target_kind, :target_name, :class_name, :negative) do
      def truthy_only? = edge == :truthy_only
      def falsey_only? = edge == :falsey_only
      def negative? = negative == true
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
    AssertEffect = Data.define(:condition, :target_kind, :target_name, :class_name, :negative) do
      def always? = condition == :always
      def if_truthy_return? = condition == :if_truthy_return
      def if_falsey_return? = condition == :if_falsey_return
      def negative? = negative == true
    end

    module_function

    # Reads RBS::Extended predicate effects off
    # `RBS::Definition::Method#annotations`. Returns the
    # effects in source order; duplicates and unrecognised
    # `rigor:v1:` directives are dropped. Returns an empty
    # array (NEVER `nil`) for a method with no recognised
    # annotations so callers can iterate unconditionally.
    def read_predicate_effects(method_def)
      return [] if method_def.nil?

      annotations = method_def.annotations
      return [] if annotations.nil? || annotations.empty?

      effects = []
      annotations.each do |annotation|
        effect = parse_predicate_annotation(annotation.string)
        effects << effect if effect
      end
      effects.uniq
    end

    PREDICATE_DIRECTIVE_PATTERN = /
      \A
      rigor:v1:(?<directive>predicate-if-(?:true|false))
      \s+
      (?<target>self|[a-z_][a-zA-Z0-9_]*)
      \s+is\s+
      (?<negation>~?)
      (?<class_name>(?:::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)
      \s*
      \z
    /x
    private_constant :PREDICATE_DIRECTIVE_PATTERN

    def parse_predicate_annotation(string)
      match = PREDICATE_DIRECTIVE_PATTERN.match(string)
      return nil if match.nil?

      directive = match[:directive].to_s
      target = match[:target].to_s
      class_name = match[:class_name].to_s.sub(/\A::/, "")
      edge = directive == "predicate-if-true" ? :truthy_only : :falsey_only
      target_kind = target == "self" ? :self : :parameter
      target_name = target == "self" ? :self : target.to_sym
      PredicateEffect.new(
        edge: edge,
        target_kind: target_kind,
        target_name: target_name,
        class_name: class_name,
        negative: match[:negation].to_s == "~"
      )
    end

    # Reads RBS::Extended assertion effects (`assert`,
    # `assert-if-true`, `assert-if-false`) off
    # `RBS::Definition::Method#annotations`. Returns an empty
    # array when no recognised assertion directives are
    # attached to the method.
    def read_assert_effects(method_def)
      return [] if method_def.nil?

      annotations = method_def.annotations
      return [] if annotations.nil? || annotations.empty?

      effects = []
      annotations.each do |annotation|
        effect = parse_assert_annotation(annotation.string)
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
      (?<class_name>(?:::)?[A-Z][A-Za-z0-9_]*(?:::[A-Z][A-Za-z0-9_]*)*)
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

    def parse_assert_annotation(string)
      match = ASSERT_DIRECTIVE_PATTERN.match(string)
      return nil if match.nil?

      directive = match[:directive].to_s
      condition = ASSERT_CONDITIONS[directive]
      return nil if condition.nil?

      target = match[:target].to_s
      class_name = match[:class_name].to_s.sub(/\A::/, "")
      target_kind = target == "self" ? :self : :parameter
      target_name = target == "self" ? :self : target.to_sym
      AssertEffect.new(
        condition: condition,
        target_kind: target_kind,
        target_name: target_name,
        class_name: class_name,
        negative: match[:negation].to_s == "~"
      )
    end
  end
end
