# frozen_string_literal: true

require "rigor/plugin"
require "rigor-ffi"

module Rigor
  module Plugin
    class RbNaCl < Base
      manifest(
        id: "rbnacl",
        version: "0.1.0",
        description: "Models RbNaCl / libsodium DSL bindings (sodium_function) and cryptographic carrier types.",
        signature_paths: ["sig"]
      )

      # Recognizer for sodium_function DSL wrapping attach_function (WD2)
      ffi_binding_recognizer :sodium_function do |node, _scope|
        next [] unless node.is_a?(Prism::CallNode) && node.name == :sodium_function

        args = node.arguments&.arguments || []
        next [] if args.size < 4

        ruby_name = FFI::Analyzer.extract_symbol(args[0])
        c_name = FFI::Analyzer.extract_symbol(args[1]) || ruby_name
        next [] if ruby_name.nil?

        arg_types = []
        if args[2].is_a?(Prism::ArrayNode)
          arg_types = (args[2].elements || []).map { |elem| FFI::Analyzer.extract_type_symbol(elem) }.compact
        end

        return_type = FFI::Analyzer.extract_type_symbol(args[3]) || :void

        [
          FFI::AttachFunctionFact.new(
            ruby_name: ruby_name,
            c_name: c_name,
            arg_types: arg_types,
            return_type: return_type,
            node: node,
            receiver_name: "RbNaCl"
          )
        ]
      end

      def init(services)
      end

      def prepare(services)
      end

      def diagnostics_for_file(path:, scope:, root:)
        []
      end
    end
  end
end

Rigor::Plugin.register(Rigor::Plugin::RbNaCl)
