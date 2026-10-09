# frozen_string_literal: true

require "prism"

require_relative "return_type_heuristic"
require_relative "../../source/constant_path"
require_relative "../../source/node_children"
require_relative "../../inference/scope_indexer"

module Rigor
  module Analysis
    module DependencySourceInference
      # Walks a resolved gem's `roots:` and collects the `(class_name, method_name) → CatalogEntry(kind,
      # return_type)` method catalog. The walker is the source of facts the dispatcher tier consults to
      # recognise a method as defined by an opt-in gem and contribute a `Type::Dynamic`-wrapped return at
      # the call site.
      #
      # The dispatcher tier wraps every walker-contributed return in `Dynamic[T]` per ADR-10's gem-boundary
      # contract. When the heuristic ({ReturnTypeHeuristic}) recognises the method body's tail expression,
      # the dispatcher uses the heuristic's static facet; otherwise it falls back to `Dynamic[top]` (the
      # pre-heuristic behaviour). The heuristic is intentionally narrow — only literal-tail method bodies
      # fold; everything else degrades silently.
      #
      # Hard exclusions are NOT user-configurable, per ADR-10 § "Hard exclusions": top-level `spec/`,
      # `test/`, `bin/`, plus any non-`.rb` source. C extensions fall out automatically because the walker
      # only loads `.rb` files.
      module Walker
        # Top-level directories that MUST NOT participate in gem-source inference even when the user lists
        # them under `roots:`. The check is case-insensitive against the first segment of `roots:`; nested
        # `spec/` / `test/` directories deeper inside `lib/` are NOT filtered (a few gems legitimately ship
        # `lib/.../spec/`).
        HARD_EXCLUDED_ROOTS = %w[spec test bin].freeze

        # Walker outcome wrapping the harvested method catalog plus a budget-exceeded flag. ADR-10 slice 4
        # introduces the cap; the Walker stops appending to the accumulator once `catalog.size` reaches
        # `budget`, and `truncated?` reports whether the cap was reached. The Index records this per-gem so
        # the Runner can surface a single `dynamic.dependency-source.budget-exceeded` warning naming the
        # affected gem(s).
        #
        # Issue #1672 — `refinements` is the gem's `refine X do … end` table, `{refined class => {method =>
        # [refining modules]}}`, the shape `Inference::ScopeIndexer` builds for project files. A refine-body `def`
        # goes there and never into `catalog`: it is not a method of the refining module, and of the refined class
        # only after `using`.
        class Outcome < Data.define(:catalog, :truncated, :refinements)
          def initialize(catalog:, truncated:, refinements: {}.freeze)
            super
          end

          def truncated? = truncated
        end

        # The walk's two accumulators. The budget counts `catalog` only.
        Harvest = Struct.new(:catalog, :refinements)
        private_constant :Harvest

        # Per-method catalog entry. `kind` is `:instance` or `:singleton`; `return_type` is the
        # {ReturnTypeHeuristic}-extracted static facet (a `Rigor::Type::*`) or `nil` when the heuristic
        # declined. The dispatcher wraps a non-nil `return_type` in `Dynamic[T]`; a `nil` `return_type` falls
        # back to `Dynamic[top]`.
        class CatalogEntry < Data.define(:kind, :return_type)
          def initialize(kind:, return_type: nil)
            super
          end
        end

        # Sentinel for "no cap" — used by callers that don't care about the budget (specs, tooling).
        # Production code MUST pass an integer.
        UNBOUNDED = Float::INFINITY

        module_function

        # @param gem_dir — absolute path to the gem's installation directory.
        # @param roots — subdirectory names within the gem to walk (defaults to `["lib"]` per
        #   `Configuration::Dependencies::Entry`).
        # @param budget — per-gem catalog cap (method-definition count). When unset, defaults
        #   to `UNBOUNDED` for backwards-compatible test paths.
        # @return frozen wrapper carrying the catalog (`Hash{[class_name, method_name] =>
        #   :instance | :singleton}`) and a `truncated?` flag set when the walker stopped harvesting because
        #   the budget was reached. Methods of identical name on the same class with different kinds (rare;
        #   private API mostly) carry the kind that wins the per-class first walk.
        def walk(gem_dir:, roots:, budget: UNBOUNDED)
          harvest = Harvest.new({}, {})
          truncated = false
          accepted_roots(roots).each do |root|
            break if truncated

            truncated = walk_root(File.join(gem_dir.to_s, root), harvest, budget)
          end
          Outcome.new(catalog: harvest.catalog.freeze, truncated: truncated,
                      refinements: Inference::ScopeIndexer.freeze_refinements(harvest.refinements))
        end

        # Drops hard-excluded entries before any filesystem walk happens. Reasoning: we never want a gem's
        # `spec/` to participate even if the user requested it — the noise from RSpec-style globals plus
        # the cost of walking test fixtures isn't worth the marginal coverage.
        def accepted_roots(roots)
          roots.reject { |root| HARD_EXCLUDED_ROOTS.include?(root.downcase) }
        end

        # Returns true when the budget tripped during this root's walk so the caller can stop iterating
        # subsequent roots.
        def walk_root(root_dir, harvest, budget) # rubocop:disable Naming/PredicateMethod
          return false unless File.directory?(root_dir)

          Dir.glob(File.join(root_dir, "**", "*.rb")).each do |path|
            harvest_file(path, harvest, budget)
            return true if harvest.catalog.size >= budget
          end
          false
        end

        def harvest_file(path, harvest, budget)
          parse_result = Prism.parse_file(path)
          return unless parse_result.errors.empty?

          walk_node(parse_result.value, [], false, harvest, budget)
        rescue StandardError
          # Gem source we can't parse / read silently degrades to "no contribution from this file". The
          # user-facing diagnostic stream is reserved for the project source; opt-in gem source MUST NOT
          # pollute it with parse errors the user cannot fix.
          nil
        end

        # Walks a Prism subtree, accumulating method definitions under their qualified class name. Mirrors
        # the shape of `Inference::ScopeIndexer#walk_methods` but stays decoupled from `Scope` because
        # gem-source inference runs without a scope context.
        def walk_node(node, qualified_prefix, in_singleton_class, harvest, budget)
          return unless node.is_a?(Prism::Node)
          return if harvest.catalog.size >= budget

          case node
          when Prism::ClassNode, Prism::ModuleNode
            descend_class_or_module(node, qualified_prefix, in_singleton_class, harvest, budget)
          when Prism::SingletonClassNode
            descend_singleton_class(node, qualified_prefix, harvest, budget)
          when Prism::DefNode
            record_def_node(node, qualified_prefix, in_singleton_class, harvest, budget)
          when Prism::CallNode
            if (target = Inference::ScopeIndexer.refine_target(node))
              return walk_refine_body(node, target, qualified_prefix, in_singleton_class, harvest, budget)
            end

            walk_children(node, qualified_prefix, in_singleton_class, harvest, budget)
          else
            walk_children(node, qualified_prefix, in_singleton_class, harvest, budget)
          end
        end

        def walk_children(node, qualified_prefix, in_singleton_class, harvest, budget)
          node.rigor_each_child do |child|
            break if harvest.catalog.size >= budget

            walk_node(child, qualified_prefix, in_singleton_class, harvest, budget)
          end
        end

        # `class Foo` / `module Bar`. The dynamic-prefix shape (`module ::Foo`-rooted variants whose left
        # side is a runtime expression) is treated as opaque — we walk the children under the same prefix
        # so any inner class definitions are still recorded under their own name.
        def descend_class_or_module(node, qualified_prefix, in_singleton_class, harvest, budget)
          name = Source::ConstantPath.qualified_name_or_nil(node.constant_path)
          if name && node.body
            child_prefix = Source::ConstantPath.declaration_prefix(qualified_prefix, node.constant_path)
            walk_node(node.body, child_prefix, in_singleton_class, harvest, budget)
          else
            walk_children(node, qualified_prefix, in_singleton_class, harvest, budget)
          end
        end

        # `class << self` only — `class << expr` for any other `expr` is treated as opaque so we don't
        # accidentally record per-instance singleton methods under the surrounding class.
        def descend_singleton_class(node, qualified_prefix, harvest, budget)
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_node(node.body, qualified_prefix, true, harvest, budget)
          else
            walk_children(node, qualified_prefix, false, harvest, budget)
          end
        end

        def record_def_node(node, qualified_prefix, in_singleton_class, harvest, _budget)
          return if qualified_prefix.empty?

          class_name = qualified_prefix.join("::")
          kind = node.receiver.is_a?(Prism::SelfNode) || in_singleton_class ? :singleton : :instance
          key = [class_name, node.name]
          return if harvest.catalog.key?(key) # first walk wins

          return_type = ReturnTypeHeuristic.extract(node)
          harvest.catalog[key] = CatalogEntry.new(kind: kind, return_type: return_type)
        end

        # Issue #1672 — `refine X do … end`, the shape {Inference::ScopeIndexer.refine_target} accepts. The body's
        # instance `def`s are refinements of X by the enclosing module, recorded the way the project walk records
        # them (`ScopeIndexer#record_refinement_defs`: X resolved lexically, every name it can denote recorded).
        # None reaches the catalogue. A `refine` with no enclosing module, or inside `class << self`, refines
        # nothing Ruby accepts, so its defs are dropped. Declarations nested in the body still walk under the
        # lexical prefix, as they did before.
        def walk_refine_body(node, target, qualified_prefix, in_singleton_class, harvest, budget)
          body = node.block.body
          return if body.nil?

          unless qualified_prefix.empty? || in_singleton_class
            refining = qualified_prefix.join("::")
            targets = Inference::ScopeIndexer.constant_receiver_candidates(target, qualified_prefix)
            Inference::ScopeIndexer.each_refinement_def(body) do |def_node|
              targets.each { |class_name| record_refinement(harvest.refinements, class_name, def_node.name, refining) }
            end
          end
          walk_refine_declarations(body, qualified_prefix, harvest, budget)
        end

        def record_refinement(refinements, class_name, method_name, refining)
          modules = ((refinements[class_name] ||= {})[method_name] ||= [])
          modules << refining unless modules.include?(refining)
        end

        # The class / module declarations inside a refine body, walked as before; nothing else in it is.
        def walk_refine_declarations(node, qualified_prefix, harvest, budget)
          case node
          when Prism::ClassNode, Prism::ModuleNode
            walk_node(node, qualified_prefix, false, harvest, budget)
          when Prism::DefNode, Prism::SingletonClassNode
            nil
          else
            node.rigor_each_child { |child| walk_refine_declarations(child, qualified_prefix, harvest, budget) }
          end
        end
      end
    end
  end
end
