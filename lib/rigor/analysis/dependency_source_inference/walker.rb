# frozen_string_literal: true

require "prism"

module Rigor
  module Analysis
    module DependencySourceInference
      # Walks a resolved gem's `roots:` and collects the
      # `(class_name, method_name) → :instance | :singleton`
      # method catalog. The walker is the source of facts the
      # dispatcher tier (slice 2b-ii) consults to recognise a
      # method as defined by an opt-in gem and contribute a
      # `Type::Dynamic` return at the call site.
      #
      # Slice 2b-i intentionally collects only the catalog, not
      # the inferred return type. The dispatcher tier returns
      # `Dynamic[top]` on a hit until slice 2b-ii wires return-
      # type inference; the visible payoff today is removing the
      # `call.undefined-method` diagnostic for opt-in gem methods
      # at receivers Rigor knows by `Nominal[T]` (typically
      # because the user authored an RBS skeleton).
      #
      # Hard exclusions are NOT user-configurable, per ADR-10
      # § "Hard exclusions": top-level `spec/`, `test/`, `bin/`,
      # plus any non-`.rb` source. C extensions fall out
      # automatically because the walker only loads `.rb` files.
      module Walker
        # Top-level directories that MUST NOT participate in
        # gem-source inference even when the user lists them
        # under `roots:`. The check is case-insensitive against
        # the first segment of `roots:`; nested `spec/` /
        # `test/` directories deeper inside `lib/` are NOT
        # filtered (a few gems legitimately ship `lib/.../spec/`).
        HARD_EXCLUDED_ROOTS = %w[spec test bin].freeze

        # Walker outcome wrapping the harvested method catalog
        # plus a budget-exceeded flag. ADR-10 slice 4 introduces
        # the cap; the Walker stops appending to the accumulator
        # once `catalog.size` reaches `budget`, and `truncated?`
        # reports whether the cap was reached. The Index records
        # this per-gem so the Runner can surface a single
        # `dynamic.dependency-source.budget-exceeded` warning
        # naming the affected gem(s).
        Outcome = Data.define(:catalog, :truncated) do
          def truncated? = truncated
        end

        # Sentinel for "no cap" — used by callers that don't
        # care about the budget (specs, tooling). Production
        # code MUST pass an integer.
        UNBOUNDED = Float::INFINITY

        module_function

        # @param gem_dir [String, Pathname] absolute path to the
        #   gem's installation directory.
        # @param roots [Array<String>] subdirectory names within
        #   the gem to walk (defaults to `["lib"]` per
        #   `Configuration::Dependencies::Entry`).
        # @param budget [Integer, Float] per-gem catalog cap
        #   (method-definition count). When unset, defaults to
        #   `UNBOUNDED` for backwards-compatible test paths.
        # @return [Outcome] frozen wrapper carrying the catalog
        #   (`Hash{[class_name, method_name] => :instance |
        #   :singleton}`) and a `truncated?` flag set when the
        #   walker stopped harvesting because the budget was
        #   reached. Methods of identical name on the same class
        #   with different kinds (rare; private API mostly)
        #   carry the kind that wins the per-class first walk.
        def walk(gem_dir:, roots:, budget: UNBOUNDED)
          accumulator = {}
          truncated = false
          accepted_roots(roots).each do |root|
            break if truncated

            truncated = walk_root(File.join(gem_dir.to_s, root), accumulator, budget)
          end
          Outcome.new(catalog: accumulator.freeze, truncated: truncated)
        end

        # Drops hard-excluded entries before any filesystem
        # walk happens. Reasoning: we never want a gem's
        # `spec/` to participate even if the user requested
        # it — the noise from RSpec-style globals plus the
        # cost of walking test fixtures isn't worth the
        # marginal coverage.
        def accepted_roots(roots)
          roots.reject { |root| HARD_EXCLUDED_ROOTS.include?(root.downcase) }
        end

        # Returns true when the budget tripped during this
        # root's walk so the caller can stop iterating
        # subsequent roots.
        def walk_root(root_dir, accumulator, budget) # rubocop:disable Naming/PredicateMethod
          return false unless File.directory?(root_dir)

          Dir.glob(File.join(root_dir, "**", "*.rb")).each do |path|
            harvest_file(path, accumulator, budget)
            return true if accumulator.size >= budget
          end
          false
        end

        def harvest_file(path, accumulator, budget)
          parse_result = Prism.parse_file(path)
          return unless parse_result.errors.empty?

          walk_node(parse_result.value, [], false, accumulator, budget)
        rescue StandardError
          # Gem source we can't parse / read silently degrades
          # to "no contribution from this file". The user-facing
          # diagnostic stream is reserved for the project source;
          # opt-in gem source MUST NOT pollute it with parse
          # errors the user cannot fix.
          nil
        end

        # Walks a Prism subtree, accumulating method definitions
        # under their qualified class name. Mirrors the shape of
        # `Inference::ScopeIndexer#walk_methods` but stays
        # decoupled from `Scope` because gem-source inference
        # runs without a scope context.
        def walk_node(node, qualified_prefix, in_singleton_class, accumulator, budget)
          return unless node.is_a?(Prism::Node)
          return if accumulator.size >= budget

          case node
          when Prism::ClassNode, Prism::ModuleNode
            descend_class_or_module(node, qualified_prefix, in_singleton_class, accumulator, budget)
          when Prism::SingletonClassNode
            descend_singleton_class(node, qualified_prefix, accumulator, budget)
          when Prism::DefNode
            record_def_node(node, qualified_prefix, in_singleton_class, accumulator, budget)
          else
            walk_children(node, qualified_prefix, in_singleton_class, accumulator, budget)
          end
        end

        def walk_children(node, qualified_prefix, in_singleton_class, accumulator, budget)
          node.compact_child_nodes.each do |child|
            break if accumulator.size >= budget

            walk_node(child, qualified_prefix, in_singleton_class, accumulator, budget)
          end
        end

        # `class Foo` / `module Bar`. The dynamic-prefix shape
        # (`module ::Foo`-rooted variants whose left side is a
        # runtime expression) is treated as opaque — we walk the
        # children under the same prefix so any inner class
        # definitions are still recorded under their own name.
        def descend_class_or_module(node, qualified_prefix, in_singleton_class, accumulator, budget)
          name = qualified_name_for(node.constant_path)
          if name && node.body
            walk_node(node.body, qualified_prefix + [name], in_singleton_class, accumulator, budget)
          else
            walk_children(node, qualified_prefix, in_singleton_class, accumulator, budget)
          end
        end

        # `class << self` only — `class << expr` for any other
        # `expr` is treated as opaque so we don't accidentally
        # record per-instance singleton methods under the
        # surrounding class.
        def descend_singleton_class(node, qualified_prefix, accumulator, budget)
          if node.expression.is_a?(Prism::SelfNode) && node.body
            walk_node(node.body, qualified_prefix, true, accumulator, budget)
          else
            walk_children(node, qualified_prefix, false, accumulator, budget)
          end
        end

        def record_def_node(node, qualified_prefix, in_singleton_class, accumulator, _budget)
          return if qualified_prefix.empty?

          class_name = qualified_prefix.join("::")
          kind = node.receiver.is_a?(Prism::SelfNode) || in_singleton_class ? :singleton : :instance
          accumulator[[class_name, node.name]] ||= kind
        end

        # Resolves a `Prism::ConstantPathNode` /
        # `Prism::ConstantReadNode` chain to its dot-separated
        # name (e.g. `"Foo::Bar"`). Returns nil for the rare
        # dynamic-prefix shape (`module ::Foo`-rooted variants
        # whose left side is a runtime expression) so the
        # walker treats those as opaque rather than guessing.
        def qualified_name_for(node)
          case node
          when Prism::ConstantReadNode then node.name.to_s
          when Prism::ConstantPathNode
            parent = node.parent.nil? ? nil : qualified_name_for(node.parent)
            return nil if !node.parent.nil? && parent.nil?

            parent.nil? ? node.name.to_s : "#{parent}::#{node.name}"
          end
        end
      end
    end
  end
end
