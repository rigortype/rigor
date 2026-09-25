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
      end
    end
  end
end
