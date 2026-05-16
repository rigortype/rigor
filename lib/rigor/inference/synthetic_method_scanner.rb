# frozen_string_literal: true

require "prism"

require_relative "../plugin/macro/heredoc_template"
require_relative "../plugin/macro/trait_registry"
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
    module SyntheticMethodScanner # rubocop:disable Metrics/ModuleLength
      module_function

      # @param plugin_registry [Rigor::Plugin::Registry]
      # @param paths           [Array<String>] absolute paths to the project
      #   source files to scan.
      # @param environment     [Rigor::Environment, nil] used for
      #   inheritance resolution against RBS-known classes
      #   (ActiveRecord::Base, Dry::Struct, etc.) that aren't
      #   declared in project source.
      # @param fact_store      [Rigor::Plugin::FactStore, nil]
      #   the per-run cross-plugin fact store. ADR-18 lookups
      #   (`Plugin::Macro::HeredocTemplate::Emit#returns_from_arg`)
      #   consult this at scan time to resolve per-call-site
      #   return types from published facts; without it, those
      #   emit rows fall back to their static `returns:` (or
      #   `"untyped"` → `Dynamic[Top]`).
      # @return [Rigor::Inference::SyntheticMethodIndex]
      def scan(plugin_registry:, paths:, environment: nil, fact_store: nil)
        templates = collect_templates(plugin_registry)
        registries = collect_trait_registries(plugin_registry)
        return SyntheticMethodIndex::EMPTY if templates.empty? && registries.empty?

        asts = parse_paths(paths)
        hierarchy = build_hierarchy(asts)
        concern_index = build_concern_index(asts)

        entries = []
        asts.each do |path, ast|
          walk_class_bodies(ast) do |class_name, call_node|
            collect_entries(entries, templates, class_name, call_node, hierarchy, environment, path, fact_store)
            collect_trait_entries(entries, registries, class_name, call_node, hierarchy, environment, path)
            collect_concern_re_targeted_entries(
              entries, call_node, class_name, concern_index,
              templates, registries, hierarchy, environment, path, fact_store
            )
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

      # ADR-16 Tier B (slice 3b). Aggregates `(plugin_id, registry)`
      # pairs across every plugin's `manifest.trait_registries` in
      # registration order. Empty when no plugin contributes Tier B
      # entries.
      def collect_trait_registries(plugin_registry)
        return [] if plugin_registry.nil? || plugin_registry.empty?

        plugin_registry.plugins.flat_map do |plugin|
          # rigor:disable undefined-method
          plugin.manifest.trait_registries.map do |registry|
            [plugin.manifest.id, registry]
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

      # ADR-16 slice 4 — Concern re-targeting index.
      #
      # Walks every top-level / nested `module M` decl looking for
      # the ActiveSupport::Concern shape:
      #
      #     module M
      #       extend ActiveSupport::Concern
      #       included do
      #         # deferred DSL calls — fire on the *includer*, not on M
      #         devise :database_authenticatable
      #         has_one_attached :avatar
      #       end
      #     end
      #
      # The returned Hash maps `module_name => [deferred_call_node, ...]`.
      # When a class body later contains `include M`, the substrate
      # replays each deferred call against the including class.
      #
      # Slice 4 scope (floor):
      # - constant-path `include M` only (not `include some_var`).
      # - one-hop: nested concerns (M's `included do; include N; end`)
      #   are NOT transitively replayed; deferred. Concrete demand
      #   is the trigger for adding the second hop.
      # - `class_methods do ... end` blocks are NOT yet handled —
      #   singleton-level emission is out of scope per the slice-3
      #   floor framing.
      CONCERN_NAME = "ActiveSupport::Concern"

      def build_concern_index(asts)
        index = {}
        asts.each_value do |ast|
          next if ast.nil?

          walk_module_decls(ast, []) do |module_name, body|
            next if module_name.nil? || body.nil?
            next unless concern_module_body?(body)

            deferred_calls = collect_included_do_calls(body)
            index[module_name] = deferred_calls.freeze if deferred_calls.any?
          end
        end
        index.freeze
      end

      def walk_module_decls(node, scope_stack, &)
        return unless node.respond_to?(:compact_child_nodes)

        case node
        when Prism::ModuleNode
          name = class_name_from(node, scope_stack)
          yield name, node.body
          new_stack = scope_stack + [node]
          node.body&.compact_child_nodes&.each { |child| walk_module_decls(child, new_stack, &) }
        when Prism::ClassNode
          new_stack = scope_stack + [node]
          node.body&.compact_child_nodes&.each { |child| walk_module_decls(child, new_stack, &) }
        else
          node.compact_child_nodes.each { |child| walk_module_decls(child, scope_stack, &) }
        end
      end

      # Recognises a module body that begins with (or contains at
      # top level) an `extend ActiveSupport::Concern` statement.
      def concern_module_body?(body)
        return false unless body.respond_to?(:body)

        body.body.any? do |stmt|
          next false unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name == :extend

          args = stmt.arguments&.arguments || []
          args.any? { |arg| const_name_string(arg) == CONCERN_NAME }
        end
      end

      def collect_included_do_calls(body)
        body.body.flat_map do |stmt|
          next [] unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name == :included && stmt.block

          block_body = stmt.block.body
          next [] unless block_body.respond_to?(:body)

          block_body.body.select { |inner| inner.is_a?(Prism::CallNode) && inner.receiver.nil? }
        end
      end

      # Slice 4 hook. When the current class body contains
      # `include M` and M is a Concern with deferred DSL calls,
      # replay each deferred call against the including class.
      # Acts as a re-targeting walker — no new manifest entries
      # needed; downstream `collect_entries` /
      # `collect_trait_entries` fire just as if the calls had been
      # written directly in X's body.
      def collect_concern_re_targeted_entries(entries, call_node, class_name, concern_index, # rubocop:disable Metrics/ParameterLists
                                              templates, registries, hierarchy, environment, path, fact_store = nil)
        return unless call_node.name == :include && call_node.receiver.nil?
        return if concern_index.empty?

        args = call_node.arguments&.arguments || []
        args.each do |arg|
          name = const_name_string(arg)
          deferred = name && concern_index[name]
          next unless deferred

          deferred.each do |inner_call|
            collect_entries(entries, templates, class_name, inner_call, hierarchy, environment, path, fact_store)
            collect_trait_entries(entries, registries, class_name, inner_call, hierarchy, environment, path)
          end
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

      def collect_entries(entries, templates, class_name, call_node, hierarchy, environment, path, fact_store = nil) # rubocop:disable Metrics/ParameterLists
        templates.each do |(plugin_id, template)|
          next unless call_node.name == template.method_name
          next unless class_inherits_from?(class_name, template.receiver_constraint, hierarchy, environment)

          symbol_arg = literal_symbol_arg(call_node, template.symbol_arg_position)
          next if symbol_arg.nil?

          emit_entries_for(entries, class_name, symbol_arg, template, plugin_id, path, call_node, fact_store)
        end
      end

      # ADR-16 Tier B (slice 3b). For each matching call like
      # `<X>.<method_name>(:trait_a, :trait_b)` where X inherits
      # from the registry's receiver_constraint: collect every
      # registered trait symbol's module (silently skipping
      # unknown traits per design decision (2)) plus the
      # always_included modules, then per-method-explode each
      # module's RBS instance methods into the index.
      #
      # Per slice 3 floor (per user agreement): the synthesised
      # methods adopt `return_type: "untyped"` (Dynamic[T] at
      # dispatch). Precision promotion — looking up the module's
      # actual RBS return type — is reserved for the ceiling slice.
      def collect_trait_entries(entries, registries, class_name, call_node, hierarchy, environment, path)
        registries.each do |(plugin_id, registry)|
          next unless call_node.name == registry.method_name
          next unless class_inherits_from?(class_name, registry.receiver_constraint, hierarchy, environment)

          modules = resolve_trait_modules(registry, call_node)
          next if modules.empty?

          emit_trait_module_entries(entries, class_name, modules, registry, plugin_id, path, call_node, environment)
        end
      end

      # Resolves the set of modules to include from a Tier B
      # call site:
      #
      # - `always_included` modules (unconditional);
      # - one module per literal Symbol argument the call carries
      #   (resolved through `registry.modules_by_symbol`; unknown
      #   symbols silently skipped per design decision (2)).
      #
      # Returns an Array<String> of module names in
      # `always_included` order followed by argument order.
      def resolve_trait_modules(registry, call_node)
        modules = registry.always_included.dup
        positional_symbols(call_node, registry).each do |symbol|
          module_name = registry.module_for(symbol)
          modules << module_name if module_name
        end
        modules
      end

      def positional_symbols(call_node, registry)
        args_node = call_node.arguments
        return [] if args_node.nil?

        if registry.symbol_arg_position == Rigor::Plugin::Macro::TraitRegistry::REST_POSITION
          args_node.arguments.filter_map { |arg| literal_symbol_value(arg) }
        else
          symbol_arg = literal_symbol_arg(call_node, registry.symbol_arg_position)
          symbol_arg ? [symbol_arg] : []
        end
      end

      def literal_symbol_value(node)
        case node
        when Prism::SymbolNode, Prism::StringNode then node.unescaped.to_sym
        end
      end

      def emit_trait_module_entries(entries, class_name, modules, registry, plugin_id, path, call_node, environment) # rubocop:disable Metrics/ParameterLists
        modules.each do |module_name|
          method_names = module_instance_method_names(module_name, environment)
          method_names.each do |method_name|
            entries << build_trait_synthetic_method(
              class_name: class_name, method_name: method_name, module_name: module_name,
              registry: registry, plugin_id: plugin_id, path: path, call_node: call_node
            )
          end
        end
      end

      # Returns the Symbol method-name list defined on `module_name`'s
      # RBS instance definition. Empty Array when the module is not
      # in the RBS env (silent skip — the synthetic emit produces
      # nothing rather than fabricating method names).
      def module_instance_method_names(module_name, environment)
        return [] if environment.nil?

        loader = environment.rbs_loader
        return [] if loader.nil?

        definition = loader.instance_definition(module_name)
        return [] if definition.nil?

        definition.methods.keys
      rescue StandardError
        []
      end

      def build_trait_synthetic_method(class_name:, method_name:, module_name:, registry:, plugin_id:, path:,
                                       call_node:)
        SyntheticMethod.new(
          class_name: class_name,
          method_name: method_name,
          return_type: "untyped",
          kind: SyntheticMethod::INSTANCE,
          provenance: {
            plugin_id: plugin_id,
            origin_module: module_name,
            trait_method: registry.method_name.to_s,
            template_constraint: registry.receiver_constraint,
            source_path: path,
            source_line: call_node.location.start_line
          }
        )
      end

      def emit_entries_for(entries, class_name, symbol_arg, template, plugin_id, path, call_node, fact_store = nil) # rubocop:disable Metrics/ParameterLists
        template.emit.each do |row|
          entries << build_synthetic_method(
            class_name: class_name, name_arg: symbol_arg, row: row,
            template: template, plugin_id: plugin_id, path: path, call_node: call_node,
            kind: SyntheticMethod::INSTANCE, fact_store: fact_store
          )
        end
        template.class_level_emit.each do |row|
          entries << build_synthetic_method(
            class_name: class_name, name_arg: symbol_arg, row: row,
            template: template, plugin_id: plugin_id, path: path, call_node: call_node,
            kind: SyntheticMethod::SINGLETON, fact_store: fact_store
          )
        end
      end

      # rubocop:disable Metrics/ParameterLists
      def build_synthetic_method(class_name:, name_arg:, row:, template:, plugin_id:, path:, call_node:, kind:,
                                 fact_store: nil)
        # rubocop:enable Metrics/ParameterLists
        SyntheticMethod.new(
          class_name: class_name,
          method_name: interpolate(row.name, name_arg).to_sym,
          return_type: resolve_emit_return_type(row, call_node, fact_store),
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

      # ADR-18 three-tier fallback for the synthetic method's
      # `return_type` string:
      #
      # 1. When `row.returns_from_arg` is present AND the
      #    call-site argument at the declared position is a
      #    resolvable constant reference AND the fact_store
      #    has a matching value, use that as the return type.
      # 2. Else if `row.returns` is a non-empty String, use it
      #    (the slice-6b static path).
      # 3. Else use `"untyped"` so the dispatcher's
      #    `promote_via_return_type` sentinel chain yields
      #    `Dynamic[Top]`.
      def resolve_emit_return_type(row, call_node, fact_store)
        resolved = resolve_returns_from_arg(row.returns_from_arg, call_node, fact_store)
        return resolved if resolved
        return row.returns if row.returns

        "untyped"
      end

      def resolve_returns_from_arg(returns_from_arg, call_node, fact_store)
        return nil if returns_from_arg.nil?

        source_rep = argument_source_representation(call_node, returns_from_arg.position)
        return nil if source_rep.nil?
        return nil if fact_store.nil?

        fact = fact_store.read(plugin_id: returns_from_arg.plugin_id, name: returns_from_arg.fact)
        return nil unless fact.is_a?(Hash)

        fact[source_rep]
      end

      # Extracts the source-text qualified-constant representation
      # of the call's positional argument (e.g.,
      # `"Types::String"`). Returns nil for non-constant shapes
      # (literals, method chains, blocks, …). The floor
      # intentionally accepts only ConstantReadNode /
      # ConstantPathNode per ADR-18; chained-call argument
      # resolution stays deferred.
      def argument_source_representation(call_node, position)
        args = call_node.arguments&.arguments
        return nil if args.nil? || position >= args.size

        node = args[position]
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then qualified_constant_name(node)
        end
      end

      def qualified_constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode
          parent_name = node.parent.nil? ? nil : qualified_constant_name(node.parent)
          return nil if !node.parent.nil? && parent_name.nil?

          parent_name.nil? ? node.name.to_s : "#{parent_name}::#{node.name}"
        end
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
