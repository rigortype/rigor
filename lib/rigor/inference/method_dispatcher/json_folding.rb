# frozen_string_literal: true

require_relative "../../type"
require_relative "singleton_folding"

module Rigor
  module Inference
    module MethodDispatcher
      # Folds `JSON.generate` / `JSON.pretty_generate` to their precise return type.
      #
      # Both methods always return a `String` or raise (`JSON::GeneratorError`, `JSON::NestingError`, …) —
      # never `nil`, never a non-`String` value. Upstream RBS (`stdlib/json/0/json.rbs`) already declares
      # `generate` as `-> String`, but `pretty_generate` is declared `-> untyped`, so every
      # `JSON.pretty_generate` call widens to `Dynamic[top]` and every downstream method call on the result
      # loses precision with it. This tier closes that gap by construction rather than waiting on an
      # upstream RBS fix, and folds `generate` alongside it for symmetry — a `Nominal[String]` answer here
      # is monotone over both today's `untyped` (`pretty_generate`) and today's already-precise `String`
      # (`generate`).
      #
      # Unlike `CGIFolding` / `ShellwordsFolding`, this tier does NOT evaluate the argument. `JSON.generate`
      # is not a pure function whose *result* can be computed at analysis time in general — the object graph
      # can be arbitrarily large, cyclic, or rely on a user-defined `#to_json` — so only the *return type* is
      # folded here, never the *return value*. A future literal-argument constant fold (mirroring
      # `ConstantFolding`'s treatment of other pure stdlib calls) can layer on top of this tier without
      # changing it.
      #
      # === Supported methods
      #
      # * `generate(obj)` / `generate(obj, opts)` — returns `Nominal[String]`.
      # * `pretty_generate(obj)` / `pretty_generate(obj, opts)` — returns `Nominal[String]`.
      #
      # === Unsupported cases
      #
      # Returns `nil` (deferring to the next dispatcher tier) when:
      # - the receiver is not `Singleton[JSON]`,
      # - the method is not `generate` / `pretty_generate` (e.g. `JSON.parse`, `JSON.dump`),
      # - the call has the wrong arity (not 1 or 2 positional arguments).
      module JSONFolding
        JSON_GENERATE_METHODS = Set[:generate, :pretty_generate].freeze
        private_constant :JSON_GENERATE_METHODS

        module_function

        # @rbs return: Rigor::Type? -- Folded result, or nil to defer.
        def try_dispatch(context)
          receiver = context.receiver
          method_name = context.method_name
          args = context.args
          return nil unless SingletonFolding.receiver?(receiver, "JSON")
          return nil unless JSON_GENERATE_METHODS.include?(method_name)
          return nil unless args.size.between?(1, 2)

          Type::Combinator.nominal_of("String")
        end
      end
    end
  end
end
