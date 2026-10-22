# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module CheckRules
      module RebindingBlockCallees
        # Which method a block call reaches, and on what receiver: `callee_may_rebind?` reads the callee name, a
        # callable receiver, and whether Ruby can reach `method_missing` from here.
        module Dispatch
          # Issue #2186 — a block given to `call` / `bind_call` (or `yield` / `===` / `[]`) on a literal `method(:x)`
          # chain goes to the method it names: `Ext.method(:me).call { … }` is `Ext.me { … }`. On a receiver typed as
          # one of CALLABLE_CLASSES it goes to a callable Rigor cannot follow; on any other receiver it is a call by
          # that name.
          METHOD_OBJECT_CALLS = %i[call yield === [] bind_call].freeze
          METHOD_READERS = %i[method public_method singleton_method instance_method public_instance_method].freeze
          # The readers whose receiver is the object the named method runs on.
          BOUND_METHOD_READERS = %i[method public_method singleton_method].freeze
          METHOD_WRAPPERS = %i[bind unbind to_proc curry].freeze
          CALLABLE_CLASSES = %w[Method UnboundMethod Proc].freeze
          private_constant :METHOD_READERS, :BOUND_METHOD_READERS, :METHOD_WRAPPERS, :CALLABLE_CLASSES

          module_function

          # `[name, receiver]` of the method the block reaches: the call's own name, the literal name a `send` family
          # call dispatches to, or the method a literal `method(:name)` chain names. The receiver is a node, `:implicit`
          # for a receiverless call, or nil where Rigor cannot say (an `instance_method` chain). The name is nil when a
          # `send` names its method with anything but a valid literal.
          def dispatch(call)
            reader = method_reader(call.receiver) if METHOD_OBJECT_CALLS.include?(call.name)
            if reader
              receiver = reader.receiver || :implicit if BOUND_METHOD_READERS.include?(reader.name)
              return [RebindingBlockCallees.literal_name(reader.arguments&.arguments&.first), receiver]
            end
            [RebindingBlockCallees.send_target(call), call.receiver || :implicit]
          end

          def method_reader(receiver)
            receiver = receiver.receiver while wrapper?(receiver)
            receiver if receiver.is_a?(Prism::CallNode) && METHOD_READERS.include?(receiver.name)
          end

          # Whether `receiver` may be a Method, UnboundMethod or Proc, whose `call` runs a callable Rigor cannot follow.
          def callable?(receiver, scope, scope_index)
            return false unless receiver.is_a?(Prism::Node)

            type = receiver_type(receiver, scope, scope_index)
            members = type.is_a?(Type::Union) ? type.members : [type]
            members.any? do |member|
              member.is_a?(Type::BoundMethod) ||
                (member.is_a?(Type::Nominal) && CALLABLE_CLASSES.include?(member.class_name.to_s))
            end
          end

          def wrapper?(node) = node.is_a?(Prism::CallNode) && METHOD_WRAPPERS.include?(node.name)

          # A `call` (or the like) on a receiver that may be a Method, UnboundMethod or Proc.
          def callable_call?(name, receiver, scope, scope_index)
            METHOD_OBJECT_CALLS.include?(name) && callable?(receiver, scope, scope_index)
          end

          def receiver_type(receiver, scope, scope_index)
            (scope_index&.[](receiver) || scope).type_of(receiver)
          rescue StandardError
            nil
          end

          # Whether the receiver's type names a class whose RBS or project table gives it `name`, on every member of a
          # union. A receiverless call at the top level asks `Object`, `main`'s class. Any other type cannot say.
          def resolves_on_receiver?(receiver, name, scope, scope_index)
            return scope.toplevel? && class_defines?("Object", :instance, name, scope) if receiver == :implicit
            return false if receiver.nil?

            type = receiver_type(receiver, scope, scope_index)
            !type.nil? && type_resolves?(type, name, scope)
          rescue StandardError
            false
          end

          def type_resolves?(type, name, scope)
            case type
            when Type::Union then type.members.all? { |member| type_resolves?(member, name, scope) }
            when Type::Singleton then class_defines?(type.class_name, :singleton, name, scope)
            else
              class_name = receiver_class_name(type)
              !class_name.nil? && class_defines?(class_name, :instance, name, scope)
            end
          end

          def receiver_class_name(type)
            case type
            when Type::Nominal, Type::StructInstance, Type::DataInstance then type.class_name&.to_s
            when Type::Tuple then "Array"
            when Type::HashShape then "Hash"
            when Type::Constant then type.value.class.name
            end
          end

          def class_defines?(class_name, side, name, scope)
            rbs = if side == :singleton
                    Rigor::Reflection.singleton_method_definition(class_name, name, scope: scope)
                  else
                    Rigor::Reflection.instance_method_definition(class_name, name, scope: scope)
                  end
            !rbs.nil? || scope.discovered_method?(class_name, name, side)
          end
        end
      end
    end
  end
end
