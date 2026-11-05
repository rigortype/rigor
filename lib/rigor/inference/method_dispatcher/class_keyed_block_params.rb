# frozen_string_literal: true

require_relative "../../type"

module Rigor
  module Inference
    module MethodDispatcher
      # Issue #2686 — `Rigor::Plugin::Base.node_rule(node_class) { |node, ...| }` yields instances of the class it is
      # given, which RBS cannot say: `[N < ::Prism::Node] (singleton(N))` does not resolve (RBS has no
      # `singleton(<type variable>)`). `sig/rigor/plugin/base.rbs` declares per-class overloads for the classes
      # the bundled plugins register and a `Prism::Node` fallback. Read through the overloads alone, two calls bind
      # `node` wrong:
      #
      # - a class with no overload of its own (`node_rule(Prism::IfNode)`) takes the fallback, so `node` is
      #   `Prism::Node` and `node.predicate` reported `call.undefined-method`;
      # - a class argument the engine cannot read (`def self.reg(k) = node_rule(k) { ... }`) matches every overload
      #   gradually, and the block probe took the first, `Prism::CallNode`.
      #
      # This rebinds the block's first parameter from the class argument:
      #
      # - `singleton(X)` binds `X`, and a union of class objects the union of their instances;
      # - any other argument (an untyped parameter, a `Class` value) binds `Dynamic[top]`, so the body is not
      #   checked against a class the call may not register.
      #
      # The rest of the block's parameters keep the overload's binding; every overload declares them alike.
      #
      # A per-class overload set generated from Prism's node classes was the alternative. It was declined: the
      # gemspec admits `prism >= 1.0, < 2.0`, and a generated set names classes later minors added, which an older
      # Prism's RBS does not declare, so loading Rigor's own `sig/` would fail there.
      #
      # Only the declaration Rigor owns is read, by the method's RBS owner, so a project's own `node_rule` is not.
      module ClassKeyedBlockParams
        OWNER = "::Rigor::Plugin::Base"
        METHOD = :node_rule
        private_constant :OWNER, :METHOD

        module_function

        # @param method_definition — the RBS declaration the probe read.
        # @param params — the block parameters the overloads bound.
        # @return the block parameters, the first rebound for `Base.node_rule`.
        def rebind(method_definition, method_name, args, params)
          return params unless method_name == METHOD
          return params unless method_definition.defined_in.to_s == OWNER

          [instance_of(args.first), *params.drop(1)]
        end

        # The instances the class argument names, or `Dynamic[top]`.
        def instance_of(arg)
          case arg
          when Type::Singleton
            Type::Combinator.nominal_of(arg.class_name)
          when Type::Union
            return Type::Combinator.untyped unless arg.members.all?(Type::Singleton)

            Type::Combinator.union(*arg.members.map { |member| Type::Combinator.nominal_of(member.class_name) })
          else
            Type::Combinator.untyped
          end
        end
      end
    end
  end
end
