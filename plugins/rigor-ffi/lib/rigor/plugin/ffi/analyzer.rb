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
            extract_symbol(node.receiver) if node.name == :to_sym && node.receiver
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

        # Universal binding extractor for attach_function, sodium_function, etc.
        def extract_function_binding(call_node, method_name:, module_name: nil, default_return: :void)
          return nil unless call_node.is_a?(Prism::CallNode) && call_node.name == method_name

          all_args = call_node.arguments&.arguments || []
          return nil if all_args.empty?

          # Strip trailing keyword options hash if present
          pos_args = all_args.grep_v(Prism::KeywordHashNode)
          return nil if pos_args.empty?

          ruby_name = extract_symbol(pos_args[0])
          return nil if ruby_name.nil?

          if pos_args.size >= 4
            # Form B: ruby_name, c_name, arg_types, return_type
            c_name = extract_symbol(pos_args[1]) || ruby_name
            args_node = pos_args[2]
            ret_node = pos_args[3]
          elsif pos_args.size == 3
            # Form A: ruby_name, arg_types, return_type
            c_name = ruby_name
            args_node = pos_args[1]
            ret_node = pos_args[2]
          elsif pos_args.size == 2
            c_name = ruby_name
            args_node = nil
            ret_node = pos_args[1]
          else
            return nil
          end

          arg_types = []
          if args_node.is_a?(Prism::ArrayNode)
            arg_types = (args_node.elements || []).map { |elem| extract_type_symbol(elem) }.compact
          elsif args_node.is_a?(Prism::ConstantReadNode) || args_node.is_a?(Prism::ConstantPathNode)
            arg_types = [args_node.slice.to_sym]
          end

          return_type = ret_node ? (extract_type_symbol(ret_node) || default_return) : default_return

          AttachFunctionFact.new(
            ruby_name: ruby_name,
            c_name: c_name,
            arg_types: arg_types,
            return_type: return_type,
            node: call_node,
            receiver_name: module_name
          )
        end

        def extract_attach_function(call_node, module_name: nil)
          extract_function_binding(call_node, method_name: :attach_function, module_name: module_name, default_return: :void)
        end

        def ffx_diagnostics_for_call(call_node, path:, target:)
          return [] unless target == :ffx && call_node.is_a?(Prism::CallNode)

          diagnostics = []

          case call_node.name
          when :callback
            diagnostics << Rigor::Analysis::Diagnostic.new(
              path: path,
              line: call_node.location.start_line,
              column: call_node.location.start_column + 1,
              rule: "ffx.unsupported-callback",
              message: "callback declarations are not supported by ffx (C extensions use native function pointers)",
              severity: :error
            )
          when :typedef
            diagnostics << Rigor::Analysis::Diagnostic.new(
              path: path,
              line: call_node.location.start_line,
              column: call_node.location.start_column + 1,
              rule: "ffx.unsupported-typedef",
              message: "typedef declarations are not supported by ffx",
              severity: :error
            )
          when :enum, :bitmask
            diagnostics << Rigor::Analysis::Diagnostic.new(
              path: path,
              line: call_node.location.start_line,
              column: call_node.location.start_column + 1,
              rule: "ffx.unsupported-enum",
              message: "#{call_node.name} declarations are not supported by ffx",
              severity: :error
            )
          when :attach_function
            args = call_node.arguments&.arguments || []
            pos_args = args.grep_v(Prism::KeywordHashNode)

            args_node = pos_args.size >= 4 ? pos_args[2] : pos_args[1]
            ret_node = pos_args.size >= 4 ? pos_args[3] : pos_args[2]

            if args_node.is_a?(Prism::ArrayNode)
              args_node.elements.each do |elem|
                type_sym = extract_type_symbol(elem)
                if type_sym == :varargs
                  diagnostics << Rigor::Analysis::Diagnostic.new(
                    path: path,
                    line: elem.location.start_line,
                    column: elem.location.start_column + 1,
                    rule: "ffx.unsupported-varargs",
                    message: "varargs are not supported by ffx",
                    severity: :error
                  )
                elsif type_sym && !Types::FFX_PRIMITIVE_TYPES.include?(type_sym)
                  diagnostics << Rigor::Analysis::Diagnostic.new(
                    path: path,
                    line: elem.location.start_line,
                    column: elem.location.start_column + 1,
                    rule: "ffx.unsupported-type",
                    message: "type :#{type_sym} is not supported by ffx (expected one of 25 primitive types)",
                    severity: :error
                  )
                end
              end
            end

            if ret_node
              ret_sym = extract_type_symbol(ret_node)
              if ret_sym && !Types::FFX_PRIMITIVE_TYPES.include?(ret_sym)
                diagnostics << Rigor::Analysis::Diagnostic.new(
                  path: path,
                  line: ret_node.location.start_line,
                  column: ret_node.location.start_column + 1,
                  rule: "ffx.unsupported-type",
                  message: "return type :#{ret_sym} is not supported by ffx (expected one of 25 primitive types)",
                  severity: :error
                )
              end
            end
          end

          diagnostics
        end

        def ffx_diagnostics_for_class(class_node, path:, target:)
          return [] unless target == :ffx && class_node.is_a?(Prism::ClassNode)

          superclass_name = class_node.superclass&.slice
          return [] unless superclass_name

          if ["FFI::Struct", "::FFI::Struct", "FFI::Union", "::FFI::Union", "FFI::ManagedStruct", "::FFI::ManagedStruct"].include?(superclass_name)
            [
              Rigor::Analysis::Diagnostic.new(
                path: path,
                line: class_node.location.start_line,
                column: class_node.location.start_column + 1,
                rule: "ffx.unsupported-struct",
                message: "FFI::Struct and FFI::Union are not supported by ffx",
                severity: :error
              )
            ]
          else
            []
          end
        end
      end
    end
  end
end
