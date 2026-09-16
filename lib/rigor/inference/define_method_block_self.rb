# frozen_string_literal: true

require_relative "../type"

module Rigor
  module Inference
    # Issue #963 — the lexical `self` of a `define_method(:name) { ... }` block.
    #
    # A block has no `self` of its own, so every block body enters with `Scope#entering_opaque_block`
    # and the enclosing class body's `self_type` (`Singleton[C]`) rides along unchanged. For
    # `define_method` that carrier is the wrong side of the class: `Module#define_method` turns the
    # block into an INSTANCE method of the receiver, and Ruby runs its body with `self` bound to the
    # receiving instance. A bare `text` inside the block therefore reaches `C`'s member / attr reader,
    # while `Singleton[C]` answers only `C`'s class methods.
    #
    # The consequence #963 records is #618's veto going the wrong way: `ExpressionTyper#self_type_answers?`
    # asked the singleton side, found nothing, and let a same-named top-level `def text` bind ahead of the
    # reader — typing `text.upcase` inside `class Line < Struct.new(:text); define_method(:shout) { text.upcase }`
    # as the top-level def's `nil`. Narrowing the block body's `self_type` to `Nominal[C]` makes the
    # existing veto ask the instance side, which is the side Ruby dispatches on; nothing in the veto
    # itself changes.
    #
    # The match is deliberately narrow — the receiver must be the class body's own `self`, and that
    # `self` must be a known `Singleton[C]` on the instance side of the class. `class << self` bodies
    # (where `define_method` defines a CLASS method) and `Foo.define_method(...)` on some other receiver
    # keep the unmodelled-self answer.
    module DefineMethodBlockSelf
      module_function

      # @return the block body's narrowed `self_type`, or `nil` when the call shape does not match.
      def narrow_self_type_for(scope:, call_node:, singleton_body: false)
        return nil if singleton_body
        return nil unless define_method_on_lexical_self?(call_node)

        self_type = scope&.self_type
        return nil unless self_type.is_a?(Type::Singleton)

        class_name = self_type.class_name
        return nil if class_name.nil?

        instance_type_for(class_name, scope.environment)
      end

      def define_method_on_lexical_self?(call_node)
        return false unless call_node.is_a?(Prism::CallNode)
        return false unless call_node.name == :define_method

        call_node.receiver.nil? || call_node.receiver.is_a?(Prism::SelfNode)
      end

      def instance_type_for(class_name, environment)
        environment&.nominal_for_name(class_name) || Type::Nominal.new(class_name)
      end
    end
  end
end
