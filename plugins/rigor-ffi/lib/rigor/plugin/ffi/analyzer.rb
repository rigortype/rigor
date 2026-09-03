# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class FFI < Base
      module Analyzer
        module_function

        def extract_symbol(node)
          case node
          when Prism::SymbolNode
            node.unescaped.to_sym
          when Prism::StringNode
            node.unescaped.to_sym
          when Prism::CallNode
            if node.name == :to_sym && node.receiver
              extract_symbol(node.receiver)
            end
          end
        end

        def extract_type_symbol(node)
          case node
          when Prism::SymbolNode
            node.unescaped.to_sym
          when Prism::StringNode
            node.unescaped.to_sym
          when Prism::ConstantReadNode, Prism::ConstantPathNode
            node.slice.to_sym
          when Prism::CallNode
            # e.g. MyStruct.ptr or MyStruct.by_ref
            node.slice.to_sym
          end
        end

        def extract_attach_function(call_node, module_name: nil)
          return nil unless call_node.is_a?(Prism::CallNode) && call_node.name == :attach_function

          args = call_node.arguments&.arguments || []
          return nil if args.empty?

          ruby_name = extract_symbol(args[0])
          return nil if ruby_name.nil?

          idx = 1
          c_name = ruby_name
          if args[idx] && (args[idx].is_a?(Prism::SymbolNode) || (args[idx].is_a?(Prism::StringNode) && args[idx + 1].is_a?(Prism::ArrayNode)))
            c_name = extract_symbol(args[idx]) || ruby_name
            idx += 1
          end

          arg_types = []
          if args[idx].is_a?(Prism::ArrayNode)
            arg_types = (args[idx].elements || []).map { |elem| extract_type_symbol(elem) }.compact
            idx += 1
          end

          return_type = args[idx] ? (extract_type_symbol(args[idx]) || :void) : :void

          AttachFunctionFact.new(
            ruby_name: ruby_name,
            c_name: c_name,
            arg_types: arg_types,
            return_type: return_type,
            node: call_node,
            receiver_name: module_name
          )
        end

        def ffx_diagnostics_for_call(node, path:, target:)
          return [] unless target == :ffx && node.is_a?(Prism::CallNode)

          diags = []
          case node.name
          when :callback
            diags << Rigor::Analysis::Diagnostic.new(
              path: path,
              line: node.location.start_line,
              column: node.location.start_column + 1,
              message: "ffx does not support callback declarations",
              severity: :error,
              rule: "ffx.unsupported-callback"
            )
          when :typedef
            diags << Rigor::Analysis::Diagnostic.new(
              path: path,
              line: node.location.start_line,
              column: node.location.start_column + 1,
              message: "ffx does not support typedef declarations",
              severity: :error,
              rule: "ffx.unsupported-typedef"
            )
          when :enum, :bitmask
            diags << Rigor::Analysis::Diagnostic.new(
              path: path,
              line: node.location.start_line,
              column: node.location.start_column + 1,
              message: "ffx does not support #{node.name} declarations",
              severity: :error,
              rule: "ffx.unsupported-enum"
            )
          when :attach_function
            fact = extract_attach_function(node)
            if fact
              if fact.arg_types.include?(:varargs)
                diags << Rigor::Analysis::Diagnostic.new(
                  path: path,
                  line: node.location.start_line,
                  column: node.location.start_column + 1,
                  message: "ffx does not support variadic (:varargs) functions",
                  severity: :error,
                  rule: "ffx.unsupported-varargs"
                )
              end

              all_types = fact.arg_types.reject { |t| t == :varargs } + [fact.return_type]
              unsupported = all_types.reject { |t| Types::FFX_PRIMITIVE_TYPES.include?(t) }
              unless unsupported.empty?
                diags << Rigor::Analysis::Diagnostic.new(
                  path: path,
                  line: node.location.start_line,
                  column: node.location.start_column + 1,
                  message: "ffx does not support type #{unsupported.first.inspect}; only the 25 primitive types are supported",
                  severity: :error,
                  rule: "ffx.unsupported-type"
                )
              end
            end
          end
          diags
        end

        def ffx_diagnostics_for_class(node, path:, target:)
          return [] unless target == :ffx && node.is_a?(Prism::ClassNode)

          superclass_name = node.superclass&.slice
          return [] unless superclass_name && ["FFI::Struct", "::FFI::Struct", "FFI::Union", "::FFI::Union", "FFI::ManagedStruct", "::FFI::ManagedStruct"].include?(superclass_name)

          [
            Rigor::Analysis::Diagnostic.new(
              path: path,
              line: node.location.start_line,
              column: node.location.start_column + 1,
              message: "ffx does not support #{superclass_name} declarations",
              severity: :error,
              rule: "ffx.unsupported-struct"
            )
          ]
        end
      end
    end
  end
end
