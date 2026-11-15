# frozen_string_literal: true

require "prism"

require_relative "external_ancestor_resolution"

module Rigor
  module Inference
    # Whether a receiver's `send` is `Kernel#send`, the reflective call, rather than a method of the same name a
    # class defines for itself (`Mailer#send(message, flags)`, `UDPSocket#send(msg, flags)`). ADR-132 WD3: a
    # consumer that reads `recv.send(:m, …)` as `recv.m(…)` may do so only where the `send` is genuine, and
    # falls back to the ordinary call otherwise (issues #3080, #3081).
    #
    # `__send__` and `public_send` are separate methods and are not asked about here: their consumers keep the
    # reflective reading.
    #
    # A receiver is genuine when no project class or module on its chain defines `send` in source, and the RBS
    # declaration Ruby reaches (on the class, or through the project's ancestry to an external one) is
    # `Kernel`'s or `BasicObject`'s. A receiver the engine cannot see into — `Dynamic`, `top`, a literal or
    # shape carrier — keeps the reflective reading it had before this check.
    module GenuineSend
      GENUINE_OWNERS = Set["::Kernel", "::BasicObject"].freeze
      private_constant :GENUINE_OWNERS

      module_function

      # True when every member of `receiver_type` reaches the genuine `send`.
      def type?(receiver_type, scope)
        case receiver_type
        when Type::Union then receiver_type.members.all? { |member| type?(member, scope) }
        when Type::Nominal, Type::StructInstance, Type::DataInstance
          class_side?(receiver_type.class_name, :instance, scope)
        when Type::Singleton then class_side?(receiver_type.class_name, :singleton, scope)
        else true
        end
      end

      # True when the `send` a call with receiver `receiver_node` reaches is genuine, judged in `scope` (the scope
      # the call is typed in). An implicit or `self` receiver reads the scope's `self`; any other receiver is typed
      # in `scope` only when `typed:` (a caller holding another node's scope passes false, and the answer is then
      # false: nothing proves the `send` genuine). No scope proves nothing either.
      def call?(receiver_node, scope, typed: true)
        return false if scope.nil?

        receiver_type =
          case receiver_node
          when nil, Prism::SelfNode then scope.self_type || Type::Combinator.nominal_of("Object")
          else
            return false unless typed

            scope.type_of(receiver_node)
          end
        !receiver_type.nil? && type?(receiver_type, scope)
      end

      def class_side?(class_name, kind, scope)
        return true if class_name.nil? || scope.nil?
        return false unless project_definer(class_name, kind, scope).nil?

        rbs_genuine?(class_name, kind, scope)
      end

      # True when the RBS declaration of `send` Ruby reaches on `class_name`'s `kind` side, on the class or through
      # the project's ancestry to an external one, is `Kernel`'s or `BasicObject`'s, or when none is found. The
      # typer asks this alone before letting a project `def send` body answer: a project RBS `def send:` is the
      # contract and outranks the body, as it does for any other method.
      def rbs_genuine?(class_name, kind, scope)
        definition = ExternalAncestorResolution.method_definition(class_name, :send, kind, scope: scope)
        definition ||= ExternalAncestorResolution.resolve(class_name, :send, kind, scope: scope)&.first
        definition.nil? || GENUINE_OWNERS.include?(definition.defined_in.to_s)
      end

      # The project `def send` Ruby reaches on `class_name`'s `kind` side, or nil.
      def project_definer(class_name, kind, scope)
        if kind == :singleton
          scope.singleton_def_through_ancestors(class_name, :send).first
        else
          scope.user_def_through_ancestors(class_name, :send).first
        end
      end
      private_class_method :class_side?, :project_definer
    end
  end
end
