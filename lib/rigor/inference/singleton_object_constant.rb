# frozen_string_literal: true

require_relative "../source/constant_path"

module Rigor
  module Inference
    # Issue #320 — the *private-singleton-object* idiom: a constant holds a plain object whose singleton
    # class carries the methods.
    #
    #     class << Merger = Object.new
    #       def merge_attributes!(a, b) = a
    #     end
    #     Merger.merge_attributes!({}, {})
    #
    # {ScopeIndexer} already records such a body under the constant's own name with kind `:singleton` — that
    # keying is correct for both spellings, since `Foo.bar` means "call `bar` on the value of constant `Foo`"
    # whether the value is a class object or an ordinary object. The gap is on the *receiver* side: when the
    # constant names a class or module the read types as `Singleton[Foo]` and dispatch recovers the name from
    # the type, but when it holds an ordinary object the read types as `Nominal[Object]` and the name is
    # gone — so every method in the body is invisible and `call.undefined-method` fires on working code.
    #
    # This module recovers the name from the receiver *syntax* instead, for exactly the receivers whose type
    # has lost it. `Singleton` receivers are excluded so the established class/module path keeps its
    # precedence; a receiver whose constant has no recorded singleton body yields nil, so an undefined method
    # on such a constant (`Merger.nope`) still fires.
    module SingletonObjectConstant
      module_function

      # The constant name a call's receiver names, when that receiver is a constant reference whose type is
      # not already a `Singleton` carrier. Nil for every other receiver shape.
      def receiver_constant_name(call_node, receiver_type)
        return nil if receiver_type.is_a?(Type::Singleton)

        receiver = call_node.receiver
        return nil unless receiver.is_a?(Prism::ConstantReadNode) || receiver.is_a?(Prism::ConstantPathNode)

        Source::ConstantPath.qualified_name(receiver)
      end

      # True when the project recorded `method_name` on the singleton side of the constant this call's
      # receiver names. The suppression probe for `call.undefined-method`.
      def recorded?(call_node, receiver_type, method_name, scope)
        return false if scope.nil?

        name = receiver_constant_name(call_node, receiver_type)
        return false if name.nil?

        scope.discovered_method?(name, method_name, :singleton)
      end

      # The `Prism::DefNode` for `method_name` in the constant's singleton body, or nil. The inference tier's
      # entry point.
      def def_node_for(call_node, receiver_type, method_name, scope)
        return nil if scope.nil?

        name = receiver_constant_name(call_node, receiver_type)
        return nil if name.nil?

        scope.singleton_def_for(name, method_name)
      end
    end
  end
end
