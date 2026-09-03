# frozen_string_literal: true

module Rigor
  module Plugin
    class FFI < Base
      # Fact yielded by a registered BindingRecognizer or emitted from literal attach_function.
      AttachFunctionFact = Data.define(
        :ruby_name,
        :c_name,
        :arg_types,
        :return_type,
        :blocking,
        :node,
        :receiver_name
      ) do
        def initialize(
          ruby_name:,
          c_name: ruby_name,
          arg_types: [],
          return_type: :void,
          blocking: false,
          node: nil,
          receiver_name: nil
        )
          super(
            ruby_name: ruby_name.to_sym,
            c_name: (c_name || ruby_name).to_sym,
            arg_types: Array(arg_types),
            return_type: return_type,
            blocking: blocking,
            node: node,
            receiver_name: receiver_name&.to_s
          )
        end
      end

      # Extension point for sub-plugins to register custom DSL recognizers (WD2).
      class BindingRecognizer
        attr_reader :name, :block

        def initialize(name, &block)
          @name = name.to_sym
          @block = block
        end

        def recognize(node, scope)
          Array(@block.call(node, scope))
        rescue StandardError
          []
        end
      end

      class << self
        def binding_recognizers
          @binding_recognizers ||= []
        end

        def register_binding_recognizer(name, &block)
          binding_recognizers << BindingRecognizer.new(name, &block)
        end
      end
    end

    class Base
      def self.ffi_binding_recognizers
        @ffi_binding_recognizers ||= []
      end

      def self.ffi_binding_recognizer(name, &block)
        ffi_binding_recognizers << Rigor::Plugin::FFI::BindingRecognizer.new(name, &block)
        Rigor::Plugin::FFI.register_binding_recognizer(name, &block)
      end
    end
  end
end
