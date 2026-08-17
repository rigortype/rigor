# frozen_string_literal: true

require "prism"

require_relative "../inference/mutation_widening"
require_relative "label_set"

module Rigor
  module Effects
    # Decides whether a call mutates its receiver, and — when it does — which `mutate.*` label that earns
    # (ADR-103 WD4 / WD14).
    #
    # Two independent questions, both answered conservatively:
    #
    # 1. **Is this a mutation?** Only when the selector says so beyond doubt. `[]=` and an attribute writer
    #    are writes on every receiver; `<<` and the bang family are claimed only when the typer named the
    #    receiver's class, because `n << 2` is a bit shift and `io << "x"` is output. A wrong label in the
    #    proven lane is worse than a missing one — the proven lane is the one a verdict may read (ADR-5).
    # 2. **Who owns the receiver?** `self` and its ivars are `mutate.self` (`mutate.static` in singleton
    #    context), a class variable is `mutate.static`, a parameter is `mutate.instance`, a frame-owned
    #    local is `mutate.local`. **Anything else answers nil**, and the caller records an
    #    `unknown-ownership` taint rather than a proven bare `mutate`: Ruby's ownership is a dataflow
    #    question, and a proven parent label on a fresh-but-unproven receiver would put findings on correct
    #    code (WD14).
    class MutationClassifier
      # The only selectors a mutation may be claimed from without knowing the receiver's class.
      UNIVERSAL_MUTATORS = %i[[]=].to_set.freeze

      # `String`'s receiver-mutating surface. `Array` / `Hash` reuse the hand-audited sets the widening
      # rules already maintain, cited rather than re-derived (ADR-103 WD3).
      STRING_MUTATORS = %i[
        << concat replace insert prepend clear
        upcase! downcase! capitalize! swapcase! reverse!
        strip! lstrip! rstrip! chomp! chop! squeeze! succ! next!
        sub! gsub! tr! tr_s! delete! slice! []=
      ].to_set.freeze

      # `foo=`, and deliberately not `==` / `<=` / `!=` / `===`.
      ATTRIBUTE_WRITER = /\A[a-z_][A-Za-z0-9_]*=\z/

      LABELS = {
        self_state: LabelSet.new(["mutate.self"]),
        static: LabelSet.new(["mutate.static"]),
        instance: LabelSet.new(["mutate.instance"]),
        local: LabelSet.new(["mutate.local"])
      }.freeze

      def initialize(singleton:, parameters:, owned_locals:)
        @singleton = singleton
        @parameters = parameters
        @owned_locals = owned_locals
      end

      # Whether `node` mutates its receiver. `receiver_class` is the class the typer projected the
      # receiver's type to, or nil when it projected to none.
      def mutating?(node, receiver_class)
        name = node.name
        return true if UNIVERSAL_MUTATORS.include?(name) || ATTRIBUTE_WRITER.match?(name.to_s)

        case receiver_class
        when "Array" then Inference::MutationWidening::ARRAY_MUTATORS.include?(name)
        when "Hash" then Inference::MutationWidening::HASH_MUTATORS.include?(name)
        when "String" then STRING_MUTATORS.include?(name)
        else false
        end
      end

      # The label a mutation of `receiver` earns, or nil when ownership is not provable.
      def label_for(receiver)
        LABELS[ownership(receiver)]
      end

      private

      def ownership(receiver)
        case receiver
        when nil, Prism::SelfNode, Prism::InstanceVariableReadNode
          @singleton ? :static : :self_state
        when Prism::ClassVariableReadNode then :static
        when Prism::LocalVariableReadNode then local_ownership(receiver.name.to_s)
        end
      end

      def local_ownership(name)
        return :instance if @parameters.include?(name)
        return :local if @owned_locals.include?(name)

        nil
      end
    end
  end
end
