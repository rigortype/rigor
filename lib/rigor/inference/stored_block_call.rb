# frozen_string_literal: true

require "prism"

module Rigor
  module Inference
    # The calls that keep their literal block to run later instead of running it before they return: the Kernel
    # functions that wrap it in a Proc (`lambda`, `proc`), the definers that install it as a method body
    # (`define_method`, `define_singleton_method`, on any receiver), and the constructors that keep it as a proc,
    # a thread or fiber body, an enumerator's generator or a hash's default proc.
    #
    # A `break` in such a block never becomes the call's value — it returns from the lambda or the defined method
    # when that is called, or raises `LocalJumpError` — so the #853 break-arm union
    # (`ExpressionTyper#call_break_arm_types`) MUST NOT read it. Unioning the arm typed
    # `lambda do |t| break if flag; t end` as `Proc | nil`, and the lambda's next `.call` drew
    # `call.possible-nil-receiver`.
    #
    # A project redefinition of one of these names is not excluded: dropping the arm there loses a `break`
    # value, never invents one.
    module StoredBlockCall
      KERNEL_WRAPPERS = %i[lambda proc].freeze
      DEFINERS = %i[define_method define_singleton_method].freeze
      CONSTRUCTORS = {
        Proc: %i[new], Thread: %i[new start fork], Fiber: %i[new], Enumerator: %i[new], Hash: %i[new]
      }.transform_values(&:freeze).freeze
      NO_NAMES = [].freeze
      private_constant :KERNEL_WRAPPERS, :DEFINERS, :CONSTRUCTORS, :NO_NAMES

      module_function

      def stores_block?(call_node)
        name = call_node.name
        return kernel_spelled?(call_node.receiver) if KERNEL_WRAPPERS.include?(name)
        return true if DEFINERS.include?(name)

        constant = root_constant_name(call_node.receiver)
        !constant.nil? && CONSTRUCTORS.fetch(constant, NO_NAMES).include?(name)
      end

      # Implicit self, `self.`, or `Kernel.` / `::Kernel.` — the spellings that reach Kernel's function.
      def kernel_spelled?(receiver)
        receiver.nil? || receiver.is_a?(Prism::SelfNode) || root_constant_name(receiver) == :Kernel
      end

      # `Foo` or `::Foo`'s name, else nil.
      def root_constant_name(receiver)
        case receiver
        when Prism::ConstantReadNode then receiver.name
        when Prism::ConstantPathNode then receiver.name if receiver.parent.nil?
        end
      end
    end
  end
end
