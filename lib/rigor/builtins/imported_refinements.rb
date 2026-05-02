# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Builtins
    # Canonical-name registry for the imported-built-in
    # refinement catalogue. See `imported-built-in-types.md`
    # in `docs/type-specification/` for the full catalogue
    # rationale and the kebab-case naming rule.
    #
    # Maps kebab-case names (`non-empty-string`, `positive-int`,
    # `non-empty-array`, …) to the Rigor type each name denotes.
    # The registry is the single integration point for:
    #
    # - The new `rigor:v1:return:` RBS::Extended directive
    #   ([`Rigor::RbsExtended.read_return_type_override`](../rbs_extended.rb)),
    #   which overrides a method's RBS-declared return type
    #   with a refinement carrier.
    # - Future `RBS::Extended` directives that accept a
    #   refinement name in any type position (`param:`,
    #   `assert: x is non-empty-string`, …).
    # - The display side: `Type::Difference#describe` already
    #   recognises the same shapes and prints the kebab-case
    #   spelling without consulting the registry.
    #
    # Names not in the registry resolve to `nil`; callers
    # decide whether to fall back to the RBS-declared type or
    # raise a parse error.
    #
    # The current registry covers no-argument refinement
    # names — both the point-removal half (`non-empty-string`,
    # `non-zero-int`, …) and the predicate-subset half
    # (`lowercase-string`, `uppercase-string`, `numeric-string`)
    # of the OQ3 refinement-carrier strategy. Parameterised
    # refinements like `non-empty-array[Integer]` and bounded
    # ranges like `int<5, 10>` will be parsed by a future
    # tokeniser; today the no-arg form `non-empty-array` lands
    # at `non_empty_array(top)` and downstream code projects to
    # the underlying base nominal.
    module ImportedRefinements
      REGISTRY = {
        "non-empty-string" => -> { Type::Combinator.non_empty_string },
        "non-zero-int" => -> { Type::Combinator.non_zero_int },
        "non-empty-array" => -> { Type::Combinator.non_empty_array },
        "non-empty-hash" => -> { Type::Combinator.non_empty_hash },
        "positive-int" => -> { Type::Combinator.positive_int },
        "non-negative-int" => -> { Type::Combinator.non_negative_int },
        "negative-int" => -> { Type::Combinator.negative_int },
        "non-positive-int" => -> { Type::Combinator.non_positive_int },
        "lowercase-string" => -> { Type::Combinator.lowercase_string },
        "uppercase-string" => -> { Type::Combinator.uppercase_string },
        "numeric-string" => -> { Type::Combinator.numeric_string }
      }.freeze
      private_constant :REGISTRY

      module_function

      # @param name [String] kebab-case refinement name.
      # @return [Rigor::Type, nil] the matching refinement
      #   carrier, or `nil` if the name is not registered.
      def lookup(name)
        builder = REGISTRY[name.to_s]
        builder&.call
      end

      def known?(name)
        REGISTRY.key?(name.to_s)
      end

      def known_names
        REGISTRY.keys
      end
    end
  end
end
