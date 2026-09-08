# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # ADR-109 — the interval a random draw over a literal range lands in. `Random.rand` and
      # `Kernel#rand` advance a generator, so no call folds to a constant ({Builtins::RANDOM_CATALOG}
      # says why); but a draw over `a..b` returns a value the range covers, and that is a bounded
      # carrier of the range's own class, keeping its written end:
      #
      #   rand(1..6)              -> Integer[1..6]
      #   rand(1...6)             -> Integer[1..5]
      #   rand(0.0...1.0)         -> Float[0.0...1.0]
      #   Random.rand(1.0..2.0)   -> Float[1.0..2.0]
      #
      # An empty range (`rand(5..1)` returns nil, `Random.rand(5..1)` raises), an unbounded one
      # (`Errno::EDOM`) and a non-literal argument decline to the RBS envelope. The other argument
      # shapes (`rand`, `rand(n)`, `rand(1.5)`) are deliberately NOT folded: the corpus uses them as its
      # "unknown Integer / Float" oracle, and their intervals belong to a change that replaces that
      # oracle first. The `Kernel` spelling is folded by {KernelDispatch#try_rand} behind ADR-91's
      # ownership gate; this module owns `Singleton[Random]` and the shared interval reading.
      module RandomFolding
        module_function

        def try_dispatch(context)
          return nil unless SingletonFolding.receiver?(context.receiver, "Random")
          return nil unless context.method_name == :rand

          interval_for_args(context.args)
        end

        # The bounded carrier a one-argument draw over a literal range lands in, or `nil` for any other
        # argument shape.
        def interval_for_args(args)
          return nil unless args.size == 1

          arg = args.first
          return nil unless arg.is_a?(Type::Constant) && arg.value.is_a?(Range)

          range_interval(arg.value)
        end

        def range_interval(range)
          lower = range.begin
          upper = range.end
          return nil unless real_endpoint?(lower) && real_endpoint?(upper)

          if lower.is_a?(Integer) && upper.is_a?(Integer)
            integer_range_interval(lower, upper, range.exclude_end?)
          else
            float_range_interval(lower.to_f, upper.to_f, range.exclude_end?)
          end
        end

        # A finite Integer or Float; a missing end is `Errno::EDOM` at run time.
        def real_endpoint?(value)
          case value
          when Integer then true
          when Float then value.finite?
          else false
          end
        end

        def integer_range_interval(lower, upper, exclusive)
          upper -= 1 if exclusive
          return nil if lower > upper

          Type::Combinator.integer_range(lower, upper)
        end

        def float_range_interval(lower, upper, exclusive)
          return nil if lower > (exclusive ? upper.prev_float : upper)

          Type::Combinator.float_range(lower, upper, exclude_end: exclusive)
        end
      end
    end
  end
end
