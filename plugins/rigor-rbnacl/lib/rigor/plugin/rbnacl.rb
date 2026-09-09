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
        signature_paths: ["sig"],
        # ADR-26 — `sig/rbnacl.rbs` declares three methods of a class that has many more (`nonce_bytes`,
        # `key_bytes`, …). Contributing it without opening the receivers would close those classes and
        # manufacture `call.undefined-method` on correct code, which is the trade the project refuses.
        open_receivers: [
          "RbNaCl::SecretBox",
          "RbNaCl::Signatures::Ed25519::SigningKey",
          "RbNaCl::Signatures::Ed25519::VerifyKey"
        ]
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

Rigor::Plugin.register(Rigor::Plugin::RbNaCl)
