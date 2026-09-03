# frozen_string_literal: true

require "rigor"
require "rigor-ffi"

module Rigor
  module Plugin
    class RbNaCl < Base
      manifest(
        id: "rbnacl",
        version: "0.1.0",
        description: "Rigor type support for RbNaCl libsodium bindings",
        homepage: "https://github.com/rigortype/rigor",
        authors: ["Rigor Authors"]
      )

      # Issue 5 fix: do not hardcode "RbNaCl" as receiver name; use module_name context
      ffi_binding_recognizer :sodium_function do |node, module_name|
        next [] unless node.is_a?(Prism::CallNode) && node.name == :sodium_function

        args = node.arguments&.arguments || []
        next [] if args.empty?

        ruby_name = FFI::Analyzer.extract_symbol(args[0])
        next [] if ruby_name.nil?

        c_name = ruby_name
        idx = 1
        if args[idx] && (args[idx].is_a?(Prism::SymbolNode) || args[idx].is_a?(Prism::StringNode)) && args[idx + 1].is_a?(Prism::ArrayNode)
          c_name = FFI::Analyzer.extract_symbol(args[idx]) || ruby_name
          idx += 1
        end

        arg_types = []
        if args[idx].is_a?(Prism::ArrayNode)
          arg_types = (args[idx].elements || []).map { |elem| FFI::Analyzer.extract_type_symbol(elem) }.compact
          idx += 1
        end

        return_type = args[idx] ? (FFI::Analyzer.extract_type_symbol(args[idx]) || :int) : :int

        receiver = module_name && !module_name.empty? ? module_name : "RbNaCl"

        [
          FFI::AttachFunctionFact.new(
            ruby_name: ruby_name,
            c_name: c_name,
            arg_types: arg_types,
            return_type: return_type,
            node: node,
            receiver_name: receiver
          )
        ]
      end
    end
  end
end
