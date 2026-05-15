# frozen_string_literal: true

require "prism"

require_relative "../plugin/macro/heredoc_template"
require_relative "synthetic_method"
require_relative "synthetic_method_index"

module Rigor
  module Inference
    # ADR-16 slice 2b pre-pass — scans the project's source paths
    # for class-level DSL calls that match any registered plugin's
    # `Plugin::Macro::HeredocTemplate` entry, instantiates the
    # corresponding {SyntheticMethod} records, and returns a frozen
    # {SyntheticMethodIndex} the dispatcher consults below the RBS
    # tier (per WD13 — user-authored RBS overrides substrate
    # synthesis).
    #
    # Two-phase walk:
    #
    # 1. **Hierarchy collection.** Visit every `class X < Y` decl
    #    in the project source set and record the parent chain in
    #    a lexical inheritance map. Cross-file ordering does not
    #    matter — every class in `paths:` is observed before
    #    matching starts.
    # 2. **Match + emit.** Re-walk each class body looking for
    #    `Prism::CallNode` whose name matches a template's
    #    `method_name` and whose argument at
    #    `symbol_arg_position` is a literal Symbol. The enclosing
    #    class must equal or inherit (lexically OR through the
    #    RBS env) from the template's `receiver_constraint`.
    #
    # Per WD4 the pre-pass mechanism is "scan all files once at
    # startup, populate the index before per-file inference."
    # Slice 2b ships this strategy; future iterations may revisit
    # to lazy emit (per WD4 alternatives) if the warm-cache profile
    # justifies it.
    #
    # Per WD13 floor — `return_type` is recorded but not resolved.
    # `Macro::HeredocTemplate::Emit#returns` strings round-trip
    # through {SyntheticMethod#return_type} verbatim; the
    # dispatcher's slice-2b tier translates every match to
    # `Dynamic[T]`. Precise resolution via the ADR-13 resolver
    # chain is the ceiling, deferred.
    module SyntheticMethodScanner
      module_function

      # @param plugin_registry [Rigor::Plugin::Registry]
      # @param paths           [Array<String>] absolute paths to the project
      #   source files to scan.
      # @param environment     [Rigor::Environment, nil] used for
      #   inheritance resolution against RBS-known classes
      #   (ActiveRecord::Base, Dry::Struct, etc.) that aren't
      #   declared in project source.
      # @return [Rigor::Inference::SyntheticMethodIndex]
      def scan(plugin_registry:, paths:, environment: nil)
        templates = collect_templates(plugin_registry)
        return SyntheticMethodIndex::EMPTY if templates.empty?

        asts = parse_paths(paths)
        hierarchy = build_hierarchy(asts)

        entries = []
        asts.each do |path, ast|
          walk_class_bodies(ast) do |class_name, call_node|
            collect_entries(entries, templates, class_name, call_node, hierarchy, environment, path)
          end
        end

        SyntheticMethodIndex.new(entries: entries)
      end

      # Aggregates `(plugin_id, template)` pairs across every
      # plugin's `manifest.heredoc_templates` in registration
      # order. Empty when no plugin contributes Tier C entries.
      def collect_templates(plugin_registry)
        return [] if plugin_registry.nil? || plugin_registry.empty?

        plugin_registry.plugins.flat_map do |plugin|
          # rigor:disable undefined-method
          plugin.manifest.heredoc_templates.map do |template|
            [plugin.manifest.id, template]
          end
        end
      end

      def parse_paths(paths)
        paths.to_h do |path|
          source = File.read(path)
          [path, Prism.parse(source).value]
        rescue StandardError
          [path, nil]
        end
      end

      # Builds a lexical inheritance map `class_name => parent_class_name`
      # by walking every top-level / nested `class X < Y` decl
      # across the AST set.
      def build_hierarchy(asts)
        hierarchy = {}
        asts.each_value do |ast|
          next if ast.nil?

          walk_class_decls(ast, []) do |class_name, parent_name|
            hierarchy[class_name] = parent_name if parent_name && !hierarchy.key?(class_name)
          end
        end
        hierarchy.freeze
      end

      def walk_class_decls(node, scope_stack, &) # rubocop:disable Metrics/PerceivedComplexity
        return unless node.respond_to?(:compact_child_nodes)

        if node.is_a?(Prism::ClassNode)
          name = class_name_from(node, scope_stack)
          parent = parent_name_from(node, scope_stack)
          yield name, parent if name
          new_stack = scope_stack + [node]
          node.body&.compact_child_nodes&.each { |child| walk_class_decls(child, new_stack, &) }
        elsif node.is_a?(Prism::ModuleNode)
          new_stack = scope_stack + [node]
          node.body&.compact_child_nodes&.each { |child| walk_class_decls(child, new_stack, &) }
        else
          node.compact_child_nodes.each { |child| walk_class_decls(child, scope_stack, &) }
        end
      end

      # Yields `(class_name, call_node)` for every Prism::CallNode
      # at class-body top level (singleton-context calls). Nested
      # method bodies, blocks, and conditionals are skipped — the
      # Tier C call shapes the substrate targets all live at the
      # class body's top level.
      def walk_class_bodies(node, scope_stack = [], &) # rubocop:disable Metrics/AbcSize,Metrics/CyclomaticComplexity,Metrics/PerceivedComplexity
        return unless node.respond_to?(:compact_child_nodes)

        if node.is_a?(Prism::ClassNode)
          name = class_name_from(node, scope_stack)
          new_stack = scope_stack + [node]
          if name && node.body.respond_to?(:body)
            node.body.body.each do |stmt|
              yield name, stmt if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil?
            end
          end
          node.body&.compact_child_nodes&.each { |child| walk_class_bodies(child, new_stack, &) }
        elsif node.is_a?(Prism::ModuleNode)
          new_stack = scope_stack + [node]
          node.body&.compact_child_nodes&.each { |child| walk_class_bodies(child, new_stack, &) }
        else
          node.compact_child_nodes.each { |child| walk_class_bodies(child, scope_stack, &) }
        end
      end

      def class_name_from(class_node, scope_stack)
        local = const_name_string(class_node.constant_path)
        return nil unless local

        prefix = scope_stack.filter_map do |ancestor|
          case ancestor
          when Prism::ClassNode, Prism::ModuleNode
            const_name_string(ancestor.constant_path)
          end
        end.join("::")
        prefix.empty? ? local : "#{prefix}::#{local}"
      end

      def parent_name_from(class_node, _scope_stack)
        return nil if class_node.superclass.nil?

        const_name_string(class_node.superclass)
      end

      def const_name_string(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then constant_path_string(node)
        end
      end

      def constant_path_string(node)
        parent = node.parent
        name = node.name.to_s
        return name if parent.nil?

        parent_str = const_name_string(parent)
        parent_str ? "#{parent_str}::#{name}" : name
      end

      def collect_entries(entries, templates, class_name, call_node, hierarchy, environment, path)
        templates.each do |(plugin_id, template)|
          next unless call_node.name == template.method_name
          next unless class_inherits_from?(class_name, template.receiver_constraint, hierarchy, environment)

          symbol_arg = literal_symbol_arg(call_node, template.symbol_arg_position)
          next if symbol_arg.nil?

          emit_entries_for(entries, class_name, symbol_arg, template, plugin_id, path, call_node)
        end
      end

      def emit_entries_for(entries, class_name, symbol_arg, template, plugin_id, path, call_node)
        template.emit.each do |row|
          entries << build_synthetic_method(
            class_name: class_name, name_arg: symbol_arg, row: row,
            template: template, plugin_id: plugin_id, path: path, call_node: call_node,
            kind: SyntheticMethod::INSTANCE
          )
        end
        template.class_level_emit.each do |row|
          entries << build_synthetic_method(
            class_name: class_name, name_arg: symbol_arg, row: row,
            template: template, plugin_id: plugin_id, path: path, call_node: call_node,
            kind: SyntheticMethod::SINGLETON
          )
        end
      end

      def build_synthetic_method(class_name:, name_arg:, row:, template:, plugin_id:, path:, call_node:, kind:) # rubocop:disable Metrics/ParameterLists
        SyntheticMethod.new(
          class_name: class_name,
          method_name: interpolate(row.name, name_arg).to_sym,
          return_type: row.returns,
          kind: kind,
          provenance: {
            plugin_id: plugin_id,
            template_method: template.method_name.to_s,
            template_constraint: template.receiver_constraint,
            source_path: path,
            source_line: call_node.location.start_line
          }
        )
      end

      def interpolate(template_name, name_arg)
        template_name.gsub(Rigor::Plugin::Macro::HeredocTemplate::NAME_PLACEHOLDER, name_arg.to_s)
      end

      def class_inherits_from?(class_name, constraint, hierarchy, environment)
        return true if class_name == constraint

        # Walk the project-side lexical chain.
        current = class_name
        visited = Set.new
        while (parent = hierarchy[current]) && !visited.include?(parent)
          return true if parent == constraint

          visited << parent
          current = parent
        end

        # Fall back to the env's RBS-aware ordering for the case
        # where the chain terminates at an RBS-known class
        # (ActiveRecord::Base, Dry::Struct, Sinatra::Base, …).
        return false if environment.nil?

        candidates = [class_name] + visited.to_a + [current]
        candidates.uniq.any? { |name| rbs_subtype?(name, constraint, environment) }
      end

      def rbs_subtype?(class_name, constraint, environment)
        ordering = environment.class_ordering(class_name, constraint)
        %i[equal subclass].include?(ordering)
      rescue StandardError
        false
      end

      def literal_symbol_arg(call_node, index)
        args_node = call_node.arguments
        return nil if args_node.nil?

        arg = args_node.arguments[index]
        return nil unless arg

        case arg
        when Prism::SymbolNode, Prism::StringNode then arg.unescaped.to_sym
        end
      end
    end
  end
end
