# frozen_string_literal: true

require "prism"

module Rigor
  module Plugin
    class FFI < Base
      # Issue #1803 — the walk lists and reads through the plugin's {Rigor::Plugin::IoBoundary} (`io:`), so every
      # `.rb` the catalog was built from is a dependency row of the `:ffi_catalog` producer's cache entry and of
      # every run-result cache built on the run. The producer declares no `watch:`, so before this its entry
      # carried no row at all and was served after any edit, an analysed file's included, until `--no-cache`.
      class Discoverer
        RUBY_GLOB = "**/*.rb"
        SKIPPED_DIRECTORIES = %w[vendor .git].freeze

        def self.discover(root:, io:)
          new(root: root, io: io).discover
        end

        def initialize(root:, io:)
          @root = root
          @io = io
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
            parse_result = parse(file_path)
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

        # One `:names` `**/*.rb` row over the root, `vendor/` included: a per-entry walk that skipped it recorded
        # names only, so a top-level entry that changed kind under the same name went unseen. The boundary
        # answers absolute paths; they are spelled back under `@root` as `Dir.glob` spells them.
        def ruby_files
          return [] unless @root && @io.directory?(@root.to_s)

          root = @root.to_s
          prefix = "#{File.absolute_path(root)}/"
          @io.glob(root, RUBY_GLOB).filter_map do |path|
            relative = path.delete_prefix(prefix)
            File.join(root, relative) unless skipped?(relative)
          end
        end

        # #1956 — the skip reads the path relative to the root, a `vendor` or `.git` directory segment at any
        # depth under it. Matching `/vendor/` in the whole path also dropped every file of a project that itself
        # lives under some `…/vendor/…` directory, and the catalog came out empty.
        def skipped?(relative)
          relative.split("/")[0...-1].intersect?(SKIPPED_DIRECTORIES)
        end

        # The glob's rows record which files match; this read's row carries an edit.
        def parse(file_path)
          Prism.parse(@io.read_file(file_path))
        end

        def walk_tree(node, current_module, &)
          return unless node

          case node
          when Prism::ClassNode, Prism::ModuleNode
            name = node.constant_path.slice
            full_name = current_module ? "#{current_module}::#{name}" : name
            yield node, full_name
            node.body&.child_nodes&.each { |child| walk_tree(child, full_name, &) }
          else
            yield node, current_module
            node.child_nodes.each { |child| walk_tree(child, current_module, &) }
          end
        end

        def handle_call(node, mod_name, functions, functions_by_receiver, libraries, structs, typedefs, enums, callbacks)
          case node.name
          when :extend
            arg = node.arguments&.arguments&.first
            if arg && ["FFI::Library", "::FFI::Library", "FFX::Library", "::FFX::Library"].include?(arg.slice) && mod_name
              libraries << mod_name
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

          return unless ["FFI::Struct", "::FFI::Struct", "FFI::Union", "::FFI::Union"].include?(superclass_name)

          structs[mod_name] ||= {} if mod_name
        end
      end
    end
  end
end
