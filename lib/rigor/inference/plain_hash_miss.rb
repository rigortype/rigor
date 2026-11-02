# frozen_string_literal: true

require "prism"
require_relative "../type"

module Rigor
  module Inference
    # Issue #2555 L3, slice 2 — the one carve-out from `RbsDispatch` reading past `Hash#[]`'s
    # `%a{implicitly-returns-nil}` (docs/internal-spec/inference-engine.md § "That deferred-to answer is nil-free for
    # a lookup that can miss").
    #
    # The optimism exists because the type cannot tell a plain Hash from one with a default: `Hash.new(0)`,
    # `Hash.new { }` and a `default_proc` never miss, and honouring the annotation wholesale drew 25 false positives
    # on Rigor's own `lib/`. A local whose binding carries the `:synthesised` construction fact
    # ({Scope#construction_fact?}) and not `:defaulted` is a Hash this body built itself, with no default (a literal,
    # `Hash.new` with no argument or block, `Hash[...]`), that has not escaped ({ConstructionEscape}) and that no
    # `default=` / `default_proc=` / `replace` has given a default since ({MutationWidening::DEFAULTING_MUTATORS}). A
    # miss on it answers `nil`, so `h[k]` reads `V | nil`, and `RbsDispatch` records no {OptimisticOrigin} mark for it.
    #
    # Every other receiver keeps the optimistic `V`: a parameter, an RBS return, an instance variable, a constant, a
    # method result, an escaped local, and a local whose fact a join dropped. So does a gradual `V` (`Hash.new` with no
    # evidence reads `Dynamic[top]`, which a `nil` arm would only decorate), and a receiver that is not exactly the
    # `Hash` nominal (or a union of them): a `HashShape` answers through the shape tier, which already adds the `nil`
    # for a computed key on a closed shape, and a union with any other member is left alone.
    module PlainHashMiss
      module_function

      # Whether the call `node`, typed under `scope`, is a `Hash#[]` read the carve-out answers `V | nil`.
      def applies?(node, scope)
        return false unless node.is_a?(Prism::CallNode) && node.name == :[] && !node.safe_navigation?
        return false unless node.block.nil? && single_positional_argument?(node)

        receiver = node.receiver
        return false unless receiver.is_a?(Prism::LocalVariableReadNode)

        name = receiver.name
        return false unless scope.construction_fact?(name) && !scope.construction_fact?(name, :defaulted)

        plain_hash?(scope.local(name))
      end

      # `type` with the miss's `nil` joined, or `type` itself when the value side is gradual.
      def with_miss(type)
        return type if type.is_a?(Type::Dynamic)

        Type::Combinator.union(type, Type::Combinator.constant_of(nil))
      end

      def single_positional_argument?(node)
        arguments = node.arguments&.arguments
        !arguments.nil? && arguments.size == 1 &&
          !arguments.first.is_a?(Prism::SplatNode) && !arguments.first.is_a?(Prism::KeywordHashNode) &&
          !arguments.first.is_a?(Prism::BlockArgumentNode)
      end

      # The `Hash` nominal, or a union of nothing else (the join of two literal arms).
      def plain_hash?(type)
        return type.members.all? { |member| hash_nominal?(member) } if type.is_a?(Type::Union)

        hash_nominal?(type)
      end

      def hash_nominal?(type)
        type.is_a?(Type::Nominal) && type.class_name == "Hash" && type.type_args.size == 2
      end
    end
  end
end
