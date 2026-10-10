# frozen_string_literal: true

module Rigor
  module Inference
    module MethodDispatcher
      # How `OverloadSelector` reads a call whose positional arguments include a splat (`f(*xs, a: v)`), #1801.
      #
      # A splat stands for any number of arguments, so the call's positional count is not known statically. The
      # selector sees each splat as one untyped entry of the argument list, and counted that way it ruled out every
      # overload whose arity the splat may still meet: `ph(*xs, a: "s")` skipped `(Hash[Symbol, String]) -> String`,
      # which takes `{ a: "s" }` when `xs` is empty (`def ph(h) = h; ph(*[], a: "s")` is `{ a: "s" }`). Instead, an
      # overload matches when some count of the splats' elements fits its arity and every argument, the splats'
      # untyped elements included, is accepted at the parameter that count binds it to.
      module SplatArity
        # The most argument lists {.expansions} spells out; past it, the overload is matched by arity alone.
        LIMIT = 32
        private_constant :LIMIT

        module_function

        # The argument lists `arg_types` stands for against `fun`, each splat entry (at `splats`, indices into
        # `arg_types`) repeated as often as `fun`'s positional parameters can take, from none upward; nil past
        # {LIMIT}. An untyped `(?)` parameter list takes any count, so the list as given stands for all of them.
        def expansions(fun, arg_types, splats)
          return [arg_types] unless fun.respond_to?(:required_positionals)

          indices = splats.select { |index| index < arg_types.size }
          return [arg_types] if indices.empty?

          bound = element_bound(fun, arg_types.size - indices.size)
          counts = counts(indices.size, bound)
          return nil if counts.nil?

          counts.map { |count| expand(arg_types, indices, count) }
        end

        # The most splat elements a call with `fixed` other positional arguments can pass to `fun`: up to its maximum
        # arity, or, with a `*rest`, one past filling every other parameter, since further elements land in the rest
        # parameter alike.
        def element_bound(fun, fixed)
          declared = fun.required_positionals.size + fun.optional_positionals.size + fun.trailing_positionals.size
          return declared + 1 if fun.rest_positionals

          [declared - fixed, 0].max
        end

        # Every way to give `splats` splats at most `bound` elements in all, or nil past {LIMIT}.
        def counts(splats, bound)
          combinations = [[]]
          splats.times do
            combinations = combinations.flat_map do |partial|
              (0..(bound - partial.sum)).map { |count| partial + [count] }
            end
            return nil if combinations.size > LIMIT
          end
          combinations
        end

        def expand(arg_types, indices, counts)
          expanded = []
          arg_types.each_with_index do |arg, index|
            position = indices.index(index)
            position ? expanded.concat([arg] * counts[position]) : expanded << arg
          end
          expanded
        end
      end
    end
  end
end
