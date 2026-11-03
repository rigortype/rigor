# frozen_string_literal: true

require "rbs"

require_relative "../reflection"
require_relative "../type"

module Rigor
  module Inference
    # Issue #2685 — whether a no-argument call `x.r` reads a stored attribute, so a truthiness or `nil?` guard
    # on it may carry to the next `x.r` read ({Narrowing}'s single-hop chain narrowing).
    #
    # It does when, for every non-nil member of the receiver's type, the RBS of that class or one of its
    # RBS ancestors declares `r` with `attr_reader` or `attr_accessor`, and no project `def` can answer `r`
    # instead ({ExpressionTyper#instance_method_redefined_in_project?}). An attribute returns the instance
    # variable it reads, so two reads with no write between them agree. A method declared with `def` carries
    # no such promise (`queue.pop`, `io.gets`) and stays un-narrowed, as does a receiver Rigor cannot name
    # (`Dynamic`, an interface, a project class with no RBS).
    #
    # A `nil` member is skipped: on it the plain call raises and the `&.` call returns `nil` without calling
    # `r`, so neither reaches a guarded re-read with a value the guard did not see.
    #
    # The rule reads only RBS, so an `attr_reader` written in project Ruby without a signature does not
    # qualify; that is a follow-up, not part of this rule.
    module AttributeReaderChain
      ATTRIBUTE_MEMBERS = [::RBS::AST::Members::AttrReader, ::RBS::AST::Members::AttrAccessor].freeze
      private_constant :ATTRIBUTE_MEMBERS

      module_function

      # @param call_node — a no-argument, block-free `Prism::CallNode` rooted at a local or instance variable
      #   ({Narrowing}'s stable chain address has already been checked).
      def attribute_read?(call_node, scope)
        receiver_type = scope.type_of(call_node.receiver)
        members = receiver_type.is_a?(Type::Union) ? receiver_type.members : [receiver_type]
        owners = members.reject { |member| member.is_a?(Type::Constant) && member.value.nil? }
        return false if owners.empty?

        owners.all? { |member| attribute_owner?(member, call_node.name, scope) }
      end

      def attribute_owner?(member, method_name, scope)
        return false unless member.is_a?(Type::Nominal)

        declared_attribute?(member.class_name, method_name, scope) &&
          !ExpressionTyper.new(scope: scope).instance_method_redefined_in_project?(member.class_name, method_name)
      end

      def declared_attribute?(class_name, method_name, scope)
        definition = Rigor::Reflection.instance_method_definition(class_name, method_name, scope: scope)
        return false if definition.nil? || definition.defs.empty?

        definition.defs.all? { |type_def| ATTRIBUTE_MEMBERS.any? { |klass| type_def.member.is_a?(klass) } }
      rescue ::RBS::BaseError
        false
      end
    end
  end
end
