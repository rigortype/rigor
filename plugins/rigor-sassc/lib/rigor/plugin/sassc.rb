# frozen_string_literal: true

require "rigor/plugin"
require "rigor-ffi"

module Rigor
  module Plugin
    class SassC < Base
      manifest(
        id: "sassc",
        version: "0.1.0",
        description: "Models SassC native bindings, nominal pointer typedefs, and struct unions.",
        signature_paths: ["sig"]
      )

      # Recognizer for sass prefix-stripped attach_function calls
      ffi_binding_recognizer :sassc_function do |node, module_name|
        next [] unless node.is_a?(Prism::CallNode) && node.name == :attach_function

        args = node.arguments&.arguments || []
        next [] if args.empty?

        ruby_name = FFI::Analyzer.extract_symbol(args[0])
        next [] if ruby_name.nil?

        mod = module_name && !module_name.empty? ? module_name : "SassC::Native"

        # If ruby_name starts with sass_, also register stripped version
        c_name = ruby_name
        stripped_name = ruby_name.to_s.sub(/^sass_/, "").to_sym

        fact = FFI::Analyzer.extract_attach_function(node, module_name: mod)
        next [] if fact.nil?

        if stripped_name == ruby_name
          [fact]
        else
          [
            fact,
            FFI::AttachFunctionFact.new(
              ruby_name: stripped_name,
              c_name: c_name,
              arg_types: fact.arg_types,
              return_type: fact.return_type,
              node: node,
              receiver_name: mod
            )
          ]
        end
      end
    end
  end
end

Rigor::Plugin.register(Rigor::Plugin::SassC)
