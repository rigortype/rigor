# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Builtins
    # Refined types for predefined Ruby / stdlib constants whose upstream
    # RBS signatures are broader than the constants' documented runtime
    # invariants.
    #
    # Resolution is two-tiered:
    #
    # **Tier 1 — exact-value whitelist** (`FOLDED_CONSTANTS`):
    # Constants whose value is bit-for-bit identical across every Ruby
    # version and platform are folded to `Constant[T]`: the `Math::PI`
    # / `Math::E` math constants (C's `M_PI` / `M_E`) and the four
    # IEEE 754 binary64 magnitude constants `Float::INFINITY` /
    # `::MAX` / `::MIN` / `::EPSILON` (each a single format-mandated bit
    # pattern). Add new entries only when the value is truly
    # cross-implementation invariant AND compares reflexively under
    # `==` — the latter is why `Float::NAN` is deliberately EXCLUDED:
    # `NaN == NaN` is `false`, so a `Constant[NAN]` would violate the
    # `Type::Constant` `==` / `eql?` / `hash` contract (it would hash
    # equal to itself yet compare unequal), corrupting type-equality
    # and union dedup. The binary64 *integer* shape parameters
    # (`Float::DIG` / `MANT_DIG` / `MAX_EXP` / …) are intentionally NOT
    # folded: upstream RBS hedges them as "Usually defaults to …", and
    # as plain `Integer`s they fall through Tier 2 to the RBS type
    # harmlessly. `Complex::I` is deferred (no complex-fold consumer).
    #
    # **Tier 2 — runtime String inspection**:
    # For any other constant, the module resolves it via `const_get`
    # against the analyzer's own Ruby runtime.  Core / stdlib constants
    # (e.g. `RUBY_VERSION`, `RUBY_PLATFORM`) are always loaded into the
    # analyzer process; project-defined constants are not (they live only
    # in ASTs), so their `const_get` raises `NameError` and the lookup
    # falls through to the RBS type tier.
    #
    # For a successfully resolved `String` value:
    # - empty string  → no refinement (fall through to RBS `String`)
    # - a Ruby numeric literal  → `numeric-string`
    # - non-empty otherwise  → `non-empty-string`
    #
    # **Exclusion set** (`RUNTIME_INSPECTION_EXCLUDED`):
    # String constants that appear non-empty in the current runtime but
    # are documented to be potentially empty in some build configuration
    # or alternative implementation.  Exclusions are populated by
    # scanning Ruby's C source (version.c, etc.) and RBS comments for
    # any constant whose documentation says "may be empty" or
    # "platform-specific default".  None are known today; the set
    # exists as a safety net.
    #
    # This module is consulted by `Environment#constant_for_name` BEFORE
    # the RBS constant-type table (widest types) but AFTER in-source
    # constant writes (the user's own `Math::PI = 0.0` takes precedence
    # via the lexical-candidate walk in `ExpressionTyper`).
    module PredefinedConstantRefinements
      # --- tier 1 -------------------------------------------------------

      # Exact-value fold whitelist.  Keys are unqualified constant paths
      # (no leading "::") matching what `Environment#constant_for_name`
      # receives.
      FOLDED_CONSTANTS = {
        # Math module — IEEE 754 bit-identical across all MRI / JRuby /
        # TruffleRuby builds; folding enables precise constant arithmetic.
        "Math::PI" => Type::Combinator.constant_of(::Math::PI).freeze,
        "Math::E" => Type::Combinator.constant_of(::Math::E).freeze,

        # Float magnitude limits — each a single format-mandated IEEE 754
        # binary64 bit pattern (`+Inf`, `DBL_MAX`, `DBL_MIN`,
        # `DBL_EPSILON`), reflexive under `==`. `Float::NAN` is excluded
        # (non-reflexive `==` — see the module-level note).
        "Float::INFINITY" => Type::Combinator.constant_of(::Float::INFINITY).freeze,
        "Float::MAX" => Type::Combinator.constant_of(::Float::MAX).freeze,
        "Float::MIN" => Type::Combinator.constant_of(::Float::MIN).freeze,
        "Float::EPSILON" => Type::Combinator.constant_of(::Float::EPSILON).freeze
      }.freeze
      private_constant :FOLDED_CONSTANTS

      # --- tier 2 -------------------------------------------------------

      # String constants whose runtime value is non-empty in the current
      # Ruby but that should NOT be narrowed because they are documented
      # to be potentially empty in some build or implementation.
      #
      # Methodology: grep Ruby's version.c and similar C sources, and the
      # RBS comment corpus, for any constant annotated with "may be empty"
      # or "platform-specific default".  Add the full qualified path
      # (without leading "::") when a genuine risk is found.
      RUNTIME_INSPECTION_EXCLUDED = Set[].freeze
      private_constant :RUNTIME_INSPECTION_EXCLUDED

      NON_EMPTY_STRING = Type::Combinator.non_empty_string.freeze
      NUMERIC_STRING   = Type::Combinator.numeric_string.freeze
      private_constant :NON_EMPTY_STRING, :NUMERIC_STRING

      # --- public API ---------------------------------------------------

      # @param name [String] unqualified constant name (e.g. `"Math::PI"`,
      #   `"RUBY_VERSION"`, `"Ruby::ENGINE"`)
      # @return [Rigor::Type, nil] refined type, or nil to fall through
      def self.lookup(name)
        FOLDED_CONSTANTS[name] || inspect_runtime_string(name)
      end

      # --- private ------------------------------------------------------

      # Resolves `name` via `const_get` in the analyzer's runtime and
      # returns a refined String carrier, or nil.
      def self.inspect_runtime_string(name)
        return nil if RUNTIME_INSPECTION_EXCLUDED.include?(name)

        parts = name.split("::")
        value = parts.reduce(::Object) { |mod, part| mod.const_get(part, false) }

        return nil unless value.is_a?(::String) && !value.empty?

        classify_string(value)
      rescue ::NameError, ::TypeError
        nil
      end
      private_class_method :inspect_runtime_string

      # @param value [String] a non-empty string
      # @return [Rigor::Type]
      def self.classify_string(value)
        if Type::Refined.ruby_numeric_literal?(value)
          NUMERIC_STRING
        else
          NON_EMPTY_STRING
        end
      end
      private_class_method :classify_string
    end
  end
end
