# frozen_string_literal: true

require "prism"
require "set"

module Rigor
  module Plugin
    class FFI < Base
      class Discoverer
        def self.discover(root:)
          new(root: root).discover
        end

        def initialize(root:)
          @root = root
        end

        def discover
          functions = {}
          functions_by_receiver = {}
          libraries = Set.new
          structs = {}
          typedefs = {}
          enums = {}
          callbacks = {}

          ruby_files.each do |file_path|
            parse_result = Prism.parse_file(file_path)
            next unless parse_result.value

            walk_tree(parse_result.value, nil) do |node, mod_name|
              case node
              when Prism::CallNode
                handle_call(
                  node,
                  mod_name,
                  functions,
                  functions_by_receiver,
                  libraries,
                  structs,
                  typedefs,
                  enums,
                  callbacks
                )
              when Prism::ClassNode
                handle_class(node, mod_name, structs)
              end
            end
          end

          FFICatalog.new(
            functions: functions,
            functions_by_receiver: functions_by_receiver,
            libraries: libraries,
            structs: structs,
            typedefs: typedefs,
            enums: enums,
            callbacks: callbacks
          )
        end

        private

        def ruby_files
          return [] unless @root && File.directory?(@root)

          Dir.glob(File.join(@root, "**", "*.rb")).reject { |p| p.include?("/vendor/") || p.include?("/.git/") }
        end

        def walk_tree(node, current_module, &block)
          return unless node

          case node
          when Prism::ClassNode, Prism::ModuleNode
            name = node.constant_path.slice
            full_name = current_module ? "#{current_module}::#{name}" : name
            yield node, full_name
            node.body&.child_nodes&.each { |child| walk_tree(child, full_name, &block) }
          else
            yield node, current_module
            node.child_nodes.each { |child| walk_tree(child, current_module, &block) }
          end
        end

        def handle_call(node, mod_name, functions, functions_by_receiver, libraries, structs, typedefs, enums, callbacks)
          case node.name
          when :extend
            arg = node.arguments&.arguments&.first
            if arg && ["FFI::Library", "::FFI::Library", "FFX::Library", "::FFX::Library"].include?(arg.slice)
              libraries << mod_name if mod_name
            end
          when :attach_function
            fact = Analyzer.extract_attach_function(node, module_name: mod_name)
            if fact
              (functions[fact.ruby_name] ||= []) << fact
              if mod_name
                libraries << mod_name
                functions_by_receiver[[mod_name, fact.ruby_name]] = fact
              end
            end
          when :callback
            # Issue 4 fix: extract callback definitions
            args = node.arguments&.arguments || []
            if args.size >= 3
              cb_name = Analyzer.extract_symbol(args[0])
              cb_params = []
              if args[1].is_a?(Prism::ArrayNode)
                cb_params = (args[1].elements || []).map { |elem| Analyzer.extract_type_symbol(elem) }.compact
              end
              cb_ret = Analyzer.extract_type_symbol(args[2]) || :void
              if cb_name
                callbacks[cb_name] = { params: cb_params, return_type: cb_ret }
                typedefs[cb_name] = :pointer
                libraries << mod_name if mod_name
              end
            end
          when :typedef
            args = node.arguments&.arguments || []
            if args.size >= 2
              old_t = Analyzer.extract_type_symbol(args[0])
              new_t = Analyzer.extract_symbol(args[1])
              typedefs[new_t] = old_t if old_t && new_t
              libraries << mod_name if mod_name
            end
          when :enum, :bitmask
            args = node.arguments&.arguments || []
            if args.size >= 2
              enum_name = Analyzer.extract_symbol(args[0])
              enums[enum_name] = true if enum_name
              libraries << mod_name if mod_name
            end
          when :layout
            # Struct layout definition
            if mod_name
              fields = structs[mod_name] ||= {}
              args = node.arguments&.arguments || []
              i = 0
              while i < args.size
                f_name = Analyzer.extract_symbol(args[i])
                f_type = Analyzer.extract_type_symbol(args[i + 1])
                fields[f_name] = f_type if f_name && f_type
                i += 2
              end
            end
          else
            # Issue 5 fix: pass mod_name to sub-plugin recognizers
            FFI.binding_recognizers.each do |recognizer|
              facts = recognizer.recognize(node, mod_name)
              Array(facts).each do |fact|
                next unless fact.is_a?(AttachFunctionFact)

                (functions[fact.ruby_name] ||= []) << fact
                rec = fact.receiver_name || mod_name
                if rec
                  libraries << rec
                  functions_by_receiver[[rec, fact.ruby_name]] = fact
                end
              end
            end
          end
        end

        def handle_class(node, mod_name, structs)
          superclass_name = node.superclass&.slice
          return unless superclass_name

          if ["FFI::Struct", "::FFI::Struct", "FFI::Union", "::FFI::Union"].include?(superclass_name)
            structs[mod_name] ||= {} if mod_name
          end
        end
      end
    end
  end
end
