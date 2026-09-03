# frozen_string_literal: true

require "prism"
require "set"
require_relative "catalog"
require_relative "analyzer"

module Rigor
  module Plugin
    class FFI < Base
      class FFIDiscoverer
        def initialize(root:, io_boundary: nil)
          @root = root.to_s
          @io_boundary = io_boundary
        end

        def discover
          functions = {}
          libraries = Set.new
          structs = {}
          typedefs = {}
          enums = {}

          ruby_files.each do |file|
            code = read_safely(file)
            next if code.nil?

            result = Prism.parse(code)
            next unless result.success?

            walk(result.value, [], functions, libraries, structs, typedefs, enums)
          end

          FFICatalog.new(
            functions: functions,
            libraries: libraries,
            structs: structs,
            typedefs: typedefs,
            enums: enums
          )
        end

        private

        def ruby_files
          return [] unless @root && File.directory?(@root)

          Dir.glob(File.join(@root, "**", "*.rb"))
        end

        def read_safely(path)
          if @io_boundary.respond_to?(:read_file)
            @io_boundary.read_file(path)
          else
            File.read(path)
          end
        rescue SystemCallError, Plugin::AccessDeniedError
          nil
        end

        def walk(node, lexical_path, functions, libraries, structs, typedefs, enums)
          return if node.nil?

          case node
          when Prism::ModuleNode
            mod_name = constant_path_name(node.constant_path)
            full_path = (lexical_path + [mod_name]).compact
            walk_children(node, full_path, functions, libraries, structs, typedefs, enums)
          when Prism::ClassNode
            class_name = constant_path_name(node.constant_path)
            full_path = (lexical_path + [class_name]).compact
            superclass = node.superclass&.slice
            if superclass && ["FFI::Struct", "::FFI::Struct", "FFI::Union", "::FFI::Union", "FFI::ManagedStruct", "::FFI::ManagedStruct"].include?(superclass)
              structs[full_path.join("::")] ||= {}
            end
            walk_children(node, full_path, functions, libraries, structs, typedefs, enums)
          when Prism::CallNode
            mod_name = lexical_path.join("::")
            handle_call(node, mod_name, functions, libraries, structs, typedefs, enums)
            walk_children(node, lexical_path, functions, libraries, structs, typedefs, enums)
          else
            walk_children(node, lexical_path, functions, libraries, structs, typedefs, enums)
          end
        end

        def walk_children(node, lexical_path, functions, libraries, structs, typedefs, enums)
          if node.respond_to?(:rigor_each_child)
            node.rigor_each_child { |child| walk(child, lexical_path, functions, libraries, structs, typedefs, enums) }
          elsif node.respond_to?(:child_nodes)
            node.child_nodes.each { |child| walk(child, lexical_path, functions, libraries, structs, typedefs, enums) }
          end
        end

        def handle_call(node, mod_name, functions, libraries, structs, typedefs, enums)
          case node.name
          when :extend
            first_arg = node.arguments&.arguments&.first&.slice
            if first_arg && ["FFI::Library", "::FFI::Library", "FFX::Library", "::FFX::Library"].include?(first_arg)
              libraries << mod_name unless mod_name.empty?
            end
          when :attach_function
            fact = Analyzer.extract_attach_function(node, module_name: mod_name)
            if fact
              (functions[fact.ruby_name] ||= []) << fact
            end
          when :typedef
            args = node.arguments&.arguments || []
            if args.size >= 2
              old_t = Analyzer.extract_type_symbol(args[0])
              new_t = Analyzer.extract_symbol(args[1])
              typedefs[new_t] = old_t if old_t && new_t
            end
          when :enum, :bitmask
            args = node.arguments&.arguments || []
            if args.size >= 2
              enum_name = Analyzer.extract_symbol(args[0])
              enums[enum_name] = true if enum_name
            end
          when :layout
            if structs.key?(mod_name)
              fields = structs[mod_name]
              args = node.arguments&.arguments || []
              args.each_slice(2) do |f_node, t_node|
                f_name = Analyzer.extract_symbol(f_node)
                t_name = Analyzer.extract_type_symbol(t_node)
                fields[f_name] = t_name if f_name && t_name
              end
            end
          end

          # Sub-plugin recognizers extension point (WD2)
          FFI.binding_recognizers.each do |recognizer|
            facts = recognizer.recognize(node, nil)
            facts.each do |f|
              (functions[f.ruby_name] ||= []) << f
            end
          end
        end

        def constant_path_name(node)
          return nil if node.nil?

          node.slice
        end
      end
    end
  end
end
