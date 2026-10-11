# frozen_string_literal: true

module Rigor
  module Inference
    module MethodDispatcher
      module OverloadSelector
        # Canonical RBS-core aliases shipped by `core/builtin.rbs` whose body is `<Nominal> | _DuckType`.
        # Matching an overload against an Integer literal should pick the `(int) -> Array[Elem]` body over
        # the `(string) -> String` body because Integer satisfies `int`'s strict arm and not `string`'s.
        # The translator collapses both aliases to `Dynamic[Top]` (interfaces are not structurally matched
        # yet), so a dedicated pass 1.5 between strict and gradual consults this map to pick the alias
        # whose strict arm matches.
        #
        # Symbol keys are the alias names as they appear under `RBS::Types::Alias#name.to_s` (the `name` is
        # a `TypeName` whose `to_s` includes the `::` prefix). Values are an Array of class names whose
        # Nominal[..] form is the alias's strict-arm matcher.
        #
        # `range[T] = Range[T] | _Range[T]` is generic, unlike the others, but its strict arm is still a single
        # nominal and the args are irrelevant to this pass. rbs 4.1 rewrote `Array#[]`'s slicing overload from
        # `(::Range[::Integer?])` to `(range[int])`; without the entry both it and the `(int) -> E` overload look
        # alias-typed, so `a[1..2]` resolved to the element type.
        ALIAS_STRICT_NOMINALS = Ractor.make_shareable({
                                                        "::int" => ["Integer"],
                                                        "::string" => ["String"],
                                                        "::interned" => %w[Symbol String],
                                                        "::io" => ["IO"],
                                                        "::encoding" => %w[Encoding String],
                                                        "::path" => ["String"],
                                                        "::boolean" => %w[TrueClass FalseClass],
                                                        "::range" => ["Range"]
                                                      })
        private_constant :ALIAS_STRICT_NOMINALS

        class << self
          private

          # Checks the param's RBS type against an arg using alias-strict-arm matching. Optional / Union
          # wrappers are flattened; alias resolution is one level deep (the canonical core aliases all have
          # non-alias strict arms).
          def alias_param_accepts?(rbs_type, arg)
            nominal_names = strict_nominal_names_for(rbs_type)
            return false if nominal_names.nil? || nominal_names.empty?

            nominal_names.any? do |class_name|
              result = Type::Combinator.nominal_of(class_name).accepts(arg, mode: :gradual)
              result.yes? || result.maybe?
            end
          end

          # Returns the candidate class names a param's RBS type accepts under alias-resolved strict
          # matching, or nil when the shape cannot be reduced to a closed set of nominals (e.g. an
          # Interface or an unrecognised alias).
          def strict_nominal_names_for(rbs_type)
            case rbs_type
            when RBS::Types::ClassInstance
              [rbs_type.name.to_s.delete_prefix("::")]
            when RBS::Types::Alias
              ALIAS_STRICT_NOMINALS[rbs_type.name.to_s]
            when RBS::Types::Optional
              strict_nominal_names_for(rbs_type.type)
            when RBS::Types::Union
              parts = rbs_type.types.map { |t| strict_nominal_names_for(t) }
              return nil if parts.any?(&:nil?)

              parts.flatten
            end
          end
        end
      end
    end
  end
end
