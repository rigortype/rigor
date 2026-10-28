# frozen_string_literal: true

require "prism"
require_relative "mutation_widening"
require_relative "receiver_alias"
require_relative "../type"

module Rigor
  module Inference
    # Issue #2499 rule 3 (part of #2494) — the stdlib calls that fill a String the caller passes in. After
    # `io.read(n, buf)`, `io.readpartial(n, buf)`, `io.sysread(n, buf)` and `io.read_nonblock(n, buf)` the buffer
    # holds what was read, and after `StringIO.new(s)` every later write through the StringIO lands in `s`. The
    # argument (a local, instance, class or global variable read) is widened as an in-place `replace` of it would
    # widen it, so a `buf = +""` seed stops reading `""` after the call.
    #
    # A built-in catalogue keyed by method name and argument position, not a receiver-typed dispatch: a method of
    # another class with the same name and a second positional argument loses only precision on that argument.
    module OutBufferMutation
      # Method name => the zero-based position of the buffer argument.
      READERS = { read: 1, readpartial: 1, sysread: 1, read_nonblock: 1 }.freeze
      private_constant :READERS

      module_function

      # `scope` with the buffer argument of `call_node` widened, or `scope` itself when the call is no such call or the
      # argument holds no String: `Rails.cache.read(key, opts)` passes an options Hash that keeps its shape.
      def floor(call_node, scope)
        buffer = buffer_argument(call_node)
        return scope if buffer.nil?

        getter, = MutationWidening::ALIAS_ACCESSORS[buffer.class]
        return scope unless string_carrier?(scope.public_send(getter, ReceiverAlias.read_name(buffer)))

        MutationWidening.widen_alias_read(:replace, buffer, scope)
      end

      # A `Constant<String>` or the `String` nominal, or a union of nothing else.
      def string_carrier?(type)
        case type
        when Type::Constant then type.value.is_a?(String)
        when Type::Nominal then type.class_name == "String"
        when Type::Union then type.members.all? { |member| string_carrier?(member) }
        else false
        end
      end

      def buffer_argument(call_node)
        arguments = call_node.arguments&.arguments
        return nil if arguments.nil?

        position = READERS[call_node.name]
        position = 0 if position.nil? && string_io_new?(call_node)
        return nil if position.nil?

        argument = arguments[position]
        MutationWidening::ALIAS_ACCESSORS.key?(argument.class) ? argument : nil
      end

      def string_io_new?(call_node)
        return false unless call_node.name == :new

        receiver = call_node.receiver
        case receiver
        when Prism::ConstantReadNode then receiver.name == :StringIO
        when Prism::ConstantPathNode then receiver.parent.nil? && receiver.name == :StringIO
        else false
        end
      end
      private_class_method :buffer_argument, :string_io_new?, :string_carrier?
    end
  end
end
