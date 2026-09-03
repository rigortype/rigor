# frozen_string_literal: true

require "rigor"
require "rigor-ffi"

module Rigor
  module Plugin
    class RbNaCl < Base
      manifest(
        id: "rbnacl",
        version: "0.1.0",
        description: "Rigor type support for RbNaCl libsodium bindings"
      )

      # Issue 2 & 5: use robust positional binding extractor and preserve module context
      ffi_binding_recognizer :sodium_function do |node, module_name|
        next [] unless node.is_a?(Prism::CallNode) && node.name == :sodium_function

        receiver = module_name && !module_name.empty? ? module_name : "RbNaCl"
        fact = FFI::Analyzer.extract_function_binding(
          node,
          method_name: :sodium_function,
          module_name: receiver,
          default_return: :int
        )
        fact ? [fact] : []
      end
    end
  end
end
